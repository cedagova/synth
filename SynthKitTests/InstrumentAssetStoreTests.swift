import Foundation
import XCTest
@testable import SynthKit

/// The installed-instrument store: the v6 migration, the offline read path, and
/// the sentences the catalog UI speaks.
final class InstrumentAssetStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "synth-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Migration

    func testSchemaSixIsAdditiveAndLeavesAnIncrementFourStoreOpenable() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()

        // Build a store at exactly the increment-004 schema, with content in
        // every table a later build must not disturb.
        let atFive = try SQLiteDatabase.open(at: container.databaseURL)
        try atFive.executeScript("PRAGMA foreign_keys = ON;")
        let outcomeFive = try SchemaMigrator.migrate(
            atFive,
            appVersion: "increment-004",
            migrations: Array(SchemaMigrator.migrations.prefix(5))
        )
        XCTAssertEqual(outcomeFive.currentVersion, 5)

        try atFive.execute(
            """
            INSERT INTO pieces (id, title, source_file_name, source_format,
                content_file_name, content_sha256, content_byte_count, imported_at)
            VALUES ('p1', 'A Fugue', 'f.musicxml', 'musicxml', 'p1.musicxml', 'abc', 10, '2026-01-01T00:00:00Z');
            """
        )
        try atFive.execute(
            """
            INSERT INTO presets (id, piece_id, name, is_active, document_version,
                document, revision, created_at, updated_at)
            VALUES ('r1', 'p1', 'Default', 1, 1, '{}', 3, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
            """
        )
        try atFive.execute(
            "INSERT INTO preferences (key, value, updated_at) VALUES ('k', 'v', '2026-01-01T00:00:00Z');"
        )
        atFive.close()

        // Now open with this build's full chain. INS003 added `add_sound_kind`
        // behind this step, so the chain from an increment-004 store is both of
        // increment 005's migrations rather than one.
        let atSix = try SQLiteDatabase.open(at: container.databaseURL)
        try atSix.executeScript("PRAGMA foreign_keys = ON;")
        defer { atSix.close() }
        let outcomeSix = try SchemaMigrator.migrate(atSix, appVersion: "increment-005")

        XCTAssertEqual(outcomeSix.previousVersion, 5)
        XCTAssertEqual(outcomeSix.currentVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(
            outcomeSix.appliedMigrationNames,
            ["create_installed_instrument_libraries", "add_sound_kind"]
        )

        // Everything increment 004 wrote is exactly where it was.
        XCTAssertEqual(try atSix.scalarInt("SELECT count(*) FROM pieces;"), 1)
        XCTAssertEqual(try atSix.scalarText("SELECT title FROM pieces WHERE id = 'p1';"), "A Fugue")
        XCTAssertEqual(try atSix.scalarInt("SELECT revision FROM presets WHERE id = 'r1';"), 3)
        XCTAssertEqual(try atSix.scalarText("SELECT value FROM preferences WHERE key = 'k';"), "v")

        // And the new table is there and empty.
        XCTAssertTrue(try atSix.tableExists(InstrumentAssetStore.tableName))
        XCTAssertEqual(
            try atSix.scalarInt("SELECT count(*) FROM \(InstrumentAssetStore.tableName);"), 0
        )
    }

    func testMigratingTwiceChangesNothing() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }

        try SchemaMigrator.migrate(database, appVersion: "one")
        let second = try SchemaMigrator.migrate(database, appVersion: "two")
        XCTAssertTrue(second.wasAlreadyCurrent)
        XCTAssertEqual(second.currentVersion, SchemaMigrator.latestVersion)
    }

    func testEveryStoreOpenedByTheAppCanAnswerWhichInstrumentsAreInstalled() throws {
        // The store must not be constructible without its instrument half, for
        // the same reason it cannot be constructed without its presets.
        let store = try LibraryStore.open(
            container: AppContainer(rootURL: root.appending(path: "Synth")),
            appVersion: "test"
        )
        defer { store.close() }
        XCTAssertEqual(store.schemaVersion, SchemaMigrator.latestVersion)
        XCTAssertTrue(try store.instruments.installedLibraries().isEmpty)
        XCTAssertTrue(try store.instruments.availableInstruments().isEmpty)
    }

    // MARK: The offline read path

    /// A library laid out on disk by hand, so the read path is tested without a
    /// transfer of any kind existing anywhere near it.
    private func installByHand(
        _ library: CatalogLibrary, into assetsURL: URL, store: InstrumentAssetStore
    ) throws {
        let root = assetsURL.appending(path: library.identifier)
        for instrument in library.coverage {
            for path in instrument.allSFZPaths {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("<control>\n".utf8).write(to: url)
            }
        }
        try store.recordInstall(of: library)
    }

    private func fixtureLibrary(
        identifier: String = "offline-lib",
        family: InstrumentCoverage.Family = .keyboards,
        attribution: String = ""
    ) -> CatalogLibrary {
        CatalogLibrary(
            identifier: identifier,
            name: "Offline Fixture",
            publisher: "A Publisher",
            summary: "A library.",
            licence: InstrumentLicence(
                spdxIdentifier: attribution.isEmpty ? "CC0-1.0" : "CC-BY-4.0",
                name: attribution.isEmpty ? "CC0 1.0" : "CC BY 4.0",
                textURL: "https://creativecommons.org/",
                requiredAttribution: attribution,
                redistribution: .mirrorable
            ),
            homepageURL: "https://example.invalid/",
            assets: [
                CatalogAsset(
                    identifier: "primary.sfz",
                    sourceURL: "https://example.invalid/primary.sfz",
                    byteCount: 10,
                    digest: .sha256(String(repeating: "c", count: 64)),
                    payload: .file(path: "primary.sfz")
                )
            ],
            coverage: [
                InstrumentCoverage(
                    identifier: "\(identifier).instrument",
                    name: "Fixture instrument",
                    family: family,
                    sfzPath: "primary.sfz",
                    alternateSFZPaths: ["alternate.sfz"],
                    dynamicLayerCount: 3
                )
            ]
        )
    }

    func testAnInstalledInstrumentResolvesWithNothingButTheDiskAndTheDatabase() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary(attribution: "Credit where it is due.")
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )
        try installByHand(library, into: container.assetsURL, store: store)

        // Nothing in this call can reach the network — the store holds no
        // transfer at all, which is the structural half of REQ-022.
        let instruments = try store.availableInstruments()
        XCTAssertEqual(instruments.count, 1)
        let instrument = try XCTUnwrap(instruments.first)

        XCTAssertEqual(instrument.libraryID, library.identifier)
        XCTAssertEqual(instrument.coverage.dynamicLayerCount, 3)
        XCTAssertEqual(instrument.requiredAttribution, "Credit where it is due.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: instrument.sfzURL.path(percentEncoded: false)),
            "The resolved SFZ URL does not point at a real file."
        )
        XCTAssertEqual(instrument.alternateSFZURLs.count, 1)
        XCTAssertEqual(
            instrument.libraryRootURL,
            container.assetsURL.appending(path: library.identifier),
            "An SFZ's default_path is resolved against this, so it has to be the library root."
        )

        let attributions = try store.requiredAttributions()
        XCTAssertEqual(attributions.count, 1)
        XCTAssertEqual(attributions.first?.attribution, "Credit where it is due.")
    }

    func testAnAlternateArticulationThatIsNotOnDiskIsNotOffered() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary()
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )
        try installByHand(library, into: container.assetsURL, store: store)

        try FileManager.default.removeItem(
            at: container.assetsURL
                .appending(path: library.identifier)
                .appending(path: "alternate.sfz")
        )

        let instrument = try XCTUnwrap(try store.availableInstruments().first)
        XCTAssertTrue(
            instrument.alternateSFZURLs.isEmpty,
            "An articulation whose file is missing must not be handed to the player."
        )
    }

    func testAPrimarySFZThatIsMissingWithdrawsTheWholeInstrument() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary()
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )
        try installByHand(library, into: container.assetsURL, store: store)
        try FileManager.default.removeItem(
            at: container.assetsURL
                .appending(path: library.identifier)
                .appending(path: "primary.sfz")
        )

        XCTAssertTrue(
            try store.availableInstruments().isEmpty,
            "An instrument with no entry point must not be offered as playable."
        )
    }

    func testFamiliesWithNothingInstalledAreReportedForINS003() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary(family: .brass)
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )

        XCTAssertEqual(
            Set(try store.familiesWithoutAnInstalledInstrument()),
            Set(InstrumentCoverage.Family.allCases),
            "With nothing installed, every family is missing."
        )

        try installByHand(library, into: container.assetsURL, store: store)
        let missing = Set(try store.familiesWithoutAnInstalledInstrument())
        XCTAssertFalse(missing.contains(.brass))
        XCTAssertTrue(missing.contains(.strings))
    }

    func testAnInstallFromAnotherCatalogPinningIsReportedRatherThanTrusted() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary()
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )
        try installByHand(library, into: container.assetsURL, store: store)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The hand-built install did not register.")
        }

        // A later build that re-pins the same library to different bytes.
        let repinned = CatalogLibrary(
            identifier: library.identifier, name: library.name, publisher: library.publisher,
            summary: library.summary, licence: library.licence, homepageURL: library.homepageURL,
            assets: [
                CatalogAsset(
                    identifier: "primary.sfz",
                    sourceURL: "https://example.invalid/primary-v2.sfz",
                    byteCount: 20,
                    digest: .sha256(String(repeating: "d", count: 64)),
                    payload: .file(path: "primary.sfz")
                )
            ],
            coverage: library.coverage
        )
        let laterStore = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [repinned]
        )
        guard case .installedFromAnotherCatalog = try laterStore.state(of: repinned) else {
            return XCTFail("A stale install was reported as current.")
        }
        XCTAssertEqual(
            InstrumentCatalogDisplay.primaryActionTitle(
                for: try laterStore.state(of: repinned)
            ),
            "Download Again"
        )
    }

    func testStagingForALibraryTheCatalogNoLongerHasIsCleanedUp() throws {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")

        let library = fixtureLibrary()
        let store = InstrumentAssetStore(
            database: database, assetsRootURL: container.assetsURL, catalog: [library]
        )
        let staging = store.stagingArea

        // Debris from a build whose catalog had another library, plus a real
        // in-flight part for one this build still knows about.
        try staging.prepareStaging(forLibraryID: "a-library-that-is-gone")
        try staging.prepareStaging(forLibraryID: library.identifier)
        let keptPart = try staging.openPart(
            forLibraryID: library.identifier, assetID: "primary.sfz"
        )
        try keptPart.append(Data(repeating: 0, count: 5))
        try keptPart.close()

        try store.reconcileWithDisk()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staging.stagingURL(forLibraryID: "a-library-that-is-gone")
                    .path(percentEncoded: false)
            ),
            "Staging for a library this build does not know was kept."
        )
        XCTAssertEqual(
            staging.stagedByteCount(forLibraryID: library.identifier, assetID: "primary.sfz"), 5,
            "Cleaning up threw away a resumable download, which is the one thing it must not do."
        )
    }

    // MARK: Promotion

    func testPromotingAReplacementKeepsTheOldLibraryIfTheMoveFails() throws {
        let assets = root.appending(path: "assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let staging = AssetStagingArea(assetsRootURL: assets)

        // An existing install with a recognisable file in it.
        let installed = staging.installedURL(forLibraryID: "lib")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appending(path: "marker.txt"))

        // Nothing staged: promotion must refuse rather than destroy what is there.
        XCTAssertThrowsError(try staging.promoteStagedInstall(libraryID: "lib"))
        XCTAssertEqual(
            try String(contentsOf: installed.appending(path: "marker.txt"), encoding: .utf8),
            "old",
            "A failed promotion removed the working library."
        )

        // A real staged replacement does take over.
        try staging.prepareStaging(forLibraryID: "lib")
        try Data("new".utf8).write(
            to: staging.stagingURL(forLibraryID: "lib").appending(path: "marker.txt")
        )
        try staging.promoteStagedInstall(libraryID: "lib")
        XCTAssertEqual(
            try String(contentsOf: installed.appending(path: "marker.txt"), encoding: .utf8),
            "new"
        )
    }

    // MARK: What the UI says

    func testTheStatusLineSaysSomethingTrueInEveryState() throws {
        let library = fixtureLibrary()

        XCTAssertEqual(
            InstrumentCatalogDisplay.status(of: .notDownloaded, in: library),
            "Not downloaded — 10 bytes"
        )
        XCTAssertTrue(
            InstrumentCatalogDisplay
                .status(of: .partiallyDownloaded(stagedByteCount: 5), in: library)
                .contains("50%")
        )

        let record = InstalledInstrumentLibrary(
            libraryID: library.identifier, catalogVersion: 1, installedAt: "now",
            byteCount: 10, assetCount: 1, pinnedManifestDigest: library.pinnedManifestDigest
        )
        XCTAssertTrue(
            InstrumentCatalogDisplay.status(of: .installed(record), in: library)
                .contains("1 instrument across keyboards")
        )
        XCTAssertTrue(
            InstrumentCatalogDisplay.status(of: .installedFromAnotherCatalog(record), in: library)
                .contains("older version")
        )
    }

    func testTheCoverageSummaryNamesWhatIsMissingRatherThanJustCounting() {
        XCTAssertTrue(
            InstrumentCatalogDisplay.coverageSummary(installedFamilies: []).contains("synth sounds")
        )
        XCTAssertEqual(
            InstrumentCatalogDisplay.coverageSummary(
                installedFamilies: Set(InstrumentCoverage.Family.allCases),
                uncoveredInstruments: []
            ),
            "Everything this version can download is here."
        )
        let partial = InstrumentCatalogDisplay.coverageSummary(
            installedFamilies: Set(InstrumentCoverage.Family.allCases).subtracting([.harp, .brass])
        )
        XCTAssertTrue(partial.contains("brass"))
        XCTAssertTrue(partial.contains("harp"))
        XCTAssertTrue(partial.contains("synth sound"))
    }

    func testALicenceLineSaysWhetherAnythingIsOwed() {
        XCTAssertTrue(
            InstrumentCatalogDisplay.licence(CuratedInstrumentLibraries.vsco2CommunityEdition)
                .contains("nothing is owed")
        )
        XCTAssertTrue(
            InstrumentCatalogDisplay.licence(CuratedInstrumentLibraries.salamanderGrandPiano)
                .contains("must credit")
        )
        XCTAssertNil(
            InstrumentCatalogDisplay.attribution(CuratedInstrumentLibraries.vsco2CommunityEdition)
        )
        XCTAssertEqual(
            InstrumentCatalogDisplay.attribution(CuratedInstrumentLibraries.salamanderGrandPiano),
            "Salamander Grand Piano V3 by Alexander Holm, licensed CC BY 3.0."
        )
    }

    func testADiskFullFailureIsRenderedAsSomethingTheOwnerCanActON() {
        let rendered = InstrumentCatalogDisplay.failure(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        )
        XCTAssertTrue(rendered.summary.contains("space"))
        XCTAssertTrue(rendered.isRetryable)
        XCTAssertNotNil(rendered.recovery)

        let gone = InstrumentCatalogDisplay.failure(
            AssetTransferError.sourceRefused(host: "example.invalid", statusCode: 404)
        )
        XCTAssertFalse(gone.isRetryable, "A 404 must not offer a Retry that cannot work.")

        let dropped = InstrumentCatalogDisplay.failure(
            AssetTransferError.sourceUnreachable(host: "example.invalid", reason: "offline")
        )
        XCTAssertTrue(dropped.isRetryable)
    }

    func testProgressReadsAsProgressRatherThanAsNumbers() {
        let mid = InstrumentDownloadProgress(
            libraryID: "l", completedByteCount: 500_000_000, totalByteCount: 2_600_000_000,
            completedAssetCount: 900, totalAssetCount: 2_539, phase: .downloading
        )
        let text = InstrumentCatalogDisplay.progress(mid)
        XCTAssertTrue(text.contains("Downloading"))
        XCTAssertTrue(text.contains("of"))
        XCTAssertTrue(text.contains("2,539") || text.contains("2539"))
        XCTAssertEqual(mid.fraction, 500_000_000.0 / 2_600_000_000.0, accuracy: 0.0001)

        XCTAssertEqual(
            InstrumentCatalogDisplay.progress(
                InstrumentDownloadProgress(
                    libraryID: "l", completedByteCount: 1, totalByteCount: 1,
                    completedAssetCount: 1, totalAssetCount: 1, phase: .finished
                )
            ),
            "Done"
        )
    }
}
