import Foundation
import XCTest
@testable import SynthKit

/// REQ-003's store half: a removed piece is gone permanently, its dependents go
/// with it, and a failure removes nothing at all.
///
/// The confirmation REQ-003 also requires is the UI's half and is exercised in
/// the app's smoke test; nothing here can remove a piece without the caller
/// having asked for it.
final class PieceRemoverTests: XCTestCase {
    private var sandboxRoot: URL!
    private var sourceDirectory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        sourceDirectory = sandboxRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    /// Imports a real score so removal runs against real stored bytes.
    @discardableResult
    private func importScore(named name: String, workTitle: String) throws -> PieceRecord {
        let source = try writeFixture(
            MusicXMLFixtures.score(workTitle: workTitle, workNumber: nil),
            named: name,
            in: sourceDirectory
        )
        return try store.makeImporter().importPiece(from: source).piece
    }

    // MARK: - The happy path

    func testRemovingAPieceDeletesItsRecordAndItsStoredScore() throws {
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(try store.storedContentFileCount(), 1)

        try store.makeRemover().remove(piece)

        XCTAssertEqual(try store.pieceCount(), 0)
        XCTAssertEqual(try store.storedContentFileCount(), 0,
                       "The verbatim score must go with the record, not linger as debris")
        XCTAssertNil(try store.pieces.piece(withID: piece.id))
    }

    /// "The piece disappears and does not return after relaunch" (REQ-003).
    func testARemovedPieceStaysRemovedAcrossARelaunch() throws {
        let removed = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        let kept = try importScore(named: "sonata.musicxml", workTitle: "Sonata")

        try store.makeRemover().remove(removed)
        store.close()

        let reopened = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { reopened.close() }

        XCTAssertEqual(try reopened.allPieces().map(\.id), [kept.id])
        XCTAssertNil(try reopened.pieces.piece(withContentSHA256: removed.contentSHA256))
    }

    /// Removing then re-importing the same file must work: the digest index no
    /// longer holds a row for a piece that is gone.
    func testAPieceCanBeImportedAgainAfterBeingRemoved() throws {
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        try store.makeRemover().remove(piece)

        let source = sourceDirectory.appending(path: "prelude.musicxml")
        let outcome = try store.makeImporter().importPiece(from: source)

        guard case .imported(let reimported) = outcome else {
            return XCTFail("Expected a fresh import, got \(outcome)")
        }
        XCTAssertNotEqual(reimported.id, piece.id)
        XCTAssertEqual(try store.pieceCount(), 1)
    }

    func testRemovingOnePieceLeavesTheOthersUntouched() throws {
        let first = try importScore(named: "a.musicxml", workTitle: "Alborada")
        let second = try importScore(named: "b.musicxml", workTitle: "Berceuse")
        let third = try importScore(named: "c.musicxml", workTitle: "Chaconne")

        try store.makeRemover().remove(second)

        XCTAssertEqual(try store.allPieces().map(\.id).sorted(), [first.id, third.id].sorted())
        XCTAssertEqual(try store.storedContentFileCount(), 2)
    }

    // MARK: - The preset cascade (REQ-003)

    func testTheCascadeRunsForTheRemovedPieceBeforeThePieceRowGoes() throws {
        let dependent = RecordingDependentStore()
        let remover = PieceRemover(
            database: store.database,
            catalog: store.pieces,
            contentStore: store.pieceContent,
            dependentStores: [dependent]
        )
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")

        try remover.remove(piece)

        XCTAssertEqual(dependent.removedPieceIDs, [piece.id])
        XCTAssertEqual(
            dependent.pieceRowCountWhenAsked,
            1,
            "A dependent must be able to see its piece while it deletes its own rows"
        )
        XCTAssertEqual(try store.pieceCount(), 0)
    }

    func testEveryRegisteredDependentIsAsked() throws {
        let presets = RecordingDependentStore(dependentDescription: "presets")
        let annotations = RecordingDependentStore(dependentDescription: "annotations")
        let remover = PieceRemover(
            database: store.database,
            catalog: store.pieces,
            contentStore: store.pieceContent,
            dependentStores: [presets, annotations]
        )
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")

        try remover.remove(piece)

        XCTAssertEqual(presets.removedPieceIDs, [piece.id])
        XCTAssertEqual(annotations.removedPieceIDs, [piece.id])
    }

    /// A dependent that fails takes the whole removal down with it: the
    /// transaction rolls back and the piece is still there, score and all.
    func testAFailingDependentLeavesThePieceEntirelyIntact() throws {
        let failing = FailingDependentStore(dependentDescription: "presets")
        let remover = PieceRemover(
            database: store.database,
            catalog: store.pieces,
            contentStore: store.pieceContent,
            dependentStores: [failing]
        )
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        let before = try VisibleLibrary(store)

        XCTAssertThrowsError(try remover.remove(piece)) { error in
            guard case PieceRemovalError.dependentRemovalFailed(let title, let dependent, _) = error else {
                return XCTFail("Expected dependentRemovalFailed, got \(error)")
            }
            XCTAssertEqual(title, "Prelude in C")
            XCTAssertEqual(dependent, "presets")
        }

        XCTAssertEqual(try VisibleLibrary(store), before,
                       "A failed removal must leave the library byte-identical")
    }

    /// The library has no dependent stores yet — presets arrive in increment
    /// 004 — and removal must work exactly the same in the meantime.
    func testTheShippedStoreHasNoDependentsYetAndStillRemoves() throws {
        XCTAssertTrue(store.dependentStores.isEmpty)

        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        try store.makeRemover().remove(piece)

        XCTAssertEqual(try store.pieceCount(), 0)
    }

    // MARK: - Failure paths

    func testACatalogThatRefusesToDeleteLeavesEverythingInPlace() throws {
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        let remover = PieceRemover(
            database: store.database,
            catalog: DeleteRefusingCatalog(wrapping: store.pieces),
            contentStore: store.pieceContent,
            dependentStores: []
        )
        let before = try VisibleLibrary(store)

        XCTAssertThrowsError(try remover.remove(piece)) { error in
            guard case PieceRemovalError.catalogRemovalFailed(let title, _) = error else {
                return XCTFail("Expected catalogRemovalFailed, got \(error)")
            }
            XCTAssertEqual(title, "Prelude in C")
        }

        XCTAssertEqual(try VisibleLibrary(store), before)
        XCTAssertEqual(try store.storedContentFileCount(), 1,
                       "The stored score must survive a refused removal")
    }

    func testRemovingAPieceThatIsAlreadyGoneIsANamedFailureNotACrash() throws {
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        try store.makeRemover().remove(piece)

        XCTAssertThrowsError(try store.makeRemover().remove(piece)) { error in
            guard case PieceRemovalError.pieceNotFound(let title) = error else {
                return XCTFail("Expected pieceNotFound, got \(error)")
            }
            XCTAssertEqual(title, "Prelude in C")
        }
    }

    /// A second piece's bytes must never be deleted because the first piece's
    /// record could not be read.
    func testAnUnreadableCatalogDoesNotDeleteTheStoredScore() throws {
        let piece = try importScore(named: "prelude.musicxml", workTitle: "Prelude in C")
        let remover = PieceRemover(
            database: store.database,
            catalog: ReadRefusingCatalog(),
            contentStore: store.pieceContent,
            dependentStores: []
        )

        XCTAssertThrowsError(try remover.remove(piece)) { error in
            guard case PieceRemovalError.catalogRemovalFailed = error else {
                return XCTFail("Expected catalogRemovalFailed, got \(error)")
            }
        }
        XCTAssertEqual(try store.storedContentFileCount(), 1)
        XCTAssertEqual(try store.pieceCount(), 1)
    }

    // MARK: - Owner-facing wording

    func testEveryRemovalFailureNamesThePiece() throws {
        let errors: [PieceRemovalError] = [
            .pieceNotFound(title: "Prelude in C"),
            .dependentRemovalFailed(title: "Prelude in C", dependent: "presets", reason: "disk full"),
            .catalogRemovalFailed(title: "Prelude in C", reason: "disk full")
        ]

        for error in errors {
            let described = try XCTUnwrap(error.errorDescription, "\(error)")
            XCTAssertTrue(described.contains("Prelude in C"), described)
            XCTAssertNotNil(error.recoverySuggestion, described)
        }
    }

    // MARK: - Snapshots

    /// The library as removal is allowed to change it: the catalog's rows and
    /// the stored scores' bytes.
    ///
    /// Narrower than `LibrarySnapshot` on purpose. A rolled-back transaction is
    /// free to leave SQLite's write-ahead log physically different; what must
    /// not change is the library the app can see.
    private struct VisibleLibrary: Equatable {
        let pieces: [PieceRecord]
        let storedScores: [String: Data]
        let contentFileCount: Int

        init(_ store: LibraryStore) throws {
            let records = try store.allPieces()
            var scores: [String: Data] = [:]
            for record in records {
                scores[record.contentFileName] = try store.pieceContent.read(
                    named: record.contentFileName
                )
            }
            pieces = records
            storedScores = scores
            contentFileCount = try store.storedContentFileCount()
        }
    }
}

// MARK: - Test doubles

/// Stands in for increment 004's preset store.
private final class RecordingDependentStore: PieceDependentStore, @unchecked Sendable {
    let dependentDescription: String
    private(set) var removedPieceIDs: [String] = []

    /// How many piece rows existed at the moment this store was asked, which is
    /// how the ordering guarantee is observed rather than assumed.
    var pieceRowCountWhenAsked: Int?

    init(dependentDescription: String = "presets") {
        self.dependentDescription = dependentDescription
    }

    func removeDependents(ofPieceID pieceID: String, in database: SQLiteDatabase) throws {
        removedPieceIDs.append(pieceID)
        pieceRowCountWhenAsked = try database.scalarInt("SELECT count(*) FROM pieces;")
    }
}

/// Fails the way a damaged or full preset table would.
private struct FailingDependentStore: PieceDependentStore {
    let dependentDescription: String

    func removeDependents(ofPieceID pieceID: String, in database: SQLiteDatabase) throws {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "There is not enough space on the disk."]
        )
    }
}

/// Reads for real, refuses to delete.
private struct DeleteRefusingCatalog: PieceCatalogDeleting {
    let wrapped: PieceCatalog

    init(wrapping catalog: PieceCatalog) { self.wrapped = catalog }

    func piece(withContentSHA256 digest: String) throws -> PieceRecord? {
        try wrapped.piece(withContentSHA256: digest)
    }
    func piece(withID id: String) throws -> PieceRecord? { try wrapped.piece(withID: id) }
    func allPieces() throws -> [PieceRecord] { try wrapped.allPieces() }
    func pieceCount() throws -> Int { try wrapped.pieceCount() }

    func delete(pieceID: String) throws {
        throw StoreError.statementFailed(sql: "DELETE FROM pieces", code: 11, message: "database disk image is malformed")
    }
}

/// Cannot answer whether the piece is there.
private struct ReadRefusingCatalog: PieceCatalogDeleting {
    struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "The library database could not be read." }
    }

    func piece(withContentSHA256 digest: String) throws -> PieceRecord? { throw Unreadable() }
    func piece(withID id: String) throws -> PieceRecord? { throw Unreadable() }
    func allPieces() throws -> [PieceRecord] { throw Unreadable() }
    func pieceCount() throws -> Int { throw Unreadable() }
    func delete(pieceID: String) throws { throw Unreadable() }
}

