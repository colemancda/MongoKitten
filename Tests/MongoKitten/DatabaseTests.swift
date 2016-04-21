//
//  DatabaseTests.swift
//  MongoKitten
//
//  Created by Joannis Orlandos on 21/04/16.
//
//

import XCTest
import MongoKitten

class DatabaseTests: XCTestCase {
    static var allTests: [(String, DatabaseTests -> () throws -> Void)] {
        return [
                   ("testUsers", testUsers),
        ]
    }
    
    override func setUp() {
        super.setUp()
        
        try! TestManager.connect()
        try! TestManager.clean()
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testUsers() {
        let roles: Document = [["role": "dbOwner", "db": ~TestManager.db.name]]
        
        try! TestManager.db.create(user: "mongokitten-unittest-testuser", password: "hunter2", roles: roles, customData: ["testdata": true])
        
        let userInfo = try! TestManager.db.info(for: "mongokitten-unittest-testuser")
        
        print(userInfo)
    }
}