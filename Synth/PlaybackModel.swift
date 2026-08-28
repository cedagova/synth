import Foundation
import Observation
import SynthKit

/// What opening a piece is currently doing.
///
/// Named stages rather than a fraction: compilation and realization do not
/// report progress, and a fake progress bar that jumps to 90% and waits is a
/// worse answer than saying which of two steps is running.
enum PreparationStage: Equatable {
    case compiling
    case realizing

    var text: String {
        switch self {
        case .compiling: return "Compiling the score…"
        case .realizing: return "Preparing the performance…"
        }
    }
}

/// Why a piece will not play.
struct PlaybackFailure: Equatable {
    let summary: String
    let recovery: String?

    init(_ error: Error) {
        if let localized = error as? LocalizedError {
            summary = localized.errorDescription ?? String(describing: error)
            recovery = localized.recoverySuggestion
                ?? "The file you imported from is not affected."
        } else {
            summary = (error as NSError).localizedDescription
            recovery = nil
        }
    }
}

enum PlaybackLoadState: Equatable {
    case preparing(PreparationStage)
    case ready
    case failed(PlaybackFailure)
}

/// The transport screen's state, and the only thing in the app that drives
/// `PlaybackEngine`.
///
/// Three separate clocks meet here and it is worth being explicit about which
/// is which:
///
/// - the **render thread's** playhead, read through `PlaybackEngine` as a
///   single atomic load;
/// - the **notated** position, which is that playhead put through PLY001's
///   tempo map and expanded measure list — this is what the readout shows, so a
///   humanized performance still names the measure the score wrote; and
/// - the **UI ticker** below, which samples the first and derives the second.
///
/// The loop is enforced here rather than in the C core deliberately: the render
/// core is PLY003's and takes no loop, and a control-thread loop that seeks on
/// the fade the engine already performs is inaudible. The cost is that the wrap
/// lands within one ticker interval of the loop end; the ticker shortens its
/// own sleep as the boundary approaches so that interval is about a
/// millisecond, not the sixteen it would otherwise be.
@Observable
@MainActor
final class PlaybackModel {
    /// How often the transport is sampled while the music is playing.
    static let playingTickNanoseconds: UInt64 = 16_000_000

    /// …and while it is not. Nothing is moving, so this only has to notice the
    /// engine pausing itself.
    static let idleTickNanoseconds: UInt64 = 100_000_000

    /// How far ahead of a loop boundary the ticker starts sleeping in exact
    /// remaining time rather than in fixed steps.
    static let loopApproachMicroseconds: Int64 = 20_000

    /// What a skip button moves by.
    static let skipMicroseconds: Int64 = 5_000_000

    let piece: PieceRecord

    private(set) var loadState: PlaybackLoadState = .preparing(.compiling)

    private(set) var compiledScore: CompiledScore?
    private(set) var timeline: PerformanceTimeline?
    private(set) var navigator: PlaybackNavigator?

    // MARK: Transport, as last sampled

    private(set) var positionMicroseconds: Int64 = 0
    private(set) var transportState: PlaybackEngine.TransportState = .stopped
    private(set) var pauseReason: PlaybackEngine.PauseReason = .none

    /// How many times the loop has wrapped since it was set. Shown to the owner
    /// so a loop is visibly doing something even in a passage they do not know
    /// by ear.
    private(set) var loopPassCount = 0

    /// The last thing the transport has to say, including the honest reasons
    /// the engine paused itself.
    private(set) var statusMessage: String?

    // MARK: What the owner typed

    var measureField = ""
    var beatField = "1"
    var timeField = ""
    var loopFromField = ""
    var loopToField = ""

    private(set) var loop: LoopRange?

    /// The humanization the owner has chosen (REQ-012). Exactly two controls,
    /// per D4 — an enable and an amount.
    private(set) var humanization: HumanizationSettings

    /// Live slider value. Separate from `humanization` because a slider drag
    /// must not re-realize the piece on every intermediate value; the commit
    /// happens when the drag ends.
    var intensityDraft: Double

    var isReportShown = false

    /// Bumped so the view can move keyboard focus to a field a menu command
    /// asked for — the same mechanism the library uses for Find.
    private(set) var measureFocusRequests = 0
    private(set) var timeFocusRequests = 0

    // MARK: Collaborators

    private let store: LibraryStore
    private let engine: PlaybackEngine
    private var ticker: Task<Void, Never>?

    /// A seek asked for before the piece finished loading. The issue's failure
    /// clause: it queues rather than being dropped.
    ///
    /// A measure is queued separately from a time because a measure cannot be
    /// resolved at all until the score is compiled — there is no measure list
    /// yet — while a time is already absolute.
    private var queuedSeekMicroseconds: Int64?
    private var queuedMeasureSeek: (number: String, beat: Double)?

    /// `voiceProvider` is how increment 003's editor reaches this engine's
    /// voices: a provider built on a `SynthPatchLiveVoices` channel renders
    /// whatever the channel currently holds, and an edit published to that
    /// channel lands in the voices that are already playing. The default is the
    /// fixed default voice, which is the sound the app has always made.
    init(
        piece: PieceRecord,
        store: LibraryStore,
        voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider()
    ) {
        self.piece = piece
        self.store = store
        self.engine = PlaybackEngine(voiceProvider: voiceProvider)
        let stored = store.preferences.humanization()
        self.humanization = stored
        self.intensityDraft = Double(stored.intensity)
    }

    // MARK: Derived state

    var isReady: Bool { loadState == .ready }

    var isPlaying: Bool { transportState == .playing }

    var totalMicroseconds: Int64 { navigator?.totalMicroseconds ?? 0 }

    var position: ScorePosition? {
        navigator?.position(atMicroseconds: positionMicroseconds)
    }

    var positionText: String { TransportDisplay.positionText(position) }

    /// What the status line says after a jump.
    ///
    /// Past the last measure there is no position to name — `position` is nil
    /// by design, because the piece has no measure there — and the readout
    /// already says "end of the piece". Saying "Jumped to —." instead of that
    /// was what driving the app turned up.
    private var jumpedMessage: String {
        position == nil ? "Jumped to the end of the piece." : "Jumped to \(positionText)."
    }

    var elapsedText: String {
        TransportDisplay.elapsedOfTotalText(
            microseconds: positionMicroseconds,
            total: totalMicroseconds
        )
    }

    var spokenPosition: String {
        TransportDisplay.spokenPosition(
            position,
            microseconds: positionMicroseconds,
            total: totalMicroseconds
        )
    }

    /// Both reports, kept apart. They answer different questions and merging
    /// them would lose which stage could not honour what (REQ-014).
    var compilationReport: NotationReport? { compiledScore?.report }
    var realizationReport: NotationReport? { timeline?.report }

    /// How many distinct findings the piece has across both stages.
    var reportEntryCount: Int {
        (compilationReport?.entries.count ?? 0) + (realizationReport?.entries.count ?? 0)
    }

    var hasReportFindings: Bool { reportEntryCount > 0 }

    /// The piece's own title line, for the screen's header.
    var subtitle: String { piece.subtitleDescription }

    // MARK: Opening a piece

    /// Reads, compiles and realizes the piece, then hands it to the engine.
    ///
    /// Everything expensive runs off the main actor so the window is on screen
    /// and responsive from the first frame — which is what "long pieces must
    /// not block" means in practice.
    func prepare() async {
        loadState = .preparing(.compiling)
        startTicking()

        let piece = self.piece
        let contentStore = store.pieceContent
        do {
            let compiled = try await Task.detached(priority: .userInitiated) {
                try ScoreCompiler().compile(piece: piece, contentStore: contentStore)
            }.value
            compiledScore = compiled
            navigator = PlaybackNavigator(score: compiled)

            loadState = .preparing(.realizing)
            let realized = await Self.realize(compiled, humanization: humanization)
            try loadIntoEngine(realized)

            loadState = .ready
            statusMessage = readyMessage(for: compiled)
            applyQueuedSeek()
        } catch {
            loadState = .failed(PlaybackFailure(error))
            statusMessage = nil
        }
    }

    /// Stops the audio and the ticker. Called when the screen goes away.
    func close() {
        ticker?.cancel()
        ticker = nil
        engine.stop()
        engine.stopEngine()
    }

    private static func realize(
        _ score: CompiledScore,
        humanization: HumanizationSettings
    ) async -> PerformanceTimeline {
        await Task.detached(priority: .userInitiated) {
            PerformanceRealizer().realize(
                score,
                settings: RealizationSettings(humanization: humanization)
            )
        }.value
    }

    /// Hands a timeline to the engine on the main actor, which is the only
    /// thread that touches it.
    private func loadIntoEngine(_ realized: PerformanceTimeline) throws {
        timeline = realized
        try engine.load(timeline: realized)
        refreshTransport()
    }

    private func readyMessage(for score: CompiledScore) -> String {
        let measures = score.playbackMeasures.count
        let events = timeline?.eventCount ?? 0
        let notated = score.sourceMeasures.count
        let expansion = measures == notated
            ? "\(measures) measures"
            : "\(notated) notated measures played as \(measures)"
        return "Ready — \(expansion), \(events) notes."
    }

    // MARK: Transport

    func togglePlayPause() {
        guard isReady else { return }
        if transportState == .playing {
            engine.pause()
            statusMessage = "Paused."
        } else {
            startPlaying()
        }
        refreshTransport()
    }

    func play() {
        guard isReady, transportState != .playing else { return }
        startPlaying()
        refreshTransport()
    }

    func pause() {
        guard isReady, transportState == .playing else { return }
        engine.pause()
        statusMessage = "Paused."
        refreshTransport()
    }

    func stop() {
        guard isReady else { return }
        engine.stop()
        // Stop rewinds to the beginning, and the render thread will confirm it
        // — but only if the graph is running. Saying so here keeps the readout
        // honest when it is not.
        positionMicroseconds = 0
        loopPassCount = 0
        statusMessage = "Stopped."
        refreshTransport()
    }

    private func startPlaying() {
        // Playing on from the very end would pause again immediately. Rewinding
        // to the loop's start, or to the beginning, is what the owner meant.
        if pauseReason == .reachedEnd || positionMicroseconds >= totalMicroseconds {
            seekEngine(to: loop?.startMicroseconds ?? 0)
        }
        do {
            try engine.start()
        } catch {
            statusMessage = "Synth could not start audio playback: \(error). "
                + "Check that an output device is available."
            return
        }
        engine.play()
        statusMessage = loop.map { "Playing, looping \($0.displayText)." } ?? "Playing."
    }

    // MARK: Seeking

    /// Seeks to an absolute time, clamped inside the piece.
    ///
    /// Before the piece is ready the request is remembered rather than dropped:
    /// opening a long piece and immediately typing a measure has to work.
    func seek(toMicroseconds microseconds: Int64) {
        guard isReady else {
            queuedSeekMicroseconds = max(0, microseconds)
            statusMessage = "Will jump there once the piece is ready."
            return
        }
        seekEngine(to: microseconds)
        statusMessage = jumpedMessage
    }

    private func seekEngine(to microseconds: Int64) {
        let clamped = min(max(0, microseconds), max(0, totalMicroseconds))
        engine.seek(toMicroseconds: clamped)
        positionMicroseconds = clamped
    }

    /// Runs whatever the owner asked for while the piece was still loading.
    /// A measure wins over a bare time, because it is the more specific request
    /// and the two can only both be queued by asking twice.
    private func applyQueuedSeek() {
        if let queued = queuedMeasureSeek {
            queuedMeasureSeek = nil
            queuedSeekMicroseconds = nil
            guard let navigator,
                  let microseconds = navigator.microseconds(
                    forMeasureNumber: queued.number,
                    beat: queued.beat
                  )
            else {
                statusMessage = "This piece has no measure “\(queued.number)”."
                return
            }
            seekEngine(to: microseconds)
            statusMessage = jumpedMessage
            return
        }
        guard let queued = queuedSeekMicroseconds else { return }
        queuedSeekMicroseconds = nil
        seekEngine(to: queued)
        statusMessage = jumpedMessage
    }

    func goToStart() {
        guard isReady else { return seek(toMicroseconds: 0) }
        seekEngine(to: 0)
        statusMessage = "At the start."
    }

    func skip(byMicroseconds delta: Int64) {
        guard isReady else { return }
        seekEngine(to: positionMicroseconds + delta)
        statusMessage = jumpedMessage
    }

    /// Seeks to what the measure and beat fields say, or explains why it could
    /// not. A refusal is always better than seeking somewhere the owner did not
    /// ask for: there is no score on screen to notice it by.
    func seekToTypedMeasure() {
        let number = measureField.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else {
            statusMessage = "Type a measure number to jump to."
            return
        }

        let beatText = beatField.trimmingCharacters(in: .whitespaces)
        let beat: Double? = beatText.isEmpty ? 1.0 : TransportDisplay.parseBeat(beatText)
        guard let beat else {
            statusMessage = "“\(beatField)” is not a beat. Beats start at 1."
            return
        }

        // Before the score is compiled there is no measure list to resolve
        // against, so the request waits for one rather than being dropped.
        guard let navigator else {
            queuedMeasureSeek = (number, beat)
            statusMessage = "Will jump to measure \(number) once the piece is ready."
            return
        }
        guard let microseconds = navigator.microseconds(forMeasureNumber: number, beat: beat) else {
            statusMessage = "This piece has no measure “\(number)”."
            return
        }
        seek(toMicroseconds: microseconds)
    }

    func seekToTypedTime() {
        guard let microseconds = TransportDisplay.parseTime(timeField) else {
            statusMessage = "“\(timeField)” is not a time. Try 1:23 or 83.4."
            return
        }
        seek(toMicroseconds: microseconds)
    }

    func requestMeasureFocus() { measureFocusRequests += 1 }
    func requestTimeFocus() { timeFocusRequests += 1 }

    // MARK: Looping

    var isLooping: Bool { loop != nil }

    /// Turns the measure-range fields into a loop, or reports why they do not
    /// name one.
    func setLoopFromFields() {
        guard let navigator else { return }
        let from = loopFromField.trimmingCharacters(in: .whitespaces)
        let to = loopToField.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else {
            statusMessage = "A loop needs a first and a last measure."
            return
        }
        guard let range = navigator.loopRange(fromMeasureNumber: from, toMeasureNumber: to) else {
            statusMessage = "No loop from measure \(from) to measure \(to): "
                + "check both numbers are printed in this piece and in that order."
            return
        }
        loop = range
        loopPassCount = 0
        statusMessage = "Looping \(range.displayText)."
        // Start the loop from its beginning unless the playhead is already
        // inside it, so pressing Play does the obvious thing.
        if !range.contains(positionMicroseconds), isReady {
            seekEngine(to: range.startMicroseconds)
        }
    }

    func clearLoop() {
        guard loop != nil else { return }
        loop = nil
        loopPassCount = 0
        statusMessage = "Loop off."
    }

    func toggleLoop() {
        if loop == nil { setLoopFromFields() } else { clearLoop() }
    }

    /// "Looping measures 6–7 · 3 passes", or nil when nothing is looping.
    var loopDescription: String? {
        guard let loop else { return nil }
        let passes = loopPassCount == 1 ? "1 pass" : "\(loopPassCount) passes"
        return "Looping \(loop.displayText) · \(passes)"
    }

    // MARK: Humanization (REQ-012)

    /// Turns humanization on or off and re-realizes the piece under the new
    /// setting, keeping the playhead and whether it was playing.
    func setHumanizationEnabled(_ isEnabled: Bool) async {
        await apply(HumanizationSettings(isEnabled: isEnabled, intensity: humanization.intensity))
    }

    /// Commits the slider. Called when the drag ends, not on every value.
    func commitIntensity() async {
        let intensity = Int(intensityDraft.rounded())
        guard intensity != humanization.intensity else { return }
        await apply(HumanizationSettings(isEnabled: humanization.isEnabled, intensity: intensity))
    }

    private func apply(_ settings: HumanizationSettings) async {
        guard settings != humanization else { return }
        humanization = settings
        intensityDraft = Double(settings.intensity)

        // The choice is the owner's and outlives this piece, so it is written
        // before anything else can fail — and a write that fails is reported,
        // not discarded. The setting still applies to this session, which is
        // right; what the owner must not be told is that it was saved when it
        // was not, only to find humanization back on at the next launch with
        // nothing having said why.
        let saveFailure = await Self.persist(settings, to: store.preferences)

        guard let compiledScore else {
            statusMessage = Self.humanizationMessage(settings, saveFailure: saveFailure)
            return
        }

        let wasPlaying = transportState == .playing
        let resumeAt = positionMicroseconds
        let realized = await Self.realize(compiledScore, humanization: settings)

        do {
            // `load` stops the graph; the position is carried across by hand
            // because a new program starts at zero.
            try loadIntoEngine(realized)
            seekEngine(to: resumeAt)
            if wasPlaying {
                try engine.start()
                engine.play()
            }
            statusMessage = Self.humanizationMessage(settings, saveFailure: saveFailure)
            refreshTransport()
        } catch {
            statusMessage = "Could not apply the humanization change: \(error)"
        }
    }

    /// Writes the choice off the main actor, returning the reason it could not
    /// be written, or nil.
    private static func persist(
        _ settings: HumanizationSettings,
        to preferences: PreferenceStore
    ) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            do {
                try preferences.setHumanization(settings)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
            }
        }.value
    }

    private static func humanizationMessage(
        _ settings: HumanizationSettings,
        saveFailure: String?
    ) -> String {
        let state = settings.isLiteral
            ? "Humanization off — playing exactly as written"
            : "Humanization on at \(settings.intensity)%"
        guard let saveFailure else { return "\(state)." }
        return "\(state) for this session only — the setting could not be saved, so it will be "
            + "back to its last saved value next launch. \(saveFailure)"
    }

    // MARK: The ticker

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshTransport()
                let delay = self.nextTickNanoseconds()
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Samples the engine, enforces the loop, and turns the engine's own
    /// reasons for pausing into something the owner can read.
    private func refreshTransport() {
        let previousState = transportState
        let previousReason = pauseReason

        // The render thread owns the playhead, but it only moves while the
        // graph is running: a seek is applied by the render callback, so before
        // the first Play — and for the few milliseconds a seek spends fading —
        // the engine still reports where it *was*. Adopting that would make the
        // readout lie about a position the owner just asked for, and would let
        // the loop wrap twice off one crossing. While a seek is outstanding the
        // model's own intended position stands instead.
        if engine.isSeekSettled {
            positionMicroseconds = engine.playbackPositionMicroseconds
        }
        transportState = engine.transportState
        pauseReason = engine.pauseReason

        if let loop,
           transportState == .playing,
           engine.isSeekSettled,
           let target = loop.wrapTarget(forPosition: positionMicroseconds) {
            engine.seek(toMicroseconds: target)
            positionMicroseconds = target
            loopPassCount += 1
        }

        guard transportState != previousState || pauseReason != previousReason else { return }
        switch (transportState, pauseReason) {
        case (.paused, .reachedEnd):
            statusMessage = "Reached the end of the piece."
        case (.paused, .overload):
            statusMessage = "Playback paused: the audio engine could not keep up. "
                + "The position is kept, so pressing Play resumes here."
        case (.paused, .deviceLost):
            statusMessage = "Playback paused: the output device went away. "
                + "The position is kept, so pressing Play resumes on the new one."
        default:
            break
        }
    }

    /// Sleeps in 16 ms steps normally, and in exactly the remaining time when a
    /// loop boundary is close, so the wrap lands within about a millisecond of
    /// the loop end instead of within a whole frame of it.
    private func nextTickNanoseconds() -> UInt64 {
        guard transportState == .playing else { return Self.idleTickNanoseconds }
        if let loop, loop.contains(positionMicroseconds) {
            let remaining = loop.endMicroseconds - positionMicroseconds
            if remaining > 0, remaining < Self.loopApproachMicroseconds {
                return UInt64(remaining) * 1_000
            }
        }
        return Self.playingTickNanoseconds
    }

    // MARK: Diagnostics

    /// What the render thread actually did. Surfaced so a dropout claim is a
    /// measurement rather than an impression.
    var renderStatistics: PlaybackEngine.RenderStatistics { engine.statistics }

    /// The digest of the exact interpretation now loaded. Two timelines with
    /// the same seed were realized identically (REQ-012's "same config twice
    /// sounds identical").
    var timelineSeed: String? { timeline?.seed }
}
