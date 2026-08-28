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

    /// The open piece's transport, or nil when the library is showing.
    ///
    /// One at a time, deliberately: there is one window, one audio engine and
    /// one output device, and a second transport would be competing for all
    /// three. Opening another piece replaces this one.
    private(set) var playback: PlaybackModel?

    /// The sound studio, once it has been opened. Nil until then, because
    /// building it opens the sound library and starts an audio engine, and an
    /// owner who never designs a sound should pay for neither.
    private(set) var studio: SoundStudioModel?

    /// True while the studio is the screen showing.
    ///
    /// Separate from `studio != nil` because leaving the studio must not throw
    /// the sound under edit away: the owner goes back to the transport, listens,
    /// and comes back to the same unsaved patch.
    private(set) var isStudioShowing = false

    /// The channel every piece's playback renders through.
    ///
    /// It holds `SynthPatch.defaultVoice`, which is exactly what increment
    /// 002's built-in voice sounded like and exactly what SYN001 replaced it
    /// with — so with the studio closed the app makes the sound it always made.
    /// What the channel adds is a way for the editor to replace that patch in
    /// the voices that are *already rendering*, which is how a piece can be
    /// played through the sound under edit without the piece stopping.
    let playbackChannel = SynthPatchLiveVoices(patch: .defaultVoice)

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

    // MARK: - Opening a piece for playback

    /// Opens `piece` on the transport screen (REQ-009).
    ///
    /// Compilation happens on the transport screen rather than here, so the
    /// window changes immediately and a long piece is prepared in front of the
    /// owner instead of behind a frozen library.
    func openPlayback(for piece: PieceRecord) {
        guard let store else { return }
        if playback?.piece.id == piece.id { return }
        playback?.close()
        playback = PlaybackModel(
            piece: piece,
            store: store,
            voiceProvider: SynthPatchVoiceProvider(live: playbackChannel)
        )
        isStudioShowing = false
    }

    // MARK: - The sound studio

    /// Show the sound-design surface (REQ-016, REQ-017).
    ///
    /// Built once and then kept, so leaving it to listen to the piece and
    /// coming back does not lose an unsaved edit. It sits *over* whatever else
    /// is showing rather than replacing it: an open piece keeps playing while
    /// the studio is up, which is the whole point of being able to edit its
    /// sound while it does.
    func openSoundStudio() {
        guard let store else { return }
        if studio == nil {
            let editor = SoundEditorModel(store: store, playbackChannel: playbackChannel)
            studio = SoundStudioModel(store: store, editor: editor)
        }
        isStudioShowing = true
    }

    func closeSoundStudio() {
        isStudioShowing = false
    }

    /// The Playback ▸ Open Selected Piece command, and the library's own
    /// Return key and Play button.
    func openSelectedPieceForPlayback() {
        guard let piece = library?.selectedPiece else { return }
        openPlayback(for: piece)
    }

    func closePlayback() {
        playback?.close()
        playback = nil
    }

    private func performBootstrap(reopen: Bool) async {
        if reopen, let current = store {
            closePlayback()
            // The studio holds a live reference into the store's sound library
            // and an audio engine of its own; both have to go before the store
            // underneath them does.
            studio?.editor.suspend()
            studio = nil
            isStudioShowing = false
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
            // The preset store registers itself inside `open`, in both the
            // piece-removal cascade (REQ-003) and the sound-deletion embed hook
            // (REQ-029), so no call site can open a store without them.
            try LibraryStore.open(appVersion: appVersion)
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
