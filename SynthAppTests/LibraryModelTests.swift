import XCTest
@testable import Synth
import SynthKit

/// `LibraryModel` directly: import, rename, remove, and what the owner is told
/// when each of them fails (issue #99).
///
/// Driven through the same methods the library screen and its menu commands
/// call, against a real store in a temporary container.
@MainActor
final class LibraryModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var model: LibraryModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        model = LibraryModel(store: library.store)
        await model.reload()
    }

    override func tearDown() async throws {
        model = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private func importFixture(
        title: String = "Model Fixture", named file: String = "fixture.musicxml"
    ) async throws -> PieceRecord {
        let url = try library.sourceFile(
            named: file, musicXML: ModelFixtures.score(title: title)
        )
        await model.importPieces(from: [url])
        return try XCTUnwrap(model.pieces.first { $0.title == title }, "“\(title)” did not import")
    }

    // MARK: Importing

    func testAFreshLibraryIsEmpty() {
        XCTAssertTrue(model.isLibraryEmpty)
        XCTAssertNil(model.alert)
    }

    func testImportingAScoreAddsItSelectsItAndSaysSo() async throws {
        let piece = try await importFixture(title: "Sonata")

        XCTAssertEqual(model.pieces.count, 1)
        XCTAssertEqual(model.selection, piece.id, "The imported piece is revealed")
        XCTAssertEqual(model.statusMessage, "Imported “Sonata”.")
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.alert)
        XCTAssertEqual(try library.store.pieceCount(), 1, "…and it is in the store")
    }

    func testImportingTheSameScoreTwiceIsReportedAsADuplicate() async throws {
        let first = try await importFixture(title: "Sonata")
        let again = try library.sourceFile(
            named: "copy.musicxml", musicXML: ModelFixtures.score(title: "Sonata")
        )
        await model.importPieces(from: [again])

        XCTAssertEqual(model.pieces.count, 1, "A duplicate adds nothing")
        XCTAssertEqual(model.selection, first.id, "…and points at the piece already there")
        XCTAssertEqual(model.statusMessage, "“Sonata” was already in your library.")
        XCTAssertNil(model.alert)
    }

    /// The failure path: an unreadable file names itself in the alert, the
    /// status line says nothing was imported, and the library is unchanged.
    func testAFileThatIsNotAScoreIsRejectedByName() async throws {
        let url = try library.sourceFile(named: "broken.musicxml", musicXML: "not a score at all")
        await model.importPieces(from: [url])

        let alert = try XCTUnwrap(model.alert, "A rejected file must be put in front of the owner")
        XCTAssertEqual(alert.title, "Import failed")
        XCTAssertTrue(alert.message.contains("broken.musicxml"), "The alert names the file: \(alert.message)")
        XCTAssertEqual(model.statusMessage, "Nothing was imported. Your library is unchanged.")
        XCTAssertTrue(model.isLibraryEmpty)
        XCTAssertEqual(try library.store.pieceCount(), 0)
    }

    func testOneBadFileDoesNotStopTheOthers() async throws {
        let good = try library.sourceFile(
            named: "good.musicxml", musicXML: ModelFixtures.score(title: "Good")
        )
        let bad = try library.sourceFile(named: "bad.musicxml", musicXML: "<nope/>")
        await model.importPieces(from: [bad, good])

        XCTAssertEqual(model.pieces.map(\.title), ["Good"])
        XCTAssertEqual(model.statusMessage, "Imported “Good”.")
        XCTAssertEqual(model.alert?.title, "Import failed")
    }

    func testBeginImportOpensThePicker() {
        model.beginImport()
        XCTAssertTrue(model.isChoosingFiles)
    }

    // MARK: Renaming

    func testEditingInfoWritesTheNewTitleAndComposer() async throws {
        let piece = try await importFixture(title: "Sonata")

        model.beginInfoEdit(of: piece)
        XCTAssertEqual(model.infoTitleDraft, "Sonata")
        model.infoTitleDraft = "  Sonata in C  "
        model.infoComposerDraft = "Haydn"
        await model.commitInfoEdit()

        XCTAssertNil(model.editingInfoPiece, "The editor closes on success")
        XCTAssertEqual(model.statusMessage, "Saved “Sonata in C”.")
        XCTAssertEqual(model.selection, piece.id)
        let stored = try XCTUnwrap(library.store.allPieces().first)
        XCTAssertEqual(stored.title, "Sonata in C", "The title is trimmed and stored")
        XCTAssertEqual(stored.composer, "Haydn")
    }

    func testAnEmptyTitleIsNotWritten() async throws {
        let piece = try await importFixture(title: "Sonata")
        model.beginInfoEdit(of: piece)
        model.infoTitleDraft = "   "
        await model.commitInfoEdit()

        XCTAssertNotNil(model.editingInfoPiece, "The editor stays open for a real title")
        XCTAssertEqual(try library.store.allPieces().first?.title, "Sonata")
    }

    func testCancellingAnInfoEditWritesNothing() async throws {
        let piece = try await importFixture(title: "Sonata")
        model.beginInfoEdit(of: piece)
        model.infoTitleDraft = "Something else"
        model.cancelInfoEdit()

        XCTAssertNil(model.editingInfoPiece)
        XCTAssertEqual(try library.store.allPieces().first?.title, "Sonata")
    }

    /// The failure path: the store refuses the write, the owner is told, and
    /// the stored name is untouched.
    func testARenameTheStoreRefusesRaisesAnAlertAndChangesNothing() async throws {
        let piece = try await importFixture(title: "Sonata")
        try library.failWrites(.update, on: PieceCatalog.tableName)

        model.beginInfoEdit(of: piece)
        model.infoTitleDraft = "Renamed"
        await model.commitInfoEdit()

        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, "Could not save the new name")
        XCTAssertEqual(alert.recovery, "Your library is unchanged.")
        XCTAssertNotNil(model.editingInfoPiece, "The edit stays open so the owner can retry")
        XCTAssertEqual(try library.store.allPieces().first?.title, "Sonata")
    }

    // MARK: Removing

    func testRemovalAsksFirstAndCanBeCancelled() async throws {
        let piece = try await importFixture()
        model.selection = piece.id
        model.requestRemovalOfSelection()
        XCTAssertEqual(model.pendingRemoval?.id, piece.id, "Removal is never one keystroke")

        model.cancelRemoval()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(model.pieces.count, 1)
    }

    func testConfirmingRemovalDeletesThePiece() async throws {
        let piece = try await importFixture(title: "Sonata")
        model.requestRemoval(of: piece)
        await model.confirmRemoval(of: piece)

        XCTAssertNil(model.pendingRemoval)
        XCTAssertTrue(model.isLibraryEmpty)
        XCTAssertNil(model.selection, "A removed piece cannot stay selected")
        XCTAssertEqual(model.statusMessage, "Removed “Sonata” from your library.")
        XCTAssertEqual(try library.store.pieceCount(), 0)
        XCTAssertEqual(try library.store.storedContentFileCount(), 0, "…and its content file")
    }

    /// The failure path: the store refuses the delete, the alert says so, and
    /// the piece is still there on screen and on disk.
    func testARemovalTheStoreRefusesRaisesAnAlertAndKeepsThePiece() async throws {
        let piece = try await importFixture(title: "Sonata")
        try library.failWrites(.delete, on: PieceCatalog.tableName)

        await model.confirmRemoval(of: piece)

        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, "Could not remove the piece")
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.pieces.map(\.id), [piece.id], "The list still shows the piece")
        XCTAssertEqual(try library.store.pieceCount(), 1)
        XCTAssertEqual(try library.store.storedContentFileCount(), 1)
    }

    func testRemovingAPieceThatIsAlreadyGoneRaisesAnAlert() async throws {
        let piece = try await importFixture(title: "Sonata")
        try library.store.makeRemover().remove(piece)

        await model.confirmRemoval(of: piece)

        XCTAssertEqual(model.alert?.title, "Could not remove the piece")
        XCTAssertTrue(model.isLibraryEmpty, "The stale list is re-read")
    }

    // MARK: Search, sort and selection

    func testSearchNarrowsTheListAndDropsAHiddenSelection() async throws {
        let sonata = try await importFixture(title: "Sonata", named: "a.musicxml")
        _ = try await importFixture(title: "Partita", named: "b.musicxml")
        model.selection = sonata.id

        model.searchText = "part"
        XCTAssertEqual(model.visiblePieces.map(\.title), ["Partita"])
        XCTAssertNil(model.selection, "A selection the search hides is dropped")

        model.searchText = "zzz"
        XCTAssertTrue(model.isSearchEmpty)

        model.clearSearch()
        XCTAssertEqual(model.visiblePieces.count, 2)
    }

    func testSortingByAFieldAndFlippingIt() async throws {
        _ = try await importFixture(title: "Beta", named: "a.musicxml")
        _ = try await importFixture(title: "Alpha", named: "b.musicxml")

        model.sortBy(.title)  // already by title: flips to descending
        XCTAssertEqual(model.visiblePieces.map(\.title), ["Beta", "Alpha"])
        model.toggleSortDirection()
        XCTAssertEqual(model.visiblePieces.map(\.title), ["Alpha", "Beta"])

        model.sortBy(.importedAt)
        XCTAssertEqual(model.sort.field, .importedAt)
        XCTAssertEqual(model.sort.direction, .descending, "Dates start newest first")
    }

    func testKeyboardSelectionWalksTheVisibleRows() async throws {
        _ = try await importFixture(title: "Alpha", named: "a.musicxml")
        _ = try await importFixture(title: "Beta", named: "b.musicxml")
        model.selection = nil
        let focusBefore = model.listFocusRequests

        model.selectNextPiece()
        XCTAssertEqual(model.selectedPiece?.title, "Alpha", "Nothing selected starts at the top")
        model.selectNextPiece()
        XCTAssertEqual(model.selectedPiece?.title, "Beta")
        model.selectNextPiece()
        XCTAssertEqual(model.selectedPiece?.title, "Beta", "Stops at the bottom")
        model.selectPreviousPiece()
        XCTAssertEqual(model.selectedPiece?.title, "Alpha")
        XCTAssertEqual(model.listFocusRequests, focusBefore + 4)

        let searchBefore = model.searchFocusRequests
        model.requestSearchFocus()
        XCTAssertEqual(model.searchFocusRequests, searchBefore + 1)
    }
}
