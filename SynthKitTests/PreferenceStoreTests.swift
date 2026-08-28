import XCTest
@testable import SynthKit

/// The humanization setting has to survive a relaunch (REQ-012) and must never
/// be able to stop a piece from playing.
final class PreferenceStoreTests: XCTestCase {
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

    private func openStore() throws -> LibraryStore {
        try LibraryStore.open(container: container, appVersion: "1.0 (1)")
    }

    // MARK: The migration

    func testTheStoreCarriesThePreferencesTable() throws {
        let store = try openStore()
        defer { store.close() }
        XCTAssertTrue(try store.database.tableExists(PreferenceStore.tableName))
    }

    /// Forward-only and additive: a store written by the previous build opens
    /// and gains the table without losing its pieces.
    func testAStoreAtTheEarlierSchemaMigratesForwardWithoutLosingPieces() throws {
        let earlier = Array(SchemaMigrator.migrations.prefix(2))
        XCTAssertEqual(earlier.last?.version, 2)

        let database = try SQLiteDatabase.open(at: sandboxRoot.appending(path: "earlier.sqlite"))
        try SchemaMigrator.migrate(database, appVersion: "0.9 (1)", migrations: earlier)
        try database.execute(
            """
            INSERT INTO pieces (
                id, title, composer, work_title, work_number, movement_title,
                movement_number, source_file_name, source_format,
                content_file_name, content_sha256, content_byte_count, imported_at
            ) VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text("piece-1"), .text("Kept"), .text("kept.musicxml"),
                .text("musicxml"), .text("kept-content.musicxml"), .text("abc123"),
                .integer(12), .text("2026-01-01T00:00:00Z")
            ]
        )
        XCTAssertFalse(try database.tableExists(PreferenceStore.tableName))

        let outcome = try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")
        defer { database.close() }

        XCTAssertEqual(outcome.previousVersion, 2)
        XCTAssertEqual(outcome.currentVersion, SchemaMigrator.latestVersion)
        // Every step from 3 onwards, whatever later leaves have added since.
        // Naming only `create_preferences` here would make this test fail on
        // the next additive migration while proving nothing more about the one
        // it is actually about.
        XCTAssertEqual(
            outcome.appliedMigrationNames,
            SchemaMigrator.migrations.filter { $0.version > 2 }.map(\.name)
        )
        XCTAssertTrue(outcome.appliedMigrationNames.contains("create_preferences"))
        XCTAssertTrue(try database.tableExists(PreferenceStore.tableName))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM pieces;"), 1)
        XCTAssertEqual(
            try database.scalarText("SELECT title FROM pieces WHERE id = 'piece-1';"),
            "Kept"
        )
    }

    // MARK: Humanization

    func testAFreshLibraryUsesTheShippedHumanizationDefault() throws {
        let store = try openStore()
        defer { store.close() }
        XCTAssertEqual(store.preferences.humanization(), .standard)
        XCTAssertTrue(HumanizationSettings.standard.isEnabled)
    }

    func testTheHumanizationChoiceSurvivesAClosedAndReopenedStore() throws {
        let chosen = HumanizationSettings(isEnabled: true, intensity: 75)

        let first = try openStore()
        try first.preferences.setHumanization(chosen)
        XCTAssertEqual(first.preferences.humanization(), chosen)
        first.close()

        let second = try openStore()
        defer { second.close() }
        XCTAssertEqual(second.preferences.humanization(), chosen)
    }

    func testTurningHumanizationOffPersistsAsOff() throws {
        let first = try openStore()
        try first.preferences.setHumanization(.off)
        first.close()

        let second = try openStore()
        defer { second.close() }
        XCTAssertEqual(second.preferences.humanization(), .off)
        XCTAssertTrue(second.preferences.humanization().isLiteral)
    }

    /// Rewriting must replace, not accumulate: the table is keyed, and a second
    /// write of the same key has to win.
    func testWritingTheChoiceTwiceKeepsOneRowPerKey() throws {
        let store = try openStore()
        defer { store.close() }

        try store.preferences.setHumanization(HumanizationSettings(isEnabled: true, intensity: 10))
        try store.preferences.setHumanization(HumanizationSettings(isEnabled: false, intensity: 90))

        XCTAssertEqual(
            store.preferences.humanization(),
            HumanizationSettings(isEnabled: false, intensity: 90)
        )
        XCTAssertEqual(
            try store.database.scalarInt("SELECT COUNT(*) FROM \(PreferenceStore.tableName);"),
            2
        )
    }

    // MARK: A damaged preference is never fatal

    func testAnUnreadableStoredValueFallsBackToTheDefault() throws {
        let store = try openStore()
        defer { store.close() }

        try store.preferences.setString("maybe", forKey: PreferenceStore.humanizationEnabledKey)
        XCTAssertEqual(
            store.preferences.humanization(),
            .standard,
            "a corrupt preference must give the default interpretation, never an unplayable piece"
        )
    }

    func testAnAbsurdStoredIntensityIsClampedRatherThanRefused() throws {
        let store = try openStore()
        defer { store.close() }

        try store.preferences.setString("1", forKey: PreferenceStore.humanizationEnabledKey)
        try store.preferences.setString("900", forKey: PreferenceStore.humanizationIntensityKey)
        XCTAssertEqual(store.preferences.humanization().intensity, 100)

        try store.preferences.setString("-4", forKey: PreferenceStore.humanizationIntensityKey)
        XCTAssertEqual(store.preferences.humanization().intensity, 0)
    }

    func testAMissingIntensityFallsBackToTheDefaultAmount() throws {
        let store = try openStore()
        defer { store.close() }

        try store.preferences.setString("1", forKey: PreferenceStore.humanizationEnabledKey)
        XCTAssertEqual(
            store.preferences.humanization(),
            HumanizationSettings(isEnabled: true, intensity: HumanizationSettings.standard.intensity)
        )
    }

    // MARK: Raw key-value access

    func testAnArbitraryPreferenceRoundTripsAndCanBeRemoved() throws {
        let store = try openStore()
        defer { store.close() }

        XCTAssertNil(try store.preferences.string(forKey: "probe"))
        try store.preferences.setString("value", forKey: "probe")
        XCTAssertEqual(try store.preferences.string(forKey: "probe"), "value")
        try store.preferences.remove(key: "probe")
        XCTAssertNil(try store.preferences.string(forKey: "probe"))
    }
}
