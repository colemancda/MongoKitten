//
//  Database.swift
//  MongoSwift
//
//  Created by Joannis Orlandos on 27/01/16.
//  Copyright © 2016 PlanTeam. All rights reserved.
//

import Foundation
import BSON

/// A Mongo Database. Cannot be publically initialized. But you can get a database object by subscripting a Server with a String
public class Database {
    /// The server that this Database is a part of
    public let server: Server
    
    /// The database's name
    public let name: String
    
    public internal(set) var isAuthenticated = true
    
    internal init(database: String, at server: Server) {
        self.server = server
        self.name = database.replacingOccurrences(of: ".", with: "")
    }
    
    /// This subscript is used to get a collection by providing a name as a String
    public subscript (collection: String) -> Collection {
        return Collection(named: collection, in: self)
    }
    
    @warn_unused_result
    internal func allDocuments(in message: Message) throws -> [Document] {
        guard case .Reply(_, _, _, _, _, _, let documents) = message else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return documents
    }
    
    @warn_unused_result
    internal func firstDocument(in message: Message) throws -> Document {
        let documents = try allDocuments(in: message)
        
        guard let document = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: message)
        }
        
        return document
    }
    
    /// Executes a command on this database using a query message
    @warn_unused_result
    internal func execute(command command: Document) throws -> Message {
        let cmd = self["$cmd"]
        let commandMessage = Message.Query(requestID: server.nextMessageID(), flags: [], collection: cmd, numbersToSkip: 0, numbersToReturn: 1, query: command, returnFields: nil)
        let id = try server.send(message: commandMessage)
        return try server.await(response: id)
    }
    
    @warn_unused_result
    public func getCollectionInfos(filter filter: Document? = nil) throws -> Cursor<Document> {
        var request: Document = ["listCollections": 1]
        if let filter = filter {
            request["filter"] = filter
        }
        
        let reply = try execute(command: request)
        
        let result = try firstDocument(in: reply)
        
        guard let code = result["ok"]?.intValue, cursor = result["cursor"] as? Document where code == 1 else {
            throw MongoError.CommandFailure
        }
        
        return try Cursor(cursorDocument: cursor, server: server, chunkSize: 10, transform: { $0 })
    }
    
    /// Gets the collections in this database
    @warn_unused_result
    public func getCollections(filter filter: Document? = nil) throws -> Cursor<Collection> {
        let infoCursor = try self.getCollectionInfos(filter: filter)
        return Cursor(base: infoCursor) { collectionInfo in
            guard let name = collectionInfo["name"]?.stringValue else { return nil }
            return self[name]
        }
    }
    
    @warn_unused_result
    internal func isMaster() throws -> Document {
        let response = try self.execute(command: ["ismaster": Int32(1)])
        
        return try firstDocument(in: response)
    }
}

extension Database {
    /// Generates a random String
    private func randomNonce() -> String {
        let allowedCharacters = "!\"#'$%&()*+-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_$"
        
        var randomString = ""
        
        for _ in 0..<24 {
            let randomNumber: Int
            
            #if os(Linux)
                randomNumber = Int(random() % allowedCharacters.characters.count)
            #else
                randomNumber = Int(arc4random_uniform(UInt32(allowedCharacters.characters.count)))
            #endif
            
            let letter = allowedCharacters[allowedCharacters.startIndex.advanced(by: randomNumber)]
            
            randomString.append(letter)
        }
        
        return randomString
    }
    
    /// Parses a SCRAM response
    private func parseResponse(response: String) -> [String: String] {
        var parsedResponse = [String: String]()
        
        for part in response.characters.split(separator: ",") where String(part).characters.count >= 3 {
            let part = String(part)
            
            if let first = part.characters.first {
                parsedResponse[String(first)] = part[part.startIndex.advanced(by: 2)..<part.endIndex]
            }
        }
        
        return parsedResponse
    }
    
    /// Used for applying SHA1_HMAC on a password and salt
    private func digest(password: String, data: [Byte]) throws -> [Byte] {
        var passwordBytes = [Byte]()
        passwordBytes.append(contentsOf: password.utf8)
        
        return try Authenticator.HMAC(key: passwordBytes, variant: .sha1).authenticate(data)
    }
    
    /// xor's two arrays of bytes
    private func xor(left: [Byte], _ right: [Byte]) -> [Byte] {
        var result = [Byte]()
        let loops = min(left.count, right.count)
        
        result.reserveCapacity(loops)
        
        for i in 0..<loops {
            result.append(left[i] ^ right[i])
        }
        
        return result
    }
    
    /// Applies the `hi` (PBKDF2 with HMAC as PseudoRandom Function)
    private func hi(password: String, salt: [Byte], iterations: Int) throws -> [Byte] {
        var salt = salt
        salt.append(contentsOf:)(contentsOf: [0, 0, 0, 1])
        
        var ui = try digest(password, data: salt)
        var u1 = ui
        
        for _ in 0..<iterations - 1 {
            u1 = try digest(password, data: u1)
            ui = xor(ui, u1)
        }
        
        return ui
    }
    
    /// Last step(s) in the SASL process
    /// TODO: Set a timeout for connecting
    private func complete(SASL payload: String, using response: Document, verifying signature: [Byte]) throws {
        // If we failed authentication
        guard response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if response["done"]?.boolValue == true {
            return
        }
        
        guard let stringResponse = response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let conversationId = response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let finalResponse = String(bytes: [Byte](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let dictionaryResponse = self.parseResponse(finalResponse)
        
        guard let v = dictionaryResponse["v"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        let serverSignature = [Byte](base64: v)
        
        guard serverSignature == signature else {
            throw MongoAuthenticationError.ServerSignatureInvalid
        }
        
        let response = try self.execute(command: [
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": ""
            ])
        
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        try self.complete(SASL: payload, using: responseDocument, verifying: serverSignature)
    }
    
    /// Respond to a challenge
    /// TODO: Set a timeout for connecting
    private func challenge(with details: (username: String, password: String), using previousInformation: (nonce: String, response: Document)) throws {
        // If we failed the authentication
        guard previousInformation.response["ok"]?.int32Value == 1 else {
            throw MongoAuthenticationError.IncorrectCredentials
        }
        
        // If we're done
        if previousInformation.response["done"]?.boolValue == true {
            return
        }
        
        // Get our ConversationID
        guard let conversationId = previousInformation.response["conversationId"] else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Create our header
        var basicHeader = [Byte]()
        basicHeader.append(contentsOf:)(contentsOf: "n,,".utf8)
        
        guard let header = basicHeader.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Decode the challenge
        guard let stringResponse = previousInformation.response["payload"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        guard let decodedStringResponse = String(bytes: [Byte](base64: stringResponse), encoding: NSUTF8StringEncoding) else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Parse the challenge
        let dictionaryResponse = self.parseResponse(decodedStringResponse)
        
        guard let nonce = dictionaryResponse["r"], let stringSalt = dictionaryResponse["s"], let stringIterations = dictionaryResponse["i"], let iterations = Int(stringIterations) where String(nonce[nonce.startIndex..<nonce.startIndex.advanced(by: 24)]) == previousInformation.nonce else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Build up the basic information
        let noProof = "c=\(header),r=\(nonce)"
        
        // Calculate the proof
        var digestBytes = [Byte]()
        digestBytes.append(contentsOf:)(contentsOf: "\(details.username):mongo:\(details.password)".utf8)
        
        let digest = digestBytes.md5().toHexString()
        let salt = [Byte](base64: stringSalt)
        
        let saltedPassword = try hi(digest, salt: salt, iterations: iterations)
        var ck = [Byte]()
        ck.append(contentsOf:)(contentsOf: "Client Key".utf8)
        
        var sk = [Byte]()
        sk.append(contentsOf:)(contentsOf: "Server Key".utf8)
        
        let clientKey = try Authenticator.HMAC(key: saltedPassword, variant: .sha1).authenticate(ck)
        let storedKey = clientKey.sha1()
        
        let fixedUsername = details.username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        
        let authenticationMessage = "n=\(fixedUsername),r=\(previousInformation.nonce),\(decodedStringResponse),\(noProof)"
        
        var authenticationMessageBytes = [Byte]()
        authenticationMessageBytes.append(contentsOf: authenticationMessage.utf8)
        
        let clientSignature = try Authenticator.HMAC(key: storedKey, variant: .sha1).authenticate(authenticationMessageBytes)
        let clientProof = xor(clientKey, clientSignature)
        let serverKey = try Authenticator.HMAC(key: saltedPassword, variant: .sha1).authenticate(sk)
        let serverSignature = try Authenticator.HMAC(key: serverKey, variant: .sha1).authenticate(authenticationMessageBytes)
        
        // Base64 the proof
        guard let proof = clientProof.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Base64 the payload
        guard let payload = "\(noProof),p=\(proof)".cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        // Send the proof
        let response = try self.execute(command: [
                                                   "saslContinue": Int32(1),
                                                   "conversationId": conversationId,
                                                   "payload": payload
            ])
        
        // If we don't get a correct reply
        guard case .Reply(_, _, _, _, _, _, let documents) = response, let responseDocument = documents.first else {
            throw InternalMongoError.IncorrectReply(reply: response)
        }
        
        // Complete Authentication
        try self.complete(SASL: payload, using: responseDocument, verifying: serverSignature)
    }
    
    /// Authenticates to this database using SASL
    /// TODO: Support authentication DBs
    /// TODO: Set a timeout for connecting
    internal func authenticate(SASL details: (username: String, password: String)) throws {
        let nonce = randomNonce()
        
        let fixedUsername = details.username.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        
        guard let payload = "n,,n=\(fixedUsername),r=\(nonce)".cStringBsonData.toBase64() else {
            throw MongoAuthenticationError.Base64Failure
        }
        
        let response = try self.execute(command: [
                                                   "saslStart": Int32(1),
                                                   "mechanism": "SCRAM-SHA-1",
                                                   "payload": payload
            ])
        
        let responseDocument = try firstDocument(in: response)
        
        try self.challenge(with: details, using: (nonce: nonce, response: responseDocument))
    }
    
    /// Authenticate with MongoDB Challenge Response
    /// TODO: Set a timeout for connecting
    internal func authenticate(mongoCR details: (username: String, password: String)) throws {
        // Get the server's nonce
        let response = try self.execute(command: [
                                                   "getNonce": Int32(1)
            ])
        
        // Get the server's challenge
        let document = try firstDocument(in: response)
        
        guard let nonce = document["nonce"]?.stringValue else {
            throw MongoAuthenticationError.AuthenticationFailure
        }
        
        // Digest our password and prepare it for sending
        let digest = "\(details.username):mongo:\(details.password)".cStringBsonData.md5().toHexString()
        let key = "\(nonce)\(details.username)\(digest)".cStringBsonData.md5().toHexString()
        
        // Respond to the challengge
        let successResponse = try self.execute(command: [
                                                          "authenticate": 1,
                                                          "nonce": nonce,
                                                          "user": details.username,
                                                          "key": key
            ])
        
        let successDocument = try firstDocument(in: successResponse)
        
        // Check for success
        guard let ok = successDocument["ok"]?.intValue where ok == 1 else {
            throw InternalMongoError.IncorrectReply(reply: successResponse)
        }
    }
}