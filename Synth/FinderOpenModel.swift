import SwiftUI
import Foundation
import Observation

/// The result of a Finder open, shown over whichever screen is not the
/// library (P84-4): a short notice naming the piece now selected there.
struct FinderOpenNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

/// Scores opened from Finder — double-click or Open With (#88).
///
/// **One import path.** Nothing here reads a file: every batch goes through
/// `LibraryModel.importPieces(from:)`, the same call the picker and the drop
/// target make, so validation, de-duplication, the named failure and the
/// selection are the library's, unchanged. What this adds is only *when*:
///
/// - **Before the library exists.** On a cold launch the system hands the
///   files over before `AppModel.bootstrap()` has opened the store. They wait
///   here and go in as soon as the library is ready — including after a
///   failed launch and a successful Try Again. Until then they are held, never
///   dropped.
/// - **Behind another library operation.** `importPieces` turns a call away
///   while an import or a piece removal holds `isWorking`; a Finder open
///   instead waits for it to finish and then goes in, once.
/// - **Several at once.** Everything waiting when a delivery starts goes in as
///   one batch with one report.
///
/// **Where the result shows (P84-4).** With the library on screen its own
/// status line and alert report it, exactly as for the picker. Anywhere else
/// — the transport, Sound Studio, the instrument catalog — the open does not
/// navigate away or interrupt anything: the piece is imported and selected in
/// the library, and the result is raised here, over the visible screen. A
/// failure moves the library's named-file alert up to the app level, so the
/// owner sees it now and not again later when they go back to the library.
@Observable
@MainActor
final class FinderOpenModel {
    /// Files handed over and not yet given to the library.
    private(set) var pendingURLs: [URL] = []

    /// The success notice over a non-library screen, or nil.
    var notice: FinderOpenNotice?

    /// The named-file failure over a non-library screen, or nil.
    var alert: LibraryAlert?

    /// The delivery in flight, if any. Exposed so tests can wait for it.
    private(set) var delivery: Task<Void, Never>?

    /// The library to deliver into, when there is one.
    @ObservationIgnored private let library: () -> LibraryModel?

    /// Whether the library is the screen showing right now.
    @ObservationIgnored private let isLibraryShowing: () -> Bool

    init(library: @escaping () -> LibraryModel?, isLibraryShowing: @escaping () -> Bool) {
        self.library = library
        self.isLibraryShowing = isLibraryShowing
    }

    /// Takes files the system asked the app to open, and delivers them as soon
    /// as the library can take them.
    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pendingURLs.append(contentsOf: files)
        deliverPending()
    }

    /// Starts a delivery if there is a library and something waiting. Called
    /// on every open and whenever the library becomes ready.
    func deliverPending() {
        guard delivery == nil, !pendingURLs.isEmpty, library() != nil else { return }
        delivery = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pendingURLs.isEmpty, let library = library() {
            await library.waitUntilIdle()
            // A store reopened while this waited is a different library;
            // deliver into whichever one is current.
            guard library === self.library() else { continue }

            let batch = pendingURLs
            pendingURLs = []
            guard let summary = await library.importPieces(from: batch) else {
                // Turned away after all: put the batch back and wait again.
                pendingURLs = batch + pendingURLs
                continue
            }
            surface(summary, from: library)
        }
        delivery = nil
    }

    /// Reports a finished batch where the owner can see it (P84-4).
    private func surface(_ summary: ImportSummary, from library: LibraryModel) {
        guard !isLibraryShowing() else { return }

        if let sentence = summary.successSentence,
           let selected = library.selectedPiece {
            let message = "\(sentence) “\(selected.title)” is selected in your library."
            notice = FinderOpenNotice(message: message)
            AccessibilityNotification.Announcement(message).post()
        }
        if let failure = library.alert {
            alert = failure
            library.alert = nil
        }
    }
}
