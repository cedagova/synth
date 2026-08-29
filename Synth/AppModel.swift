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

    /// The instrument catalog, once it has been opened.
    ///
    /// Kept after the screen closes, deliberately: a 2.6 GB download must not
    /// stop because the owner went back to their piece. `suspend()` on the
    /// store closing is the only thing that ends a transfer early.
    private(set) var instrumentCatalog: InstrumentCatalogModel?

    /// True while the catalog is the screen showing.
    private(set) var isInstrumentCatalogShowing = false

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
    ///
    /// The setter stays private — nothing outside this model decides when the
    /// store opens — while the getter is internal so `SynthAppTests` can put a
    /// sound in the same library the app is holding and then drive the real
    /// screens over it. Reading a test's assertions from a *second* store would
    /// prove nothing about the one the app is using.
    private(set) var store: LibraryStore?

    /// Tail of the chain of bootstrap attempts. Each new attempt waits for it,
    /// which is what keeps the database from ever being opened twice at once —
    /// a plain `store == nil` guard cannot do that, because it is re-checked
    /// only after the first attempt has already suspended.
    private var attempts: Task<Void, Never>?

    /// Where the store is opened.
    ///
    /// Nil means `<Application Support>/Synth`, which is what the app always
    /// uses — `SynthApp` constructs this model with no arguments. It is
    /// injectable for exactly one reason: `SynthAppTests` drives this model for
    /// real, and a test that bootstrapped into the owner's own container would
    /// be writing to their library. A documented seam on one initialiser, the
    /// same shape `SoundLibrary` uses for its clock and its identity generator.
    private let containerOverride: AppContainer?

    nonisolated init(container: AppContainer? = nil) {
        self.containerOverride = container
    }

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
        // Play-through belongs to the piece that was open, not to the studio's
        // sound. Leaving it on would hand the incoming piece's lines away
        // before it had ever played its own preset.
        studio?.editor.stopPlayingPieceThroughSound()
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
            let instrumentEditor = InstrumentEditorModel(store: store)
            wireStudioToPlayback(editor: editor, instrumentEditor: instrumentEditor)
            studio = SoundStudioModel(
                store: store, editor: editor, instrumentEditor: instrumentEditor
            )
        }
        isStudioShowing = true
    }

    /// Connect the two editors to the open piece.
    ///
    /// **Extracted so it can be tested.** The increment-004 effort review found
    /// that nothing covered these closures: the behaviour was proved one layer
    /// below, at `SoundEditorModel` and `AssignmentModel.publishEditedSound`,
    /// so a wiring regression here — a closure dropped, or pointed at the wrong
    /// model — would have passed every test while REQ-018 quietly stopped
    /// working in the app. Increment 005 adds a second editor with the same
    /// three closures, which doubles the surface, so this leaf closes the gap:
    /// `AppModelWiringTests` calls this with stubs and asserts each closure
    /// reaches the model it names.
    ///
    /// `nonisolated` on the parameters is not needed — everything here is main
    /// actor — but `[weak self]` is: the editors outlive individual playbacks
    /// and must not keep the app model alive through a closure.
    func wireStudioToPlayback(
        editor: SoundEditorModel,
        instrumentEditor: InstrumentEditorModel
    ) {
        editor.onPlayThroughChanged = { [weak self] isPlayingThrough in
            self?.playback?.setPlayingThroughEditedSound(isPlayingThrough)
        }
        // REQ-018 on an assigned line: an edit reaches every line of the
        // open piece that plays this sound, while it plays, and nothing
        // else.
        editor.onPatchEdited = { [weak self] soundID, patch in
            self?.playback?.assignment.publishEditedSound(id: soundID, patch: patch)
        }
        // The same requirement for a customized instrument (INS003): moving a
        // tone control reaches every line playing that variant, on the notes
        // already sounding, without rebuilding the program.
        instrumentEditor.onVariantEdited = { [weak self] soundID, variant in
            self?.playback?.assignment.publishEditedVariant(id: soundID, variant: variant)
        }
    }

    func closeSoundStudio() {
        isStudioShowing = false
    }

    // MARK: - The instrument catalog

    /// Show the curated instrument catalog (REQ-020, REQ-022).
    ///
    /// Built once and kept, because the model owns the download tasks. Sits
    /// over whatever else is showing, like the studio does, so an open piece
    /// keeps playing while a library downloads behind it.
    func openInstrumentCatalog() {
        guard let store else { return }
        if instrumentCatalog == nil {
            instrumentCatalog = InstrumentCatalogModel(store: store)
        }
        isInstrumentCatalogShowing = true
    }

    func closeInstrumentCatalog() {
        isInstrumentCatalogShowing = false
    }

    /// Runs the first-run instrument offer once the store is open.
    ///
    /// Built without showing the screen: the offer is a sheet the catalog model
    /// raises, and `RootView` shows the catalog when it does. An owner who
    /// declines never sees the catalog screen at all.
    private func prepareInstrumentsForFirstRun() {
        guard let store else { return }
        let catalog = instrumentCatalog ?? InstrumentCatalogModel(store: store)
        instrumentCatalog = catalog
        catalog.prepareForFirstRun()
        guard catalog.isShowingFirstRunOffer else { return }

        // Declining puts the screen away again. An owner who never asked to see
        // the catalog and said no to it should be back where they were, not
        // left looking at the thing they just turned down. Accepting keeps it
        // open, because that is where the progress is.
        catalog.onFirstRunOfferAnswered = { [weak self] didAccept in
            guard let self, !didAccept else { return }
            self.isInstrumentCatalogShowing = false
        }
        isInstrumentCatalogShowing = true
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
            // Downloads write into the container this store owns, so they have
            // to stop before it is closed underneath them. Whatever has already
            // arrived stays staged and resumes on the next attempt.
            instrumentCatalog?.suspend()
            instrumentCatalog = nil
            isInstrumentCatalogShowing = false
            current.close()
            store = nil
        }
        // An attempt queued behind a successful one has nothing left to do.
        guard store == nil else { return }

        state = .loading
        let appVersion = Bundle.main.synthVersionString
        do {
            let opened = try await Self.openStore(
                appVersion: appVersion, container: containerOverride
            )
            store = opened
            state = .ready(LibraryModel(store: opened))
            prepareInstrumentsForFirstRun()
        } catch {
            state = .failed(StoreFailure(error))
        }
    }

    /// Disk work runs off the main actor so launch stays responsive.
    private static func openStore(
        appVersion: String, container: AppContainer?
    ) async throws -> LibraryStore {
        try await Task.detached(priority: .userInitiated) {
            // The preset store registers itself inside `open`, in both the
            // piece-removal cascade (REQ-003) and the sound-deletion embed hook
            // (REQ-029), so no call site can open a store without them.
            try LibraryStore.open(container: container, appVersion: appVersion)
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
