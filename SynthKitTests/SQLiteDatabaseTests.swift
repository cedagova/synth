import XCTest
@testable import SynthKit

final class SQLiteDatabaseTests: XCTestCase {
    private var sandboxRoot: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        database = try SQLiteDatabase.open(at: sandboxRoot.appending(path: "test.sqlite"))
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    func testOpenCreatesTheDatabaseFile() throws {
        try database.executeScript("CREATE TABLE t (a INTEGER);")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sandboxRoot.appending(path: "test.sqlite").path(percentEncoded: false)
            )
        )
    }

    func testOpenFailsWithAClearErrorForAnUnwritablePath() {
        let unreachable = sandboxRoot
            .appending(path: "missing-directory")
            .appending(path: "test.sqlite")

        XCTAssertThrowsError(try SQLiteDatabase.open(at: unreachable)) { error in
            guard case StoreError.databaseOpenFailed(_, _, let message) = error else {
                return XCTFail("Expected databaseOpenFailed, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testParameterBindingAndScalarReads() throws {
        try database.executeScript("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT, note TEXT);")
        try database.execute(
            "INSERT INTO t (id, label, note) VALUES (?, ?, ?);",
            [.integer(7), .text("seven"), .null]
        )

        XCTAssertEqual(try database.scalarInt("SELECT id FROM t;"), 7)
        XCTAssertEqual(try database.scalarText("SELECT label FROM t;"), "seven")
        XCTAssertNil(try database.scalarText("SELECT note FROM t;"))
        XCTAssertNil(try database.scalarInt("SELECT id FROM t WHERE id = 99;"))
    }

    func testTextBindingIsNotInterpretedAsSQL() throws {
        try database.executeScript("CREATE TABLE t (label TEXT);")
        let hostile = "'); DROP TABLE t; --"
        try database.execute("INSERT INTO t (label) VALUES (?);", [.text(hostile)])

        XCTAssertTrue(try database.tableExists("t"))
        XCTAssertEqual(try database.scalarText("SELECT label FROM t;"), hostile)
    }

    func testInvalidStatementThrowsWithTheOffendingSQL() {
        XCTAssertThrowsError(try database.executeScript("SELECT * FROM nope;")) { error in
            guard case StoreError.statementFailed(let sql, _, let message) = error else {
                return XCTFail("Expected statementFailed, got \(error)")
            }
            XCTAssertEqual(sql, "SELECT * FROM nope;")
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testTransactionRollsBackOnThrow() throws {
        try database.executeScript("CREATE TABLE t (a INTEGER);")

        struct Boom: Error {}
        XCTAssertThrowsError(
            try database.withTransaction { db in
                try db.execute("INSERT INTO t (a) VALUES (?);", [.integer(1)])
                throw Boom()
            }
        )

        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM t;"), 0)
    }

    func testTransactionCommitsAndReturnsItsValue() throws {
        try database.executeScript("CREATE TABLE t (a INTEGER);")

        let inserted: Int = try database.withTransaction { db in
            try db.execute("INSERT INTO t (a) VALUES (?);", [.integer(42)])
            return 42
        }

        XCTAssertEqual(inserted, 42)
        XCTAssertEqual(try database.scalarInt("SELECT a FROM t;"), 42)
    }

    func testTableExists() throws {
        XCTAssertFalse(try database.tableExists("t"))
        try database.executeScript("CREATE TABLE t (a INTEGER);")
        XCTAssertTrue(try database.tableExists("t"))
    }

    func testUsingAClosedDatabaseFailsLoudly() throws {
        database.close()
        XCTAssertThrowsError(try database.executeScript("CREATE TABLE t (a INTEGER);")) { error in
            guard case StoreError.statementFailed(_, _, let message) = error else {
                return XCTFail("Expected statementFailed, got \(error)")
            }
            XCTAssertEqual(message, "database is closed")
        }
    }
}
