import XCTest
@testable import SynthKit

/// #97: an existing library is copied to `backups/` before any pending schema
/// migration runs, and is not migrated if that copy fails.
final class LibraryBackupTests: XCTestCase {
    private var sandboxRoot: URL!
    private var container: AppContainer!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    // MARK: Acceptance

    /// A populated library at the shipped schema is v(n-1) for a chain one
    /// step longer. Migrating it must leave a backup that opens at v(n-1)
    /// holding every row of every table exactly as it was.
    func testMigratingAPopulatedLibraryLeavesABackupAtTheOldVersionWithIdenticalRows() throws {
        let previous = SchemaMigrator.latestVersion
        try populateLibrary()
        let before = try TableContents.capture(at: container.databaseURL)
        XCTAssertGreaterThan(before.rowCount, 3, "The fixture must hold real rows")

        let store = try LibraryStore.open(
            container: container,
            appVersion: "test",
            fileManager: .default,
            dependentStores: [],
            soundDependentStores: [],
            migrations: SchemaMigrator.migrations + [Self.rewritingMigration(version: previous + 1)]
        )
        let outcome = store.migrationOutcome
        store.close()

        XCTAssertEqual(outcome.previousVersion, previous)
        XCTAssertEqual(outcome.currentVersion, previous + 1)
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertNil(backup.pruningFailure)
        XCTAssertEqual(backup.backupURL.deletingLastPathComponent().lastPathComponent, "backups")
        XCTAssertTrue(backup.backupURL.lastPathComponent.hasPrefix("library-v\(previous)-"))
        XCTAssertEqual(
            try LibraryBackup.backups(in: container.backupsURL).map(\.lastPathComponent),
            [backup.backupURL.lastPathComponent]
        )

        // The live store really changed, so equality below is not vacuous.
        let after = try TableContents.capture(at: container.databaseURL)
        XCTAssertNotEqual(after, before)

        let backedUp = try SQLiteDatabase.open(at: backup.backupURL)
        defer { backedUp.close() }
        XCTAssertEqual(try SchemaMigrator.currentVersion(of: backedUp), previous)
        XCTAssertEqual(try TableContents.capture(backedUp), before)
    }

    /// The same promise through the shipped chain itself: a store built by
    /// every migration but the last is backed up at that version.
    func testTheShippedChainBacksUpAStoreOneVersionBehind() throws {
        let previous = SchemaMigrator.latestVersion - 1
        try container.prepare()
        do {
            let database = try SQLiteDatabase.open(at: container.databaseURL)
            defer { database.close() }
            try SchemaMigrator.migrate(
                database, appVersion: "old", migrations: Array(SchemaMigrator.migrations.dropLast())
            )
            try PreferenceStore(database: database).setString("kept", forKey: "probe")
        }
        let before = try TableContents.capture(at: container.databaseURL)

        let store = try LibraryStore.open(container: container, appVersion: "test")
        let outcome = store.migrationOutcome
        store.close()

        XCTAssertEqual(outcome.previousVersion, previous)
        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion)
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertTrue(backup.backupURL.lastPathComponent.hasPrefix("library-v\(previous)-"))

        let backedUp = try SQLiteDatabase.open(at: backup.backupURL)
        defer { backedUp.close() }
        XCTAssertEqual(try SchemaMigrator.currentVersion(of: backedUp), previous)
        XCTAssertEqual(try TableContents.capture(backedUp), before)
    }

    // MARK: Refusal

    func testABackupThatCannotBeWrittenRefusesTheMigrationAndNamesTheBackup() throws {
        let previous = SchemaMigrator.latestVersion
        try populateLibrary()
        let before = try TableContents.capture(at: container.databaseURL)

        // Something that is not a folder sits where backups/ must go.
        try Data("not a folder".utf8).write(to: container.backupsURL)

        XCTAssertThrowsError(
            try LibraryStore.open(
                container: container,
                appVersion: "test",
                fileManager: .default,
                dependentStores: [],
                soundDependentStores: [],
                migrations: SchemaMigrator.migrations + [Self.rewritingMigration(version: previous + 1)]
            )
        ) { error in
            guard case StoreError.migrationBackupFailed(let path, let reason) = error else {
                return XCTFail("Expected migrationBackupFailed, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".sqlite"), path)
            XCTAssertTrue(path.contains("/backups/library-v\(previous)-"), path)
            XCTAssertFalse(reason.isEmpty)
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("backups/library-v\(previous)-"), message)
        }

        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        XCTAssertEqual(try SchemaMigrator.currentVersion(of: database), previous, "The store must stay unmigrated")
        XCTAssertEqual(try TableContents.capture(database), before)
    }

    // MARK: Retention

    func testAFourthBackupPrunesTheOldestAndOnlyBackups() throws {
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        let backups = container.backupsURL
        try SchemaMigrator.migrate(database, appVersion: "test", backupsDirectory: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path(percentEncoded: false)))

        // Files that are not backups must survive pruning, including ones
        // that nearly match the pattern.
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let bystanders = ["notes.txt", "library-v1-latest.sqlite", "library-v2-20000101T000000000Z.sqlite.bak"]
        for name in bystanders {
            try Data(name.utf8).write(to: backups.appending(path: name))
        }

        var chain = SchemaMigrator.migrations
        var written: [URL] = []
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for step in 0..<4 {
            chain.append(Self.rewritingMigration(version: chain.count + 1))
            let outcome = try SchemaMigrator.migrate(
                database,
                appVersion: "test",
                migrations: chain,
                backupsDirectory: backups,
                now: start.addingTimeInterval(Double(step) * 60)
            )
            let backup = try XCTUnwrap(outcome.backup)
            XCTAssertNil(backup.pruningFailure)
            written.append(backup.backupURL)
        }

        XCTAssertEqual(
            try LibraryBackup.backups(in: backups).map(\.lastPathComponent),
            written.suffix(3).reversed().map(\.lastPathComponent),
            "The newest three are kept, the oldest pruned"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[0].path(percentEncoded: false)))
        for name in bystanders {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: backups.appending(path: name).path(percentEncoded: false)),
                "\(name) is not a backup and must not be pruned"
            )
        }
    }

    /// Backups dated in the future (a clock that once ran ahead) must never
    /// cause the backup just written to be pruned: the store is about to be
    /// migrated and that copy is its only way back.
    func testTheJustWrittenBackupSurvivesFutureDatedBackups() throws {
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let backups = container.backupsURL
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var future: [String] = []
        for day in 1...LibraryBackup.retainedCount {
            let name = LibraryBackup.fileName(
                schemaVersion: 1, date: now.addingTimeInterval(Double(day) * 86_400)
            )
            try Data("future".utf8).write(to: backups.appending(path: name))
            future.append(name)
        }

        let outcome = try SchemaMigrator.migrate(
            database,
            appVersion: "test",
            migrations: SchemaMigrator.migrations + [Self.rewritingMigration(version: SchemaMigrator.latestVersion + 1)],
            backupsDirectory: backups,
            now: now
        )

        let written = try XCTUnwrap(outcome.backup).backupURL.lastPathComponent
        let kept = try LibraryBackup.backups(in: backups).map(\.lastPathComponent)
        XCTAssertEqual(kept.count, LibraryBackup.retainedCount)
        XCTAssertTrue(kept.contains(written), "The pre-migration backup must survive pruning")
        XCTAssertEqual(
            Set(kept), Set([written] + future.suffix(LibraryBackup.retainedCount - 1)),
            "The rest are the newest others; the oldest future-dated one is pruned"
        )
    }

    func testAPruningFailureDoesNotBlockTheMigrationAndIsReported() throws {
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let backups = container.backupsURL
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for minute in 0..<LibraryBackup.retainedCount {
            let name = LibraryBackup.fileName(
                schemaVersion: 1, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60)
            )
            try Data("old".utf8).write(to: backups.appending(path: name))
        }

        let outcome = try SchemaMigrator.migrate(
            database,
            appVersion: "test",
            migrations: SchemaMigrator.migrations + [Self.rewritingMigration(version: SchemaMigrator.latestVersion + 1)],
            backupsDirectory: backups,
            fileManager: RefusingRemovalFileManager()
        )

        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion + 1, "Pruning must not block")
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertNotNil(backup.pruningFailure, "A pruning failure must not be silent")
        XCTAssertEqual(try LibraryBackup.backups(in: backups).count, LibraryBackup.retainedCount + 1)
    }

    // MARK: No backup

    func testABrandNewLibraryCreatesNoBackup() throws {
        let store = try LibraryStore.open(container: container, appVersion: "test")
        XCTAssertEqual(store.migrationOutcome.previousVersion, 0)
        XCTAssertNil(store.migrationOutcome.backup)
        store.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: container.backupsURL.path(percentEncoded: false)))
    }

    func testAnUpToDateLibraryCreatesNoBackup() throws {
        try LibraryStore.open(container: container, appVersion: "test").close()
        let store = try LibraryStore.open(container: container, appVersion: "test")
        XCTAssertTrue(store.migrationOutcome.wasAlreadyCurrent)
        XCTAssertNil(store.migrationOutcome.backup)
        store.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: container.backupsURL.path(percentEncoded: false)))
    }

    func testBackupNamesSortByTimeAndRejectLookalikes() {
        let name = LibraryBackup.fileName(schemaVersion: 7, date: Date(timeIntervalSince1970: 1_800_000_000.25))
        XCTAssertEqual(name, "library-v7-20270115T080000250Z.sqlite")
        XCTAssertEqual(LibraryBackup.timestampComponent(of: name), "20270115T080000250Z")
        for lookalike in [
            "library-v-20270115T080000250Z.sqlite",
            "library-v7-20270115T080000Z.sqlite",
            "library-vx-20270115T080000250Z.sqlite",
            "library-v7-20270115T080000250Z.sqlite.partial",
            ".library-v7-20270115T080000250Z.sqlite.partial",
            "library.sqlite"
        ] {
            XCTAssertNil(LibraryBackup.timestampComponent(of: lookalike), lookalike)
        }
    }

    // MARK: Fixtures

    /// A library at the shipped schema with a piece, a sound, a preset and a
    /// preference in it.
    private func populateLibrary() throws {
        let store = try LibraryStore.open(container: container, appVersion: "fixture")
        defer { store.close() }
        let source = sandboxRoot.appending(path: "prelude.musicxml")
        try MusicXMLFixtures.score().write(to: source)
        try store.makeImporter().importPiece(from: source)
        _ = try store.sounds.create(patch: .defaultVoice, named: "Made Before", in: .pads)
        try store.preferences.setString("kept", forKey: "probe")
    }

    /// A migration past the shipped chain that changes existing rows and the
    /// schema, so the live store and its backup visibly diverge.
    private static func rewritingMigration(version: Int) -> Migration {
        Migration(version: version, name: "probe_\(version)") { database in
            try database.executeScript(
                """
                CREATE TABLE probe_\(version) (id INTEGER PRIMARY KEY) STRICT;
                INSERT INTO probe_\(version) (id) VALUES (\(version));
                UPDATE preferences SET value = value || '+\(version)';
                """
            )
        }
    }
}

/// Every row of every table, rendered with SQLite's own `quote()` so integers,
/// reals, text, blobs and NULL all compare exactly.
private struct TableContents: Equatable {
    let tables: [String: [String]]

    var rowCount: Int { tables.values.map(\.count).reduce(0, +) }

    static func capture(at url: URL) throws -> TableContents {
        let database = try SQLiteDatabase.open(at: url)
        defer { database.close() }
        return try capture(database)
    }

    static func capture(_ database: SQLiteDatabase) throws -> TableContents {
        let names = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
        ).compactMap { $0.text("name") }

        var tables: [String: [String]] = [:]
        for name in names {
            let columns = try database.query("SELECT name FROM pragma_table_info(?);", [.text(name)])
                .compactMap { $0.text("name") }
            let row = columns.map { "quote(\"\($0)\")" }.joined(separator: " || '|' || ")
            tables[name] = try database.query("SELECT \(row) AS r FROM \"\(name)\" ORDER BY 1;")
                .compactMap { $0.text("r") }
        }
        return TableContents(tables: tables)
    }
}

/// Lets a backup be written but refuses to delete anything, so pruning fails.
private final class RefusingRemovalFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
