import Foundation
import Observation
import SynthKit

/// What the instrument catalog screen shows, and what its buttons do.
///
/// The model owns the download tasks so a transfer survives the screen being
/// closed: an owner who starts a 2.6 GB download and goes back to their piece
/// should come back to a download that has been running, not one that stopped
/// when the view went away.
@Observable
@MainActor
final class InstrumentCatalogModel {
    /// One row of the catalog list.
    struct Row: Identifiable, Sendable {
        let library: CatalogLibrary
        var state: InstrumentLibraryState
        var progress: InstrumentDownloadProgress?
        var failure: Failure?

        var id: String { library.identifier }

        /// True while a transfer for this library is running.
        var isWorking: Bool { progress != nil }
    }

    /// A failure, already turned into something the owner can act on.
    struct Failure: Sendable, Equatable {
        let summary: String
        let recovery: String?
        let isRetryable: Bool
    }

    private(set) var rows: [Row] = []

    /// The row the menu commands act on. Bound to the list's own selection, so
    /// clicking a row and pressing ⌥⌘G do the same thing to the same library.
    var selection: String?

    /// The library whose licence sheet is open.
    var licenceSheetLibraryID: String?

    /// The library whose removal is waiting on a confirmation.
    var pendingRemovalLibraryID: String?

    /// True while the first-run offer is showing.
    private(set) var isShowingFirstRunOffer = false

    /// A store failure the whole screen has to report.
    var alert: StoreFailure?

    private let store: LibraryStore
    private let manager: InstrumentDownloadManager
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Preference key recording that the owner has been offered the download
    /// once. Set whether they accept or decline, because the offer is a
    /// first-run event and not a nag.
    static let firstRunOfferSeenKey = "instruments.firstRunOffer.seen"

    init(store: LibraryStore, transfer: AssetTransferring = ShippedAssetTransfer.make()) {
        self.store = store
        self.manager = InstrumentDownloadManager(store: store.instruments, transfer: transfer)
    }

    // MARK: Loading

    /// Reads the current state of every catalog library from disk.
    func reload() {
        do {
            let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = try store.instruments.states().map { entry in
                Row(
                    library: entry.library,
                    state: entry.state,
                    progress: existing[entry.library.identifier]?.progress,
                    failure: existing[entry.library.identifier]?.failure
                )
            }
        } catch {
            alert = StoreFailure(error)
        }
    }

    /// Launch-time tidy-up plus the first-run offer.
    ///
    /// The offer appears once, when nothing is installed and the owner has not
    /// been asked before. Declining is a real answer: the preference is written
    /// either way, and the catalog stays reachable from the Instruments menu
    /// (REQ-020's "the offer remains reachable later").
    func prepareForFirstRun() {
        do {
            try store.instruments.reconcileWithDisk()
        } catch {
            alert = StoreFailure(error)
        }
        reload()

        let previousAnswer = (try? store.preferences.string(forKey: Self.firstRunOfferSeenKey)) ?? nil
        let nothingInstalled = rows.allSatisfy { !$0.state.isInstalled }
        isShowingFirstRunOffer = previousAnswer == nil && nothingInstalled
    }

    /// Told what the owner answered, so the shell can put the screen away again
    /// when it was only ever opened to ask.
    var onFirstRunOfferAnswered: ((Bool) -> Void)?

    /// The owner answered the first-run offer.
    ///
    /// The preference is written either way. Declining is a real answer, not a
    /// postponement: the offer never appears again on its own, and the catalog
    /// stays in the Instruments menu for whenever the owner does want it.
    func answerFirstRunOffer(downloadNow: Bool) {
        guard isShowingFirstRunOffer else { return }
        isShowingFirstRunOffer = false
        try? store.preferences.setString(
            downloadNow ? "accepted" : "declined", forKey: Self.firstRunOfferSeenKey
        )
        if downloadNow {
            downloadEverythingNotYetInstalled()
        }
        onFirstRunOfferAnswered?(downloadNow)
    }

    // MARK: Summary

    /// The line above the list: what the owner can and cannot play.
    var coverageSummary: String {
        let installed = rows.reduce(into: Set<InstrumentCoverage.Family>()) { families, row in
            guard row.state.isInstalled else { return }
            families.formUnion(row.library.families)
        }
        return InstrumentCatalogDisplay.coverageSummary(installedFamilies: installed)
    }

    /// Total bytes the whole catalog costs, for the first-run offer.
    var catalogByteCount: Int64 { InstrumentCatalog.defaultSelectionByteCount }

    var libraryCount: Int { rows.count }

    // MARK: Acting on one library

    /// Download, resume, remove or re-download, whichever the row's state means.
    func performPrimaryAction(on library: CatalogLibrary) {
        guard let row = rows.first(where: { $0.id == library.identifier }) else { return }
        if row.isWorking {
            pauseDownload(of: library)
            return
        }
        switch row.state {
        case .notDownloaded, .partiallyDownloaded, .installedFromAnotherCatalog:
            startDownload(of: library)
        case .installed:
            pendingRemovalLibraryID = library.identifier
        }
    }

    func startDownload(of library: CatalogLibrary) {
        guard tasks[library.identifier] == nil else { return }
        update(library.identifier) { row in
            row.failure = nil
            row.progress = InstrumentDownloadProgress(
                libraryID: library.identifier,
                completedByteCount: 0,
                totalByteCount: library.downloadByteCount,
                completedAssetCount: 0,
                totalAssetCount: library.assets.count,
                phase: .downloading
            )
        }

        // `self` is captured strongly, which makes a cycle — the model holds the
        // task, the task's closures hold the model — and that is deliberate: a
        // download in flight must keep its reporter alive even if nothing else
        // references it. The cycle is broken in exactly two places, and both
        // always run: `finish` clears the entry when the transfer ends, and
        // `suspend` cancels and clears every entry when the store closes.
        let task = Task { [manager] in
            do {
                try await manager.install(library) { progress in
                    Task { @MainActor in
                        self.update(library.identifier) { $0.progress = progress }
                    }
                }
                await MainActor.run { self.finish(library.identifier, failure: nil) }
            } catch {
                await MainActor.run { self.finish(library.identifier, failure: error) }
            }
        }
        tasks[library.identifier] = task
    }

    /// Pauses a running transfer. What has arrived stays on disk.
    func pauseDownload(of library: CatalogLibrary) {
        tasks[library.identifier]?.cancel()
    }

    /// Removes an installed library after the confirmation.
    func confirmRemoval(of library: CatalogLibrary) {
        pendingRemovalLibraryID = nil
        do {
            try manager.remove(library)
        } catch {
            update(library.identifier) { $0.failure = Self.failure(from: error) }
        }
        reload()
    }

    func cancelRemoval() { pendingRemovalLibraryID = nil }

    // MARK: What the menu commands do

    /// The selected library, or the first one when nothing is selected — so a
    /// shortcut pressed before anything has been clicked still does something
    /// predictable rather than nothing at all.
    private var actionableLibrary: CatalogLibrary? {
        rows.first { $0.id == selection }?.library ?? rows.first?.library
    }

    func performPrimaryActionOnSelection() {
        guard let library = actionableLibrary else { return }
        selection = library.identifier
        performPrimaryAction(on: library)
    }

    func showLicenceForSelection() {
        guard let library = actionableLibrary else { return }
        selection = library.identifier
        licenceSheetLibraryID = library.identifier
    }

    func downloadEverythingNotYetInstalled() {
        for row in rows where !row.state.isInstalled && !row.isWorking {
            startDownload(of: row.library)
        }
    }

    func pauseEverything() {
        for row in rows where row.isWorking {
            pauseDownload(of: row.library)
        }
    }

    func selectNextLibrary() { moveSelection(by: 1) }

    func selectPreviousLibrary() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == selection }) else {
            selection = rows[offset > 0 ? 0 : rows.count - 1].id
            return
        }
        let next = (current + offset + rows.count) % rows.count
        selection = rows[next].id
    }

    /// Stops everything, for a store that is closing under us.
    func suspend() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    // MARK: Sentences

    func status(of row: Row) -> String {
        if let progress = row.progress {
            return InstrumentCatalogDisplay.progress(progress)
        }
        return InstrumentCatalogDisplay.status(of: row.state, in: row.library)
    }

    func primaryActionTitle(for row: Row) -> String {
        row.isWorking ? "Pause" : InstrumentCatalogDisplay.primaryActionTitle(for: row.state)
    }

    /// The whole row, as one sentence, for VoiceOver (REQ-027).
    ///
    /// Assembled from the same strings the row shows rather than a parallel
    /// description, so what is read aloud cannot drift from what is on screen.
    func accessibilityDescription(of row: Row) -> String {
        var parts = [row.library.name, status(of: row)]
        if let failure = row.failure { parts.append(failure.summary) }
        parts.append(InstrumentCatalogDisplay.licence(row.library))
        return parts.joined(separator: ". ")
    }

    // MARK: Private

    private func update(_ libraryID: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == libraryID }) else { return }
        change(&rows[index])
    }

    private func finish(_ libraryID: String, failure error: Error?) {
        tasks[libraryID] = nil
        update(libraryID) { row in
            row.progress = nil
            row.failure = error.map(Self.failure(from:))
        }
        reload()
    }

    private static func failure(from error: Error) -> Failure {
        let rendered = InstrumentCatalogDisplay.failure(error)
        return Failure(
            summary: rendered.summary, recovery: rendered.recovery, isRetryable: rendered.isRetryable
        )
    }
}

extension InstrumentLibraryState {
    var isInstalled: Bool {
        switch self {
        case .installed, .installedFromAnotherCatalog: return true
        case .notDownloaded, .partiallyDownloaded: return false
        }
    }
}
