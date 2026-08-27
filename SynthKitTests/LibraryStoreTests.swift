import XCTest
@testable import SynthKit

final class LibraryStoreTests: XCTestCase {
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

    func testFirstLaunchCreatesTheContainerAndVersionedStore() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        XCTAssertEqual(store.schemaVersion, SchemaMigrator.latestVersion)
        XCTAssertFalse(store.migrationOutcome.wasAlreadyCurrent)
        XCTAssertEqual(store.migrationOutcome.previousVersion, 0)

        for directory in container.managedDirectoryURLs {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
                "Missing \(directory.lastPathComponent)"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: container.databaseURL.path(percentEncoded: false))
        )
        XCTAssertEqual(try store.storedPieceCount(), 0)
        XCTAssertNotNil(try store.schemaVersionAppliedAt())
    }

    func testRelaunchReusesTheSameContainerAndStore() throws {
        let first = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        let firstAppliedAt = try first.schemaVersionAppliedAt()
        first.close()

        let second = try LibraryStore.open(container: container, appVersion: "1.0 (2)")
        defer { second.close() }

        XCTAssertEqual(second.schemaVersion, first.schemaVersion)
        XCTAssertTrue(
            second.migrationOutcome.wasAlreadyCurrent,
            "A relaunch must reuse the existing store rather than re-migrate it"
        )
        XCTAssertEqual(try second.schemaVersionAppliedAt(), firstAppliedAt)
        XCTAssertEqual(second.container, first.container)
    }

    func testStoredPieceCountReflectsTheContainerContents() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }
        XCTAssertEqual(try store.storedPieceCount(), 0)

        try Data("<score-partwise/>".utf8)
            .write(to: container.piecesURL.appending(path: "fugue.musicxml"))
        try Data("<score-partwise/>".utf8)
            .write(to: container.piecesURL.appending(path: "quartet.musicxml"))

        XCTAssertEqual(try store.storedPieceCount(), 2)
    }

    func testWriteAheadLoggingIsEnabled() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        XCTAssertEqual(
            try store.database.scalarText("PRAGMA journal_mode;")?.lowercased(),
            "wal"
        )
        XCTAssertEqual(try store.database.scalarInt("PRAGMA foreign_keys;"), 1)
    }

    func testOpenFailureLeavesNoContainerBehind() throws {
        // The container root path is occupied by a file, so preparation fails
        // before any database is created.
        try Data("occupied".utf8).write(to: container.rootURL)

        XCTAssertThrowsError(
            try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        ) { error in
            guard case StoreError.containerPathIsNotADirectory = error else {
                return XCTFail("Expected containerPathIsNotADirectory, got \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.databaseURL.path(percentEncoded: false))
        )
    }

    func testLaunchErrorsAreOwnerReadable() {
        let errors: [StoreError] = [
            .applicationSupportUnavailable(reason: "The volume is unavailable."),
            .containerCreationFailed(path: "/tmp/Synth", reason: "The disk is full."),
            .containerPathIsNotADirectory(path: "/tmp/Synth/pieces"),
            .databaseOpenFailed(path: "/tmp/Synth/library.sqlite", code: 14, message: "unable to open"),
            .statementFailed(sql: "SELECT 1;", code: 1, message: "syntax error"),
            .storeWrittenByNewerApp(storedVersion: 4, supportedVersion: 1),
            .migrationFailed(version: 2, name: "add_pieces", reason: "The disk is full."),
            .schemaVersionUnreadable
        ]

        for error in errors {
            let description = error.errorDescription
            XCTAssertNotNil(description, "\(error) has no owner-facing description")
            XCTAssertFalse(description?.isEmpty ?? true)
            XCTAssertNotNil(error.recoverySuggestion, "\(error) has no recovery suggestion")
        }
    }

    func testErrorMessagesDoNotExposeTheAccountName() throws {
        let home = HomeRelativePath.realHomeDirectory
        let insideHome = home + "/Library/Application Support/Synth"

        let errors: [StoreError] = [
            .containerCreationFailed(path: insideHome, reason: "The disk is full."),
            .containerPathIsNotADirectory(path: insideHome),
            .databaseOpenFailed(path: insideHome, code: 14, message: "unable to open")
        ]

        for error in errors {
            let text = [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: " ")
            XCTAssertFalse(
                text.contains(home),
                "\(error) leaks the real home directory: \(text)"
            )
            XCTAssertTrue(
                text.contains("~/Library/Application Support/Synth"),
                "\(error) should show the home-relative path: \(text)"
            )
        }
    }
}
