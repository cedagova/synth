import Foundation
import Observation
import SynthKit

/// A readable summary of the opened store, shown by the shell.
struct StoreSummary: Sendable, Equatable {
    /// Container path abbreviated with `~` so no user name is displayed.
    let containerPath: String
    let schemaVersion: Int
    let pieceCount: Int
}

/// A store failure rendered for the owner.
struct StoreFailure: Sendable, Equatable {
    let summary: String
    let recovery: String?

    init(_ error: Error) {
        if let localized = error as? LocalizedError {
            summary = localized.errorDescription ?? String(describing: error)
            recovery = localized.recoverySuggestion
        } else {
            summary = (error as NSError).localizedDescription
            recovery = nil
        }
    }
}

/// What the shell is showing.
enum LibraryState: Sendable, Equatable {
    case loading
    case ready(StoreSummary)
    case failed(StoreFailure)
}

/// Owns the launch-time store bootstrap and the state the shell renders.
@Observable
@MainActor
final class AppModel {
    private(set) var state: LibraryState = .loading

    /// Held open for the app's lifetime; later leaves read and write through it.
    private var store: LibraryStore?

    /// Tail of the chain of bootstrap attempts. Each new attempt waits for it,
    /// which is what keeps the database from ever being opened twice at once —
    /// a plain `store == nil` guard cannot do that, because it is re-checked
    /// only after the first attempt has already suspended.
    private var attempts: Task<Void, Never>?

    nonisolated init() {}

    /// Opens the container and store, then publishes the resulting state.
    /// Never throws: every failure becomes a rendered launch error.
    ///
    /// Calls that arrive while an attempt is in flight join it rather than
    /// starting a second one.
    func bootstrap() async {
        await enqueue(reopen: false)
    }

    /// Retries after a failed bootstrap, for the error state's Try Again
    /// button. Repeated presses queue behind each other instead of racing.
    func retry() async {
        await enqueue(reopen: true)
    }

    /// Appends one attempt to the serial chain and waits for it.
    private func enqueue(reopen: Bool) async {
        let previous = attempts
        let attempt = Task { [weak self] in
            await previous?.value
            await self?.performBootstrap(reopen: reopen)
        }
        attempts = attempt
        await attempt.value
    }

    private func performBootstrap(reopen: Bool) async {
        if reopen, let current = store {
            current.close()
            store = nil
        }
        // An attempt queued behind a successful one has nothing left to do.
        guard store == nil else { return }

        state = .loading
        let appVersion = Bundle.main.synthVersionString
        do {
            let opened = try await Self.openStore(appVersion: appVersion)
            store = opened.store
            state = .ready(opened.summary)
        } catch {
            state = .failed(StoreFailure(error))
        }
    }

    private struct OpenedStore: Sendable {
        let store: LibraryStore
        let summary: StoreSummary
    }

    /// Disk work runs off the main actor so launch stays responsive.
    private static func openStore(appVersion: String) async throws -> OpenedStore {
        try await Task.detached(priority: .userInitiated) {
            let store = try LibraryStore.open(appVersion: appVersion)
            let summary = StoreSummary(
                containerPath: HomeRelativePath.display(store.container.rootURL),
                schemaVersion: store.schemaVersion,
                pieceCount: try store.storedPieceCount()
            )
            return OpenedStore(store: store, summary: summary)
        }.value
    }

}

extension Bundle {
    /// `<short version> (<build>)`, or a stable placeholder outside a bundle.
    var synthVersionString: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return "unknown"
        }
    }
}
