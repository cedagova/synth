import XCTest
@testable import SynthKit

final class SchemaMigratorTests: XCTestCase {
    private var sandboxRoot: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        database = try SQLiteDatabase.open(at: sandboxRoot.appending(path: "library.sqlite"))
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    func testShippedChainIsContiguousFromOne() {
        XCTAssertFalse(SchemaMigrator.migrations.isEmpty)
        for (offset, migration) in SchemaMigrator.migrations.enumerated() {
            XCTAssertEqual(migration.version, offset + 1)
            XCTAssertFalse(migration.name.isEmpty)
        }
        XCTAssertEqual(SchemaMigrator.latestVersion, SchemaMigrator.migrations.count)
    }

    func testFreshStoreReportsVersionZero() throws {
        XCTAssertEqual(try SchemaMigrator.currentVersion(of: database), 0)
    }

    func testMigratingAFreshStoreRecordsTheVersionRow() throws {
        let outcome = try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")

        XCTAssertEqual(outcome.previousVersion, 0)
        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(outcome.appliedMigrationNames, SchemaMigrator.migrations.map(\.name))
        XCTAssertFalse(outcome.wasAlreadyCurrent)

        XCTAssertEqual(try SchemaMigrator.currentVersion(of: database), SchemaMigrator.latestVersion)
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM schema_version;"), 1)
        XCTAssertEqual(try database.scalarText("SELECT app_version FROM schema_version WHERE id = 1;"), "1.0 (1)")

        let appliedAt = try XCTUnwrap(
            try database.scalarText("SELECT applied_at FROM schema_version WHERE id = 1;")
        )
        XCTAssertNotNil(ISO8601DateFormatter().date(from: appliedAt), "applied_at must be ISO 8601: \(appliedAt)")
    }

    func testSecondMigrationIsANoOp() throws {
        try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")
        let firstAppliedAt = try database.scalarText("SELECT applied_at FROM schema_version WHERE id = 1;")

        let outcome = try SchemaMigrator.migrate(database, appVersion: "1.0 (2)")

        XCTAssertTrue(outcome.wasAlreadyCurrent)
        XCTAssertEqual(outcome.previousVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(
            try database.scalarText("SELECT applied_at FROM schema_version WHERE id = 1;"),
            firstAppliedAt,
            "An up-to-date store must not be rewritten"
        )
    }

    func testAdditionalMigrationsApplyForwardOnly() throws {
        try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")

        let extended = SchemaMigrator.migrations + [
            Migration(version: SchemaMigrator.latestVersion + 1, name: "add_probe_table") { db in
                try db.executeScript("CREATE TABLE probe (id INTEGER PRIMARY KEY) STRICT;")
            }
        ]

        let outcome = try SchemaMigrator.migrate(database, appVersion: "1.1 (5)", migrations: extended)

        XCTAssertEqual(outcome.previousVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion + 1)
        XCTAssertEqual(outcome.appliedMigrationNames, ["add_probe_table"])
        XCTAssertTrue(try database.tableExists("probe"))
    }

    func testStoreFromANewerBuildIsRefusedNotDowngraded() throws {
        let future = SchemaMigrator.migrations + [
            Migration(version: SchemaMigrator.latestVersion + 1, name: "future_step") { db in
                try db.executeScript("CREATE TABLE future_table (id INTEGER PRIMARY KEY) STRICT;")
            }
        ]
        try SchemaMigrator.migrate(database, appVersion: "2.0 (9)", migrations: future)

        XCTAssertThrowsError(try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")) { error in
            guard case StoreError.storeWrittenByNewerApp(let stored, let supported) = error else {
                return XCTFail("Expected storeWrittenByNewerApp, got \(error)")
            }
            XCTAssertEqual(stored, SchemaMigrator.latestVersion + 1)
            XCTAssertEqual(supported, SchemaMigrator.latestVersion)
        }

        // Refusing must not touch the store.
        XCTAssertTrue(try database.tableExists("future_table"))
        XCTAssertEqual(
            try SchemaMigrator.currentVersion(of: database),
            SchemaMigrator.latestVersion + 1
        )
    }

    func testAFailingMigrationLeavesTheStoreUntouched() throws {
        struct Boom: Error {}

        let broken = SchemaMigrator.migrations + [
            Migration(version: SchemaMigrator.latestVersion + 1, name: "adds_a_table") { db in
                try db.executeScript("CREATE TABLE half_applied (id INTEGER PRIMARY KEY) STRICT;")
            },
            Migration(version: SchemaMigrator.latestVersion + 2, name: "then_explodes") { _ in
                throw Boom()
            }
        ]

        XCTAssertThrowsError(
            try SchemaMigrator.migrate(database, appVersion: "1.0 (1)", migrations: broken)
        ) { error in
            guard case StoreError.migrationFailed(let version, let name, _) = error else {
                return XCTFail("Expected migrationFailed, got \(error)")
            }
            XCTAssertEqual(version, SchemaMigrator.latestVersion + 2)
            XCTAssertEqual(name, "then_explodes")
        }

        XCTAssertFalse(
            try database.tableExists("half_applied"),
            "The whole pending chain must roll back, not just the failing step"
        )
        XCTAssertEqual(
            try SchemaMigrator.currentVersion(of: database),
            0,
            "A store that failed its first migration must stay fresh"
        )
    }

    func testMissingVersionRowIsReportedNotGuessed() throws {
        try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")
        try database.executeScript("DELETE FROM schema_version;")

        XCTAssertThrowsError(try SchemaMigrator.currentVersion(of: database)) { error in
            XCTAssertEqual(error as? StoreError, .schemaVersionUnreadable)
        }
    }
}
