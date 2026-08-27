import Foundation
import Observation
import SynthKit

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
enum LibraryState {
    case loading
    case ready(LibraryModel)
    case failed(StoreFailure)
}

/// Owns the launch-time store bootstrap and the state the shell renders.
@Observable
@MainActor
final class AppModel {
    private(set) var state: LibraryState = .loading

    /// The live library surface, once the store is open. The menu commands
    /// reach the library through this rather than through the view hierarchy.
    var library: LibraryModel? {
        guard case .ready(let library) = state else { return nil }
        return library
    }

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
            store = opened
            state = .ready(LibraryModel(store: opened))
        } catch {
            state = .failed(StoreFailure(error))
        }
    }

    /// Disk work runs off the main actor so launch stays responsive.
    private static func openStore(appVersion: String) async throws -> LibraryStore {
        try await Task.detached(priority: .userInitiated) {
            // Increment 004 adds its preset store to `dependentStores` here, and
            // piece removal cascades to it with no other change.
            try LibraryStore.open(appVersion: appVersion, dependentStores: [])
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
