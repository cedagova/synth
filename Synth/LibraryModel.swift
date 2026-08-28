import Foundation
import Observation
import SynthKit

/// A failure the library surface has to put in front of the owner.
///
/// Split into a headline and an optional recovery line because that is exactly
/// the shape of an `NSAlert`, and because both halves already exist on
/// `ImportError` and `PieceRemovalError` — the UI never invents wording for a
/// failure the model layer already described.
struct LibraryAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: String?

    /// The one failure case: names the file and the reason (REQ-004).
    static func importFailed(_ failures: [ImportFailure]) -> LibraryAlert {
        if failures.count == 1, let only = failures.first {
            return LibraryAlert(
                title: "Import failed",
                message: only.message,
                recovery: only.recovery
            )
        }
        return LibraryAlert(
            title: "\(failures.count) files could not be imported",
            message: failures.map(\.message).joined(separator: "\n\n"),
            recovery: "Your library is unchanged apart from the files that imported successfully."
        )
    }

    static func removalFailed(_ error: Error) -> LibraryAlert {
        LibraryAlert(
            title: "Could not remove the piece",
            message: Self.describe(error),
            recovery: (error as? LocalizedError)?.recoverySuggestion
        )
    }

    static func libraryUnreadable(_ error: Error) -> LibraryAlert {
        LibraryAlert(
            title: "Could not read your library",
            message: Self.describe(error),
            recovery: (error as? LocalizedError)?.recoverySuggestion
        )
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    }
}

/// One rejected file, kept whole so the alert can name it.
struct ImportFailure: Equatable, Sendable {
    let fileName: String
    let message: String
    let recovery: String?

    init(_ error: ImportError) {
        fileName = error.fileName
        message = error.errorDescription ?? "Synth could not import “\(error.fileName)”."
        recovery = error.recoverySuggestion
    }

    /// For anything the importer did not classify — it still has to name a file.
    init(fileName: String, error: Error) {
        self.fileName = fileName
        message = "Synth could not import “\(fileName)”. "
            + ((error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription)
        recovery = "Your library is unchanged."
    }
}

/// What one import run did, as the status line reports it.
struct ImportSummary: Equatable, Sendable {
    var imported: [PieceRecord] = []
    var duplicates: [PieceRecord] = []
    var failures: [ImportFailure] = []

    /// Plain-language sentence for the status line. Nil when nothing succeeded,
    /// because the alert is then carrying the whole story.
    var successSentence: String? {
        var parts: [String] = []
        if let list = Self.list(imported.map(\.title)) {
            parts.append("Imported \(list).")
        }
        if let list = Self.list(duplicates.map(\.title)) {
            parts.append("\(list) \(duplicates.count == 1 ? "was" : "were") already in your library.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func list(_ titles: [String]) -> String? {
        switch titles.count {
        case 0: return nil
        case 1: return "“\(titles[0])”"
        case 2: return "“\(titles[0])” and “\(titles[1])”"
        default: return "“\(titles[0])” and \(titles.count - 1) more"
        }
    }
}

/// The library surface's state: what is in the library, what the owner is
/// looking for, and what the app is doing about it.
///
/// Ordering and matching are `LibraryQuery`'s job, not this type's — this owns
/// only the interaction: loading, importing, confirming, removing, and the two
/// things the owner sees afterwards (a status line and, on failure, an alert).
@Observable
@MainActor
final class LibraryModel {
    /// Container path abbreviated with `~`, so no account name is on screen.
    let containerPath: String
    let schemaVersion: Int

    /// Every piece in the library, as last read from the store.
    private(set) var pieces: [PieceRecord] = []

    /// Substring the owner is searching for. Empty shows everything.
    var searchText: String = "" {
        didSet { if searchText != oldValue { pruneSelection() } }
    }

    var sort: LibrarySort = .byTitle {
        didSet { if sort != oldValue { pruneSelection() } }
    }

    /// The selected row, by piece identifier.
    var selection: PieceRecord.ID?

    /// The piece a confirmation is currently being asked about.
    var pendingRemoval: PieceRecord?

    /// Presented when the file picker is open.
    var isChoosingFiles = false

    /// True while an import or removal is running, so the surface can disable
    /// the controls that would race it.
    private(set) var isWorking = false

    /// The last thing that happened, in a sentence. Also what VoiceOver
    /// announces after an import or removal.
    private(set) var statusMessage: String?

    var alert: LibraryAlert?

    /// Bumped to ask the view to move focus to the search field, which is how
    /// the Find menu item reaches a `@FocusState` that lives in the view.
    private(set) var searchFocusRequests = 0

    /// The same mechanism for the list, so selecting from the menu also puts
    /// keyboard focus where the arrow keys will do something.
    private(set) var listFocusRequests = 0

    private let store: LibraryStore
    private let importer: MusicXMLImporter
    private let remover: PieceRemover

    init(store: LibraryStore) {
        self.store = store
        self.importer = store.makeImporter()
        self.remover = store.makeRemover()
        self.containerPath = HomeRelativePath.display(store.container.rootURL)
        self.schemaVersion = store.schemaVersion
    }

    // MARK: - Derived state

    /// The rows the list shows: filtered by `searchText`, ordered by `sort`.
    var visiblePieces: [PieceRecord] {
        LibraryQuery.arrange(pieces, searchText: searchText, sort: sort)
    }

    /// True when the library itself holds nothing — the first-run state, which
    /// is not the same as a search that found nothing.
    var isLibraryEmpty: Bool { pieces.isEmpty }

    /// True when the library has pieces but the current search matches none.
    var isSearchEmpty: Bool { !pieces.isEmpty && visiblePieces.isEmpty }

    /// The currently selected piece, if the selection still exists.
    var selectedPiece: PieceRecord? {
        guard let selection else { return nil }
        return pieces.first { $0.id == selection }
    }

    /// File extensions the picker and the drop target accept, from the
    /// importer's own list so the two can never disagree.
    static var acceptedFileExtensions: [String] {
        MusicXMLImporter.acceptedFileExtensions.sorted()
    }

    // MARK: - Loading

    /// Re-reads the library from the store.
    func reload() async {
        do {
            pieces = try await readPieces()
            pruneSelection()
        } catch {
            alert = .libraryUnreadable(error)
        }
    }

    // MARK: - Importing

    func beginImport() {
        guard !isWorking else { return }
        isChoosingFiles = true
    }

    /// Imports every URL, then reports once.
    ///
    /// One file failing never stops the others: the importer's contract is that
    /// a rejected file leaves the library untouched, so the honest result of
    /// dropping five files of which one is damaged is four imports and one
    /// named failure — not an abandoned batch.
    func importPieces(from urls: [URL]) async {
        guard !urls.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        statusMessage = urls.count == 1
            ? "Importing “\(urls[0].lastPathComponent)”…"
            : "Importing \(urls.count) files…"

        let summary = await runImport(of: urls)
        await reload()

        statusMessage = summary.successSentence
        if !summary.failures.isEmpty {
            alert = .importFailed(summary.failures)
            if summary.successSentence == nil {
                statusMessage = "Nothing was imported. Your library is unchanged."
            }
        }
        if let first = summary.imported.first ?? summary.duplicates.first {
            // Reveal where the piece landed in the current ordering — including
            // for a duplicate, which is the clearest way to show that the score
            // the owner just dropped is the one already there.
            selection = first.id
        }
    }

    // MARK: - Removing

    /// Asks for confirmation. REQ-003: removal is never one keystroke.
    func requestRemoval(of piece: PieceRecord) {
        guard !isWorking else { return }
        pendingRemoval = piece
    }

    /// Asks about the selected row, for the Remove menu item and the Delete key.
    func requestRemovalOfSelection() {
        guard let selectedPiece else { return }
        requestRemoval(of: selectedPiece)
    }

    /// Performs the removal the owner just confirmed.
    func confirmRemoval(of piece: PieceRecord) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        pendingRemoval = nil

        do {
            try await performRemoval(of: piece)
            await reload()
            statusMessage = "Removed “\(piece.title)” from your library."
        } catch {
            // The library is unchanged, but the list may be what was stale.
            await reload()
            statusMessage = nil
            alert = .removalFailed(error)
        }
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    // MARK: - Search and sort

    func requestSearchFocus() {
        searchFocusRequests += 1
    }

    /// Moves the selection one row down, starting at the top when nothing is
    /// selected. The Select Next Piece menu command.
    func selectNextPiece() {
        moveSelection(by: 1)
    }

    /// Moves the selection one row up, starting at the bottom when nothing is
    /// selected. The Select Previous Piece menu command.
    func selectPreviousPiece() {
        moveSelection(by: -1)
    }

    /// These commands exist so the list is reachable and navigable without a
    /// pointer even when Full Keyboard Access is off (REQ-027). Once a row is
    /// selected the list has focus and its own arrow keys take over.
    private func moveSelection(by offset: Int) {
        let rows = visiblePieces
        guard !rows.isEmpty else { return }

        guard let current = selection,
              let index = rows.firstIndex(where: { $0.id == current })
        else {
            selection = (offset > 0 ? rows.first : rows.last)?.id
            listFocusRequests += 1
            return
        }

        let next = min(max(index + offset, 0), rows.count - 1)
        selection = rows[next].id
        listFocusRequests += 1
    }

    func clearSearch() {
        searchText = ""
    }

    /// Picks a field, keeping the direction that field last had — except that
    /// choosing a new field starts it in its natural direction (newest first
    /// for dates, A to Z for text).
    func sortBy(_ field: LibrarySortField) {
        if sort.field == field {
            sort.direction = sort.direction.flipped
        } else {
            sort = LibrarySort(
                field: field,
                direction: field == .importedAt ? .descending : .ascending
            )
        }
    }

    func toggleSortDirection() {
        sort.direction = sort.direction.flipped
    }

    // MARK: - Off-main-actor work

    private func readPieces() async throws -> [PieceRecord] {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try store.allPieces()
        }.value
    }

    private func performRemoval(of piece: PieceRecord) async throws {
        let remover = self.remover
        try await Task.detached(priority: .userInitiated) {
            try remover.remove(piece)
        }.value
    }

    /// Reads and writes disk, so it runs off the main actor. Security-scoped
    /// access is started per file: a sandboxed app reaches a file the owner
    /// picked or dropped only while that scope is open.
    private func runImport(of urls: [URL]) async -> ImportSummary {
        let importer = self.importer
        return await Task.detached(priority: .userInitiated) {
            var summary = ImportSummary()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let outcome = try importer.importPiece(from: url)
                    if outcome.isDuplicate {
                        summary.duplicates.append(outcome.piece)
                    } else {
                        summary.imported.append(outcome.piece)
                    }
                } catch let error as ImportError {
                    summary.failures.append(ImportFailure(error))
                } catch {
                    summary.failures.append(
                        ImportFailure(fileName: url.lastPathComponent, error: error)
                    )
                }
            }
            return summary
        }.value
    }

    // MARK: - Selection housekeeping

    /// Drops a selection the current list no longer contains, so the Remove
    /// command can never act on a row that is not on screen.
    private func pruneSelection() {
        guard let selection else { return }
        if !visiblePieces.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}
