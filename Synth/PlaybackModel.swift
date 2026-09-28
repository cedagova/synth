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

    /// The score as it is being played: `sourceScore` with the owner's tempo
    /// applied. Everything that turns time into measures, or measures into
    /// time, reads this one, so the readout and the seeks agree with the
    /// music at any tempo.
    private(set) var compiledScore: CompiledScore?

    /// The score exactly as compiled from the file, at the file's own tempo.
    /// Kept so a tempo change scales from the source rather than compounding.
    private var sourceScore: CompiledScore?

    /// The owner's tempo, as a percentage of the file's (REQ-009). Read from
    /// the active preset in `prepare()`, like humanization.
    private(set) var tempoPercent = TempoMap.defaultTempoPercent

    /// Live slider value, committed when the drag ends — a re-realization
    /// per intermediate value would stutter a long score.
    var tempoDraft: Double = Double(TempoMap.defaultTempoPercent)
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

    /// Bumped whenever the playhead jumps rather than runs: a seek, a skip, a
    /// stop's rewind, a loop wrap. Observers that extrapolate the position from
    /// a rate — Now Playing does — republish on this instead of on every tick.
    private(set) var playheadJumpCount = 0

    /// The last thing the transport has to say, including the honest reasons
    /// the engine paused itself.
    private(set) var statusMessage: String?

    // MARK: What the owner typed

    var measureField = ""
    var beatField = "1"
    var timeField = ""
    var loopFromField = ""
    var loopToField = ""

    /// The readout's in-place segment editor (the DAW-counter idiom: each
    /// number in the display is the input for exactly that number). One draft
    /// is enough — only one segment edits at a time. Prefilled when editing
    /// begins; ignored unless committed with Return.
    var segmentDraft = ""

    private(set) var loop: LoopRange?

    /// The humanization the owner has chosen (REQ-012). Exactly two controls,
    /// per D4 — an enable and an amount.
    private(set) var humanization: HumanizationSettings

    /// Live slider value. Separate from `humanization` because a slider drag
    /// must not re-realize the piece on every intermediate value; the commit
    /// happens when the drag ends.
    var intensityDraft: Double

    /// The phrase expression the owner has chosen (REQ-003). Two controls, per
    /// D65-1 — an enable and an amount — for the reason humanization has two.
    private(set) var expression: ExpressionSettings

    /// Live slider value, for the reason `intensityDraft` is one.
    var expressionAmountDraft: Double

    /// The produced master the owner has chosen (REQ-005, D65-2 option A): bus
    /// cohesion and loudness calibration, as one switch. The true-peak ceiling
    /// is not here because it has no control (AD-P6).
    private(set) var producedMaster: ProducedMasterSettings

    /// The temperament and reference pitch the owner has chosen (REQ-006,
    /// D65-1): two pickers, and no third control.
    private(set) var tuning: TuningSettings

    // MARK: Preset adoption (#96)

    /// The one pending adoption of a loaded preset's performance settings, or
    /// nil when none is pending. A newer load cancels it; see `adoptPreset`.
    @ObservationIgnored private var adoptionTask: Task<Void, Never>?

    /// Bumped by every re-realization when it starts. A realization that
    /// finishes to find the counter moved was overtaken by a newer one, which
    /// realizes under every setting now in force, so its own result is stale and
    /// is dropped rather than loaded over the newer one. This is what keeps an
    /// owner edit made during a pending adoption from being undone by it.
    @ObservationIgnored private var realizationGeneration = 0

    /// Re-realizations started and not yet returned to their caller. While one
    /// is in flight the loaded timeline is about to be replaced, so it is no
    /// guide to what the engine will end up playing — see `applyAdoptedPreset`.
    @ObservationIgnored private var realizationsInFlight = 0

    /// The tempo the loaded timeline was realized at. Differs from
    /// `tempoPercent` only while a tempo change is still being realized, and is
    /// what the playhead's position has to be read against in that window.
    @ObservationIgnored private var timelineTempoPercent = TempoMap.defaultTempoPercent

    /// How many times this piece has been realized. The one seam the tests need
    /// to prove an adoption realizes once rather than once per setting.
    @ObservationIgnored private(set) var realizationCount = 0

    /// Test seam, nil in the app: awaited after a re-realization finishes and
    /// before it is checked for being overtaken, so a test can hold an older
    /// realization until a newer one has loaded — the one order the
    /// `realizationGeneration` check exists for, and not one the thread pool can
    /// be relied on to produce.
    @ObservationIgnored var realizationDidFinish: (@MainActor () async -> Void)?

    /// Bumped so the view can move keyboard focus to a field a menu command
    /// asked for — the same mechanism the library uses for Find.
    private(set) var measureFocusRequests = 0
    private(set) var timeFocusRequests = 0

    // MARK: Collaborators

    private let store: LibraryStore
    private let engine: PlaybackEngine
    private var ticker: Task<Void, Never>?

    /// The sound every line renders through when the preset is not in charge —
    /// the sound studio's live channel, in the built app.
    private let baseVoiceProvider: LineVoiceProvider

    /// The assignment, mixer and preset surface for this piece (ASN002).
    ///
    /// Owned here rather than by the screen because it writes to the same
    /// engine the transport does, and the order the two touch it in matters: a
    /// preset can only be applied once a program is loaded, since the mixer
    /// half addresses that program's lines.
    let assignment: AssignmentModel

    /// The export surface for this piece (REQ-026).
    ///
    /// Owned here because an export is of *this* piece's timeline and *this*
    /// piece's preset, and both live on this model. It renders on its own
    /// thread; see `ExportModel` for why that crossing is one value type and
    /// one flag wide.
    let export: ExportModel

    /// The "Export Stems…" surface for this piece (#90): one file per line
    /// the mix plays, from the same request the mix export builds.
    let stemExport: StemExportModel

    /// A seek asked for before the piece finished loading. The issue's failure
    /// clause: it queues rather than being dropped.
    ///
    /// A measure is queued separately from a time because a measure cannot be
    /// resolved at all until the score is compiled — there is no measure list
    /// yet — while a time is already absolute.
    private var queuedSeekMicroseconds: Int64?
    private var queuedMeasureSeek: (number: String, beat: Double)?

    /// `voiceProvider` is the sound every line starts on, before the piece's
    /// own preset replaces it.
    ///
    /// It still matters, and for two reasons. It is what the engine renders in
    /// the moment between loading the timeline and applying the preset; and it
    /// is how increment 003's editor takes the whole piece over — a provider
    /// built on a `SynthPatchLiveVoices` channel renders whatever the channel
    /// currently holds, which is what ⌥⌘P uses. From ASN002 onwards the normal
    /// state is per-line sounds from the active preset, and play-through is an
    /// explicit, reversible override of them.
    init(
        piece: PieceRecord,
        store: LibraryStore,
        voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider()
    ) {
        self.piece = piece
        self.store = store
        self.baseVoiceProvider = voiceProvider
        let engine = PlaybackEngine(voiceProvider: voiceProvider)
        self.engine = engine
        self.assignment = AssignmentModel(store: store, engine: engine)
        self.export = ExportModel(pieceTitle: piece.title)
        self.stemExport = StemExportModel(pieceTitle: piece.title)
        // The stored value lives on the piece's active preset and is adopted
        // in `prepare()`, before the first realization; this is only the value
        // for the instant before that.
        self.humanization = .standard
        self.intensityDraft = Double(HumanizationSettings.standard.intensity)
        self.expression = .standard
        self.expressionAmountDraft = Double(ExpressionSettings.standard.amount)
        self.producedMaster = .standard
        self.tuning = .standard

        wireExport()
        assignment.onPresetLoaded = { [weak self] content in
            self?.adoptPreset(content)
        }
        wireCompare()
    }

    /// Connect the export surface to this piece.
    ///
    /// **Extracted so it can be tested**, exactly as `AppModel.wireStudioToPlayback`
    /// is and for the same reason the increment-004 review gave: a closure that
    /// is only installed, never asserted, can be deleted and every other test
    /// still passes while the feature quietly stops working.
    /// `ExportWiringTests` calls each of these and checks it reaches this model.
    ///
    /// `[weak self]` because the export's task outlives an individual render
    /// and must not keep a closed piece alive.
    private func wireExport() {
        // Export always renders the active preset (D5): Compare ends first, so
        // the timeline read below is the active preset's, not the reference's.
        export.willExport = { [weak self] in self?.endCompare() }
        export.presetName = { [weak self] in self?.assignment.activePreset?.name }
        export.caveat = { [weak self] in self?.assignment.exportCaveat }
        export.makeRequest = { [weak self] settings in
            guard let self, let timeline = self.timeline else { return nil }
            // The timeline already carries the humanization that produced it,
            // so an export cannot disagree with live playback about how
            // humanized the piece is: there is one realization, and both read
            // it.
            return self.assignment.exportRequest(timeline: timeline, settings: settings)
        }
        stemExport.caveat = { [weak self] in self?.assignment.exportCaveat }
        stemExport.makeRequest = { [weak self] settings in
            guard let self, let timeline = self.timeline else { return nil }
            return self.assignment.stemExportRequest(
                timeline: timeline, settings: settings, pieceTitle: self.piece.title
            )
        }
    }

    // MARK: Derived state

    var isReady: Bool { loadState == .ready }

    var isPlaying: Bool { transportState == .playing }

    var totalMicroseconds: Int64 { navigator?.totalMicroseconds ?? 0 }

    var position: ScorePosition? {
        navigator?.position(atMicroseconds: positionMicroseconds)
    }

    /// The scrubber's in-flight target, while a drag is under way. The readout
    /// follows it live — the point of scrubbing is watching where you are —
    /// but the engine, the loop and measure stepping keep reading the real
    /// playhead until the drag commits.
    var scrubMicroseconds: Int64?

    /// What the readout shows: the drag target while scrubbing, the playhead
    /// otherwise.
    private var displayedMicroseconds: Int64 { scrubMicroseconds ?? positionMicroseconds }

    private var displayedPosition: ScorePosition? {
        navigator?.position(atMicroseconds: displayedMicroseconds)
    }

    var positionText: String { TransportDisplay.positionText(displayedPosition) }

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
            microseconds: displayedMicroseconds,
            total: totalMicroseconds
        )
    }

    var spokenPosition: String {
        TransportDisplay.spokenPosition(
            displayedPosition,
            microseconds: displayedMicroseconds,
            total: totalMicroseconds
        )
    }

    /// The piece's own title line, for the screen's header.
    var subtitle: String { piece.subtitleDescription }

    // MARK: Opening a piece

    /// Reads, compiles and realizes the piece, then hands it to the engine.
    ///
    /// Everything expensive runs off the main actor so the window is on screen
    /// and responsive from the first frame — which is what "long pieces must
    /// not block" means in practice.
    func prepare() async {
        // **Preparing twice would stop the music.**
        //
        // This runs from the transport screen's `.task`, and that screen is now
        // re-created every time the sound studio is opened over the piece and
        // closed again. Compiling and realizing a second time is wasted work;
        // handing the result to `PlaybackEngine.load` is worse than wasted,
        // because loading a program stops the graph and rewinds. A piece that
        // is already prepared is already prepared.
        if case .ready = loadState {
            startTicking()
            // Coming back from the sound studio, where a sound this piece uses
            // may have been created, edited or deleted. Only re-applies to the
            // engine if the sounds actually moved, so returning from the studio
            // having changed nothing costs the music nothing.
            assignment.refreshFromStore()
            return
        }

        loadState = .preparing(.compiling)
        startTicking()

        let piece = self.piece
        let contentStore = store.pieceContent
        do {
            let source = try await Task.detached(priority: .userInitiated) {
                try ScoreCompiler().compile(piece: piece, contentStore: contentStore)
            }.value
            sourceScore = source

            loadState = .preparing(.realizing)
            // The active preset's performance settings are read before the
            // first realization so the piece opens under its stored settings
            // rather than being realized twice. A piece with no preset yet
            // realizes under the standard settings, which is also what its
            // first preset will store — and a preset stored before the
            // expression field existed reads as on, which is where D65-3
            // actually reaches the owner's ear.
            if let preset = try? store.presets.activePreset(forPieceID: source.pieceID) {
                humanization = preset.content.humanization
                intensityDraft = Double(preset.content.humanization.intensity)
                expression = preset.content.expression
                expressionAmountDraft = Double(preset.content.expression.amount)
                producedMaster = preset.content.producedMaster
                tuning = preset.content.tuning
                tempoPercent = preset.content.tempoPercent
                tempoDraft = Double(preset.content.tempoPercent)
            }
            let compiled = source.scalingTempo(toPercent: tempoPercent)
            compiledScore = compiled
            navigator = PlaybackNavigator(score: compiled)
            let realized = await realizeUnderCurrentSettings(compiled)
            try loadIntoEngine(realized, tempoPercent: tempoPercent)

            // After the program exists, never before: the preset's mixer half
            // addresses the loaded program's lines, and its sound half replaces
            // that program's voices. REQ-007's first-open preset is created
            // here, by the same call that reads an existing one.
            assignment.open(score: compiled)

            loadState = .ready
            statusMessage = readyMessage(for: compiled)
            applyQueuedSeek()
        } catch {
            loadState = .failed(PlaybackFailure(error))
            statusMessage = nil
        }
    }

    /// The sound studio took every line over, or gave them back (SYN003's
    /// ⌥⌘P).
    ///
    /// Taking them over needs no rebuild — the live channel is already every
    /// line's provider until the preset replaces it, and publishing into it
    /// reaches the running voices. Giving them back does: the preset's sounds
    /// have to be built into a program again. The playhead and the mix survive
    /// both, so the music does not restart either way.
    func setPlayingThroughEditedSound(_ isPlayingThrough: Bool) {
        guard isReady else { return }
        if isPlayingThrough {
            endCompare()
            assignment.setSuspendedByPlayThrough(true)
            do {
                try engine.setVoices(.uniform(baseVoiceProvider))
            } catch {
                statusMessage = "Could not route the piece through the sound being edited: \(error)"
            }
        } else {
            assignment.setSuspendedByPlayThrough(false)
        }
        refreshTransport()
    }

    /// Stops the audio and the ticker. Called when the screen goes away.
    func close() {
        // The engine is about to stop; there is nothing to fade back to.
        compareGeneration += 1
        compareReturn = nil
        ticker?.cancel()
        ticker = nil
        // A render outlives the window unless something stops it, and one that
        // finished after the piece closed would publish a file the owner has
        // stopped expecting. Cancelling leaves nothing behind, by construction.
        export.close()
        stemExport.close()
        engine.stop()
        engine.stopEngine()
    }

    /// Realizes `score` under the humanization and expression in force now,
    /// off the main actor. Every realization goes through here, which is what
    /// makes `realizationCount` an honest count.
    private func realizeUnderCurrentSettings(
        _ score: CompiledScore
    ) async -> PerformanceTimeline {
        realizationCount += 1
        return await Self.realize(score, humanization: humanization, expression: expression)
    }

    /// A re-realization that yields nil if a newer one started while it ran —
    /// see `realizationGeneration`. The newer one carries every setting this
    /// one would have, so dropping the older result loses nothing.
    private func realizeUnlessOvertaken(_ score: CompiledScore) async -> PerformanceTimeline? {
        realizationGeneration += 1
        let generation = realizationGeneration
        realizationsInFlight += 1
        let realized = await realizeUnderCurrentSettings(score)
        await realizationDidFinish?()
        realizationsInFlight -= 1
        return generation == realizationGeneration ? realized : nil
    }

    private static func realize(
        _ score: CompiledScore,
        humanization: HumanizationSettings,
        expression: ExpressionSettings
    ) async -> PerformanceTimeline {
        await Task.detached(priority: .userInitiated) {
            PerformanceRealizer().realize(
                score,
                settings: RealizationSettings(
                    humanization: humanization, expression: expression
                )
            )
        }.value
    }

    /// Hands a timeline to the engine on the main actor, which is the only
    /// thread that touches it.
    private func loadIntoEngine(_ realized: PerformanceTimeline, tempoPercent: Int) throws {
        timeline = realized
        timelineTempoPercent = tempoPercent
        // Before `load`, so the program is measured once as it is built rather
        // than built, measured and then measured again (MST001).
        engine.producedMaster = producedMaster
        // Before `load` for a stronger reason (TUN001): tuning is built into each
        // voice, so setting it afterwards would throw the program away and build a
        // second one. With no timeline loaded yet this is a bookkeeping write.
        try engine.setTuning(tuning)
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
        var ready = "Ready — \(expansion), \(events) notes."
        // The produced master's one failure mode the owner has to be told about:
        // the analysis could not run, so the piece plays at its own level rather
        // than the calibrated one. Silence is never the answer, and neither is
        // saying nothing (MST001).
        if let sentence = engine.masterCalibration?.statusSentence {
            ready += " " + sentence
        }
        // And the tuning's one failure mode, said here for the same reason: the
        // preset named a temperament this build does not know, the piece is
        // playing in equal temperament, and the owner would otherwise have no way
        // to find that out (REQ-006's failure clause, TUN001).
        if let sentence = tuning.failureSentence {
            ready += " " + sentence
        }
        return ready
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
        playheadJumpCount += 1
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
        playheadJumpCount += 1
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

    // MARK: In-place readout editing

    /// The individually editable numbers of the readout. Editing one replaces
    /// exactly that component of the position and keeps the rest — which is
    /// why it matters which segment was clicked.
    enum ReadoutSegment {
        case measure, beat, minutes, seconds, tenths
    }

    /// The elapsed time as the readout's segments show it, in tenths.
    private var elapsedTenthsTotal: Int64 {
        (max(0, positionMicroseconds) + 50_000) / 100_000
    }

    var elapsedMinutesText: String { "\((displayedTenthsTotal / 600))" }
    var elapsedSecondsText: String {
        let seconds = (displayedTenthsTotal / 10) % 60
        return seconds < 10 ? "0\(seconds)" : "\(seconds)"
    }
    var elapsedTenthsText: String { "\(displayedTenthsTotal % 10)" }
    var totalElapsedText: String { TransportDisplay.elapsedText(microseconds: totalMicroseconds) }

    private var displayedTenthsTotal: Int64 {
        (max(0, displayedMicroseconds) + 50_000) / 100_000
    }

    var measureText: String { displayedPosition?.measureNumber ?? "—" }
    var beatText: String {
        displayedPosition.map { TransportDisplay.beatText($0.beat) } ?? "—"
    }
    /// " (pass 2)" while a repeat is replaying a printed measure; empty
    /// otherwise.
    var passText: String {
        guard let pass = displayedPosition?.pass, pass > 1 else { return "" }
        return " (pass \(pass))"
    }

    /// What the segment editor lets the owner type, enforced keystroke by
    /// keystroke: ASCII digits everywhere, one dot in the beat, and a hard
    /// length cap per segment. A disallowed character is simply not entered.
    static func sanitizedDraft(_ text: String, for segment: ReadoutSegment) -> String {
        let maxLength: Int
        switch segment {
        case .measure: maxLength = 4
        case .beat: maxLength = 4
        case .minutes: maxLength = 3
        case .seconds: maxLength = 2
        case .tenths: maxLength = 1
        }
        var kept = ""
        for character in text {
            if character.isASCII && character.isNumber {
                kept.append(character)
            } else if character == ".", segment == .beat, !kept.contains(".") {
                kept.append(character)
            }
        }
        return String(kept.prefix(maxLength))
    }

    /// What a segment's editor starts from — its current value, from the real
    /// playhead.
    func currentSegmentValue(_ segment: ReadoutSegment) -> String {
        switch segment {
        case .measure: return position?.measureNumber ?? ""
        case .beat: return position.map { TransportDisplay.beatText($0.beat) } ?? ""
        case .minutes: return "\(elapsedTenthsTotal / 600)"
        case .seconds:
            // Zero-padded exactly as displayed, so opening the editor keeps
            // the width it already had instead of jolting the line.
            let seconds = (elapsedTenthsTotal / 10) % 60
            return seconds < 10 ? "0\(seconds)" : "\(seconds)"
        case .tenths: return "\(elapsedTenthsTotal % 10)"
        }
    }

    /// Commits the segment editor: the typed value replaces that component of
    /// the position, everything else stays where it is.
    func commitSegment(_ segment: ReadoutSegment) {
        let draft = segmentDraft.trimmingCharacters(in: .whitespaces)
        guard !draft.isEmpty else { return }

        switch segment {
        case .measure:
            measureField = draft
            beatField = position.map { TransportDisplay.beatText($0.beat) } ?? "1"
            seekToTypedMeasure()

        case .beat:
            guard let position else {
                statusMessage = "There is no measure here to place a beat in."
                return
            }
            measureField = position.measureNumber
            beatField = draft
            seekToTypedMeasure()

        case .minutes, .seconds, .tenths:
            guard let value = Int(draft), value >= 0 else {
                statusMessage = "“\(draft)” is not a number."
                return
            }
            var minutes = elapsedTenthsTotal / 600
            var seconds = (elapsedTenthsTotal / 10) % 60
            var tenths = elapsedTenthsTotal % 10
            switch segment {
            case .minutes: minutes = Int64(value)
            case .seconds: seconds = Int64(value)
            case .tenths: tenths = Int64(value)
            default: break
            }
            // Overflow is arithmetic, not an error: typing 90 seconds means a
            // minute and a half.
            seek(toMicroseconds: ((minutes * 60 + seconds) * 10 + tenths) * 100_000)
            statusMessage = jumpedMessage
        }
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

    /// The A of A–B looping: marks the measure under the playhead as the
    /// loop's first measure. Capturing while listening is how every practice
    /// looper works — the owner hears the spot, they do not know its number.
    func captureLoopStart() {
        guard let measure = measureUnderPlayhead else { return }
        loopFromField = measure
        let to = loopToField.trimmingCharacters(in: .whitespaces)
        if to.isEmpty {
            statusMessage = "Loop will start at measure \(measure). Mark the end when you reach it."
        } else {
            setLoopFromFields()
        }
    }

    /// The B: marks the measure under the playhead as the loop's last measure
    /// and starts looping. With no start marked, the loop is this one measure.
    func captureLoopEnd() {
        guard let measure = measureUnderPlayhead else { return }
        loopToField = measure
        if loopFromField.trimmingCharacters(in: .whitespaces).isEmpty {
            loopFromField = measure
        }
        setLoopFromFields()
    }

    // MARK: Rehearsal marks (plan decisions 11–13)

    /// The piece's rehearsal marks in score order, as menu and loop choices.
    /// Empty before the piece is compiled and for a score that prints none,
    /// which is what disables Go to Rehearsal Mark.
    var rehearsalMarks: [RehearsalMarkTarget] { navigator?.rehearsalMarkTargets ?? [] }

    /// Seeks to the mark's first performance, like Go to Measure.
    func goToRehearsalMark(_ target: RehearsalMarkTarget) {
        guard let microseconds = navigator?.microseconds(forRehearsalMark: target.mark) else { return }
        seek(toMicroseconds: microseconds)
    }

    /// Starts the loop at the mark's measure. The loop fields carry printed
    /// numbers, so the loop then resolves exactly as a typed one would.
    func setLoopStart(atRehearsalMark target: RehearsalMarkTarget) {
        loopFromField = target.measureNumber
        if loopToField.trimmingCharacters(in: .whitespaces).isEmpty {
            statusMessage = "Loop will start at \(target.menuTitle). Choose where it ends."
        } else {
            setLoopFromFields()
        }
    }

    /// Ends the loop just before the mark, so "A to B" loops section A. With
    /// no start chosen, the loop runs from the beginning of the piece.
    func setLoopEnd(beforeRehearsalMark target: RehearsalMarkTarget) {
        guard let before = target.measureNumberBefore else {
            statusMessage = "\(target.text) is on the first measure; a loop cannot end before it."
            return
        }
        loopToField = before
        fillEmptyLoopStartWithFirstMeasure()
        setLoopFromFields()
    }

    /// Ends the loop at the last measure of the piece: the final section's end.
    func setLoopEndAtPieceEnd() {
        guard let last = navigator?.lastMeasureNumber else { return }
        loopToField = last
        fillEmptyLoopStartWithFirstMeasure()
        setLoopFromFields()
    }

    private func fillEmptyLoopStartWithFirstMeasure() {
        if loopFromField.trimmingCharacters(in: .whitespaces).isEmpty,
           let first = navigator?.firstMeasureNumber {
            loopFromField = first
        }
    }

    /// The printed number of the measure being played — or the last measure,
    /// for a playhead resting past the end.
    private var measureUnderPlayhead: String? {
        position?.measureNumber ?? navigator?.lastMeasureNumber
    }

    // MARK: Measure stepping

    /// One playback measure back or forward — the practice player's arrow
    /// keys. Stepping back from partway through a measure returns to that
    /// measure's own start first, the way track-skip returns to a track's
    /// start before jumping to the previous one.
    func stepMeasure(by delta: Int) {
        guard let navigator, navigator.playbackMeasureCount > 0 else { return }

        var index: Int
        if let position {
            index = position.playbackMeasureIndex
            if delta > 0 || position.beat < 1.5 { index += delta }
        } else {
            // Past the end of the piece: back lands on the last measure.
            index = delta < 0 ? navigator.playbackMeasureCount - 1 : 0
        }
        index = max(0, min(navigator.playbackMeasureCount - 1, index))

        guard let target = navigator.microseconds(atPlaybackMeasureIndex: index) else { return }
        seek(toMicroseconds: target)
        statusMessage = jumpedMessage
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

    // MARK: Performance settings (REQ-012 humanization, REQ-003 expression)

    /// Turns humanization on or off and re-realizes the piece under the new
    /// setting, keeping the playhead and whether it was playing.
    func setHumanizationEnabled(_ isEnabled: Bool) async {
        endCompare()
        await apply(HumanizationSettings(isEnabled: isEnabled, intensity: humanization.intensity))
    }

    /// Commits the slider. Called when the drag ends, not on every value.
    func commitIntensity() async {
        endCompare()
        let intensity = Int(intensityDraft.rounded())
        guard intensity != humanization.intensity else { return }
        await apply(HumanizationSettings(isEnabled: humanization.isEnabled, intensity: intensity))
    }

    private func apply(_ settings: HumanizationSettings) async {
        guard settings != humanization else { return }
        humanization = settings
        intensityDraft = Double(settings.intensity)

        // The setting is part of the preset (REQ-024), saved the way a mixer
        // move is: immediately, with a failure reported rather than discarded.
        // The setting still applies to this session either way.
        assignment.saveHumanization(settings)
        await reRealize(
            announcing: Self.humanizationMessage(settings), changing: "humanization"
        )
    }

    // MARK: Expression (REQ-003)

    /// Turns phrase expression on or off and re-realizes the piece under the
    /// new setting — the humanization control's behaviour exactly, because it
    /// is the same kind of setting: preset-stored, whole-piece, and carried by
    /// the one timeline live playback and the export both read (AD-P6).
    func setExpressionEnabled(_ isEnabled: Bool) async {
        endCompare()
        await apply(ExpressionSettings(isEnabled: isEnabled, amount: expression.amount))
    }

    /// Commits the slider. Called when the drag ends, not on every value.
    func commitExpressionAmount() async {
        endCompare()
        let amount = Int(expressionAmountDraft.rounded())
        guard amount != expression.amount else { return }
        await apply(ExpressionSettings(isEnabled: expression.isEnabled, amount: amount))
    }

    private func apply(_ settings: ExpressionSettings) async {
        guard settings != expression else { return }
        expression = settings
        expressionAmountDraft = Double(settings.amount)

        assignment.saveExpression(settings)
        await reRealize(announcing: Self.expressionMessage(settings), changing: "expression")
    }

    // MARK: The produced master (REQ-005)

    /// Turns bus cohesion and loudness calibration on or off together (D65-2
    /// option A), and saves the choice to the preset.
    ///
    /// **The one row in this group that does not re-realize the piece, and that
    /// is the point rather than an omission.** Humanization, expression and
    /// tempo all change the realized timeline, so they have to rebuild the
    /// program and carry the playhead across. This changes two numbers on the
    /// summed bus and nothing about the notes — so it lands on the next buffer
    /// with the playhead untouched and the music uninterrupted, the way a mixer
    /// move does. Everything else the group's rows share is unchanged: the
    /// change applies immediately, is written to the active preset immediately,
    /// and is announced through the status bar's live region.
    ///
    /// Turning it on measures the program if this program has not been measured
    /// yet, which is bounded by `MasterStage.maximumAnalyzedSeconds`.
    func setProducedMasterEnabled(_ isEnabled: Bool) async {
        endCompare()
        await apply(ProducedMasterSettings(isEnabled: isEnabled))
    }

    /// What the engine measured about the loaded program, or nil if it has not
    /// been measured. Read by the status message and by the wiring tests; the
    /// group's row itself needs only the switch.
    var masterCalibration: MasterCalibration? { engine.masterCalibration }

    private func apply(_ settings: ProducedMasterSettings) async {
        guard settings != producedMaster else { return }
        producedMaster = settings

        assignment.saveProducedMaster(settings)
        engine.producedMaster = settings
        statusMessage = Self.producedMasterMessage(
            settings, calibration: engine.masterCalibration
        )
    }

    // MARK: Tuning (REQ-006)

    /// Picks a temperament and plays the piece in it (REQ-006).
    func setTemperament(_ temperament: Temperament) async {
        endCompare()
        // `unrecognizedTemperament` is deliberately dropped: the owner choosing a
        // temperament is the one moment replacing a name this build could not read
        // is exactly what they asked for.
        await apply(
            TuningSettings(temperament: temperament, referencePitch: tuning.referencePitch)
        )
    }

    /// Picks what A is tuned to and plays the piece at it (REQ-006).
    func setReferencePitch(_ referencePitch: ReferencePitch) async {
        endCompare()
        await apply(
            TuningSettings(
                temperament: tuning.temperament,
                referencePitch: referencePitch,
                unrecognizedTemperament: tuning.unrecognizedTemperament
            )
        )
    }

    /// The tuning the engine's current program was actually built with, or nil
    /// before there is a program.
    ///
    /// Read by the wiring tests for the reason `masterCalibration` is: a setting
    /// that reached this model and not the program would leave every assertion
    /// about the model passing while the piece played at concert pitch.
    var loadedProgramTuning: TuningSettings? { engine.loadedProgram?.tuning }

    /// **The one row in this group that rebuilds the program without re-realizing
    /// the piece**, and the reason is worth stating because it is neither of the
    /// other two mechanisms.
    ///
    /// Humanization, expression and tempo change the *timeline* — which notes
    /// sound when, and how hard — so they re-realize and then reload. The produced
    /// master changes two numbers on the summed *bus*, so it needs neither. Tuning
    /// changes neither the timeline nor the bus: it changes the frequency a voice
    /// derives when a note starts, and a voice reads that when it is built. So the
    /// notes are untouched — the same realized timeline is reloaded verbatim — and
    /// the program is rebuilt around it. `PlaybackEngine.setTuning` carries the
    /// playhead and the mix across, exactly as a sound change does.
    ///
    /// **It therefore pays for a fresh loudness calibration** when the produced
    /// master is on — about 0.36 s on the pinned reference piece, synchronously on
    /// this actor, because a rebuild drops the measurement so the gain follows the
    /// program (P65-5). By design, and the same cost a tempo nudge already pays;
    /// worth knowing, because this control is two clicks rather than a drag.
    ///
    /// Everything else the group's rows share is kept: applied at once, written to
    /// the active preset at once, announced through the status bar's live region.
    private func apply(_ settings: TuningSettings) async {
        guard settings != tuning else { return }
        tuning = settings

        assignment.saveTuning(settings)

        guard timeline != nil else {
            statusMessage = Self.tuningMessage(settings)
            return
        }

        // Read before the change, for the reason `restorePlayback` gives: the
        // engine's own carry cannot survive the second rebuild that putting the
        // preset back costs.
        let wasPlaying = transportState == .playing
        let resumeAt = positionMicroseconds

        do {
            // No re-realization: the notes do not move, only what each one is
            // tuned to. The engine rebuilds the program around the same timeline.
            try engine.setTuning(settings)
            try restorePlayback(at: resumeAt, playing: wasPlaying)
            statusMessage = Self.tuningMessage(settings)
            refreshTransport()
        } catch {
            statusMessage = "Could not apply the tuning change: \(error)"
        }
    }

    /// Put the piece back together after something rebuilt the render program: the
    /// preset's sounds and mix, the playhead, and whether it was playing.
    ///
    /// **Why the position is held here rather than left to `PlaybackEngine`'s own
    /// carry, which exists and works.** Restoring the preset means re-seating the
    /// voices, and re-seating the voices is *a second rebuild*. The engine carries
    /// the playhead by re-issuing a seek, and a seek lands when the render thread
    /// applies it — so the second rebuild reads a playhead that is still at zero,
    /// carries zero, and starts the piece again from the top. This model is the only
    /// layer that knows the two rebuilds are one act, so this is where the position
    /// lives.
    ///
    /// Found by the smoke test rather than by a unit test, which is worth recording:
    /// every assertion about the engine in isolation was true.
    private func restorePlayback(at resumeAt: Int64, playing wasPlaying: Bool) throws {
        // A fresh program's strips start at unity, centred and unmuted, which would
        // silently throw the owner's mix away.
        assignment.programWasReloaded()
        seekEngine(to: resumeAt)
        if wasPlaying {
            try engine.start()
            engine.play()
        }
    }

    /// Realizes the piece again under whatever the performance settings now
    /// say, keeping the playhead and whether it was playing.
    ///
    /// Shared by the humanization and expression controls because the mechanism
    /// is identical and P65-6 adds more rows to this group later: every one of
    /// them changes a setting, re-renders, and saves. A second copy of this
    /// would be the place the next row forgot to restore the mix.
    private func reRealize(announcing message: String, changing what: String) async {
        guard let compiledScore else {
            statusMessage = message
            return
        }

        let wasPlaying = transportState == .playing
        // In ticks, read against the tempo actually playing: a tempo adoption
        // still being realized has already rescaled `compiledScore`.
        let ticks = playheadTicks()
        let percent = tempoPercent
        guard let realized = await realizeUnlessOvertaken(compiledScore) else { return }

        do {
            // `load` stops the graph; the position, the preset's sounds and the
            // mix are all carried across by hand — see `restorePlayback`.
            try loadIntoEngine(realized, tempoPercent: percent)
            try restorePlayback(
                at: compiledScore.tempoMap.microseconds(atPlaybackTicks: ticks),
                playing: wasPlaying
            )
            statusMessage = message
            refreshTransport()
        } catch {
            statusMessage = "Could not apply the \(what) change: \(error)"
        }
    }

    // MARK: Tempo (REQ-009)

    /// Commits the slider. Called when the drag ends, not on every value.
    func commitTempo() async {
        await setTempoPercent(Int(tempoDraft.rounded()))
    }

    func nudgeTempo(by delta: Int) async {
        await setTempoPercent(tempoPercent + delta)
    }

    func resetTempo() async {
        await setTempoPercent(TempoMap.defaultTempoPercent)
    }

    func setTempoPercent(_ percent: Int) async {
        endCompare()
        await applyTempo(PresetContent.clampedTempo(percent))
    }

    /// The tempo control's whole mechanism: rescale the clock, realize the
    /// same notes against it, reload, and put the playhead back on the same
    /// *beat* — not the same second, which would now be somewhere else.
    ///
    /// **Nothing about the sound changes.** The synthesizer renders the same
    /// events with the same envelopes and effects at different moments; no
    /// audio is stretched, so there is no artefact to speak of. The one cost
    /// is the same one humanization pays: loading a program stops the graph
    /// for an instant, which is why this runs on commit and not on every
    /// slider value.
    private func applyTempo(_ percent: Int) async {
        guard percent != tempoPercent else { return }
        tempoPercent = percent
        tempoDraft = Double(percent)

        assignment.saveTempoPercent(percent)

        guard let sourceScore, compiledScore != nil else {
            statusMessage = Self.tempoMessage(percent, score: nil)
            return
        }

        let wasPlaying = transportState == .playing
        // The same place in the music, found by score ticks, which the tempo
        // does not move.
        let ticks = playheadTicks()

        rescaleClock(to: percent, from: sourceScore)
        guard let rescaled = compiledScore,
              let realized = await realizeUnlessOvertaken(rescaled) else { return }

        do {
            try loadIntoEngine(realized, tempoPercent: percent)
            // The same place in the *music* rather than the same second, which the
            // rescaled clock has moved.
            try restorePlayback(
                at: rescaled.tempoMap.microseconds(atPlaybackTicks: ticks),
                playing: wasPlaying
            )
            statusMessage = Self.tempoMessage(percent, score: sourceScore)
            refreshTransport()
        } catch {
            statusMessage = "Could not apply the tempo change: \(error)"
        }
    }

    /// Where the playhead is in score ticks, which a tempo change does not move.
    ///
    /// Read against the tempo the *loaded timeline* was realized at, not
    /// `compiledScore`'s: while a tempo change is still being realized the two
    /// differ, and the engine is still playing the old one.
    private func playheadTicks() -> Int {
        guard let sourceScore else { return 0 }
        let playing = timelineTempoPercent == tempoPercent
            ? compiledScore : sourceScore.scalingTempo(toPercent: timelineTempoPercent)
        return playing?.tempoMap.playbackTicks(atMicroseconds: positionMicroseconds) ?? 0
    }

    /// Rescale the clock, and everything read from it, to `percent`.
    private func rescaleClock(to percent: Int, from sourceScore: CompiledScore) {
        let rescaled = sourceScore.scalingTempo(toPercent: percent)
        compiledScore = rescaled
        navigator = PlaybackNavigator(score: rescaled)
        if let loop, let navigator {
            // The loop is a pair of measures; its seconds have to be re-read.
            self.loop = navigator.loopRange(
                fromMeasureNumber: loop.startMeasureNumber, toMeasureNumber: loop.endMeasureNumber
            )
        }
    }

    // MARK: Adopting a loaded preset (#96)

    /// A loaded or switched preset brought its own performance settings: play
    /// under them, but do not write them back — they are already what the
    /// preset stores.
    ///
    /// **One ordered, cancellable unit, with one realization.** It used to be
    /// five unstored tasks, one per setting, each free to re-realize and each
    /// free to land in any order — so a second load arriving while the first's
    /// tasks were pending could interleave with them, and a stale value could
    /// land over a newer one. Now it is two halves:
    ///
    /// - **The settings, here and now**, in a fixed order — humanization,
    ///   expression, produced master, tuning, tempo — with no suspension between
    ///   them. Nothing can observe half a preset, and nothing can slip between
    ///   the load and its values landing. A newer load simply lands over this one.
    /// - **The engine, in one stored task**, which realizes once if any of the
    ///   three timeline settings moved (or else rebuilds only for tuning, or only
    ///   touches the bus for the master). A newer load cancels it, and a
    ///   cancelled task applies nothing further; the newer one reconciles the
    ///   engine with every setting now in force, including this one's.
    ///
    /// **An owner edit made meanwhile wins.** It lands on the model after these
    /// settings did, so it is never overwritten; and its own realization, or the
    /// adoption's if that starts later, reads every setting in force when it
    /// starts. Whichever realization started last is the one loaded —
    /// `realizationGeneration` drops the other — so the result carries both.
    private func adoptPreset(_ content: PresetContent) {
        var announcements: [AdoptionAnnouncement] = []

        if content.humanization != humanization {
            humanization = content.humanization
            intensityDraft = Double(content.humanization.intensity)
            announcements.append(.text(Self.humanizationMessage(content.humanization)))
        }
        if content.expression != expression {
            expression = content.expression
            expressionAmountDraft = Double(content.expression.amount)
            announcements.append(.text(Self.expressionMessage(content.expression)))
        }
        if content.producedMaster != producedMaster {
            producedMaster = content.producedMaster
            announcements.append(.producedMaster)
        }
        if content.tuning != tuning {
            tuning = content.tuning
            announcements.append(.text(Self.tuningMessage(content.tuning)))
        }
        let percent = PresetContent.clampedTempo(content.tempoPercent)
        if percent != tempoPercent {
            tempoPercent = percent
            tempoDraft = Double(percent)
            if let sourceScore { rescaleClock(to: percent, from: sourceScore) }
            announcements.append(.text(Self.tempoMessage(percent, score: sourceScore)))
        }

        // Nothing moved: the common case, since every open and refresh loads
        // the preset already in force. A pending adoption, if any, is left to
        // finish — it reconciles the engine with the settings in force when it
        // runs, and those are exactly this preset's.
        guard !announcements.isEmpty else { return }

        adoptionTask?.cancel()
        adoptionTask = Task { [weak self] in
            await self?.applyAdoptedPreset(announcing: announcements)
        }
    }

    /// The engine half of `adoptPreset`: bring the engine in line with every
    /// performance setting now in force, doing the least work that achieves it.
    private func applyAdoptedPreset(announcing announcements: [AdoptionAnnouncement]) async {
        guard !Task.isCancelled else { return }
        defer { if !Task.isCancelled { adoptionTask = nil } }

        // Composed when read, not when queued: the produced master's sentence
        // names the calibration, which exists only once the program is measured.
        var message: String {
            announcements.map { announcement in
                switch announcement {
                case .text(let text): return text
                case .producedMaster:
                    return Self.producedMasterMessage(
                        producedMaster, calibration: engine.masterCalibration
                    )
                }
            }.joined(separator: " ")
        }

        guard let timeline, let compiledScore else {
            statusMessage = message
            return
        }

        let wasPlaying = transportState == .playing
        // A realization in flight will replace the loaded timeline with one
        // realized under settings captured before this preset landed — an owner
        // edit this preset may have just put back. Realizing again overtakes it,
        // so what loads last is what the model now says.
        let needsRealization = realizationsInFlight > 0
            || timeline.settings.humanization != humanization
            || timeline.settings.expression != expression
            || timelineTempoPercent != tempoPercent

        do {
            if needsRealization {
                let ticks = playheadTicks()
                let percent = tempoPercent
                guard let realized = await realizeUnlessOvertaken(compiledScore),
                      !Task.isCancelled else { return }
                // Loading carries the produced master and the tuning with it.
                try loadIntoEngine(realized, tempoPercent: percent)
                try restorePlayback(
                    at: compiledScore.tempoMap.microseconds(atPlaybackTicks: ticks),
                    playing: wasPlaying
                )
            } else {
                if engine.producedMaster != producedMaster {
                    engine.producedMaster = producedMaster
                }
                if engine.loadedProgram?.tuning != tuning {
                    let resumeAt = positionMicroseconds
                    try engine.setTuning(tuning)
                    try restorePlayback(at: resumeAt, playing: wasPlaying)
                }
            }
            statusMessage = message
            refreshTransport()
        } catch {
            statusMessage = "Could not apply the preset's performance settings: \(error)"
        }
    }

    /// One sentence of what an adoption changed, in the fixed order it applied
    /// them.
    private enum AdoptionAnnouncement: Sendable {
        case text(String)
        /// Composed after the engine has the setting, for the calibration.
        case producedMaster
    }

    /// Waits for pending preset adoptions to finish — including one that
    /// replaced the awaited one meanwhile — or returns at once when none is
    /// pending. For tests, which need to observe the settled state.
    func settlePresetAdoption() async {
        while let task = adoptionTask {
            await task.value
            if adoptionTask == task { return }
        }
    }

    /// "Tempo 90% — ♩=120 becomes ♩=108." The marked tempo is the one in
    /// force at the start of the piece, which is what a listener would name.
    static func tempoMessage(_ percent: Int, score: CompiledScore?) -> String {
        guard percent != TempoMap.defaultTempoPercent else {
            return "Tempo back to the score's own."
        }
        guard let score else { return "Tempo \(percent)%." }
        let marked = 60_000_000.0 / Double(score.tempoMap.microsecondsPerQuarter(atPlaybackTicks: 0))
        let played = marked * Double(percent) / 100
        return "Tempo \(percent)% — ♩=\(Int(marked.rounded())) becomes ♩=\(Int(played.rounded()))."
    }

    private static func humanizationMessage(_ settings: HumanizationSettings) -> String {
        settings.isLiteral
            ? "Humanization off — playing exactly as written."
            : "Humanization on at \(settings.intensity)%."
    }

    /// Read aloud by the status bar's live region, which is how a change to
    /// this setting is announced.
    /// What the status bar says about the produced master, including the one
    /// thing the owner has to be told rather than left to notice: that the
    /// analysis could not run and the piece is therefore at its own level.
    static func producedMasterMessage(
        _ settings: ProducedMasterSettings,
        calibration: MasterCalibration?
    ) -> String {
        guard settings.isEnabled else {
            return "Produced master off — the mix is the lines as you set them, "
                + "under the clipping ceiling."
        }
        if let sentence = calibration?.statusSentence { return "Produced master on. " + sentence }
        if let calibration, case .silentProgram = calibration.outcome {
            return "Produced master on — this piece has nothing to measure, so its level "
                + "is unchanged."
        }
        guard let calibration else {
            return "Produced master on — levelled and held together."
        }
        return "Produced master on — levelled "
            + String(format: "%+.1f", calibration.appliedDecibels)
            + " dB and held together."
    }

    static func expressionMessage(_ settings: ExpressionSettings) -> String {
        settings.isNeutral
            ? "Expression off — phrases are played without shaping or breathing."
            : "Expression on at \(settings.amount)% — phrases shaped, cadences breathing."
    }

    /// What the status bar says about the tuning, including REQ-006's one thing
    /// the owner has to be told rather than left to notice: a stored temperament
    /// this build does not know, which plays as equal temperament.
    static func tuningMessage(_ settings: TuningSettings) -> String {
        if let failure = settings.failureSentence { return failure }
        let pitch = settings.referencePitch.displayName
        guard !settings.isDefault else {
            return "Tuning: equal temperament at \(pitch) — standard."
        }
        return "Tuning: \(settings.temperament.displayName) at \(pitch)."
    }

    // MARK: Compare with a reference preset (#92)

    /// The active preset's timing, kept while Compare plays the reference's.
    ///
    /// **Only the timing is swapped.** `humanization`, `expression`,
    /// `producedMaster`, `tuning` and `tempoPercent` go on holding the active
    /// preset's values throughout, because they are what the Performance
    /// controls show and edit, and what an edit writes. What the engine plays
    /// under Compare is the reference's; what the readout reads is
    /// `compiledScore` and `navigator`, which do follow the reference's tempo so
    /// the measure and beat shown are the ones being heard.
    private struct ActiveTiming {
        let score: CompiledScore
        let navigator: PlaybackNavigator
        let timeline: PerformanceTimeline
        let timelineTempoPercent: Int
        /// Whether the reference needed its own realization, so returning has
        /// to reload the active one.
        let reloadsTimeline: Bool
    }

    /// Non-nil exactly while Compare is on.
    private var compareReturn: ActiveTiming?

    /// Bumped by every end, so a Compare still realizing the reference when an
    /// edit, activation or export arrives does not land after it.
    private var compareGeneration = 0

    var isComparing: Bool { compareReturn != nil }

    private func wireCompare() {
        assignment.onCompareMustEnd = { [weak self] in self?.endCompare() }
        assignment.onToggleCompare = { [weak self] in
            Task { await self?.toggleCompare() }
        }
    }

    /// The latched toggle (plan decision 8): the menu command and the panel's
    /// Compare button both land here.
    func toggleCompare() async {
        if isComparing {
            endCompare()
        } else {
            await beginCompare()
        }
    }

    /// Play the reference preset in place of the active one, at the same place
    /// in the music.
    ///
    /// The reference's whole performance is applied — sounds, mix,
    /// humanization, expression, produced master, tuning and tempo — through
    /// one faded switch, so however many rebuilds that takes, sound resumes
    /// once. Nothing is activated and nothing is written.
    func beginCompare() async {
        guard isReady, !isComparing else { return }
        // A preset switch still being adopted, or an owner edit still being
        // realized, is about to replace the loaded timeline. Compare starts from
        // the settled state, never from one that is about to move under it.
        compareGeneration += 1
        let generation = compareGeneration
        await settlePresetAdoption()
        guard generation == compareGeneration, !isComparing else { return }
        guard realizationsInFlight == 0 else {
            statusMessage = "The piece is still being prepared — try Compare again in a moment."
            return
        }
        guard let sourceScore, let compiledScore, let navigator, let timeline else { return }
        guard let performance = assignment.referencePerformance() else {
            if let reason = assignment.compareUnavailableReason { statusMessage = reason }
            return
        }
        let content = performance.preset.content

        let percent = PresetContent.clampedTempo(content.tempoPercent)
        let reloadsTimeline = percent != tempoPercent
            || content.humanization != humanization
            || content.expression != expression
        let score = percent == tempoPercent
            ? compiledScore
            : sourceScore.scalingTempo(toPercent: percent)
        let realized: PerformanceTimeline
        if reloadsTimeline {
            realizationCount += 1
            realized = await Self.realize(
                score, humanization: content.humanization, expression: content.expression
            )
        } else {
            realized = timeline
        }

        // Anything that ended Compare while the reference was realizing — an
        // edit, a switch, an export, the piece closing — wins.
        guard generation == compareGeneration, !isComparing else { return }

        let back = ActiveTiming(
            score: compiledScore, navigator: navigator, timeline: timeline,
            timelineTempoPercent: timelineTempoPercent, reloadsTimeline: reloadsTimeline
        )
        compareReturn = back
        do {
            try switchPerformance(
                score: score,
                timeline: realized,
                timelineTempoPercent: percent,
                reloadsTimeline: reloadsTimeline,
                producedMaster: content.producedMaster,
                tuning: content.tuning
            ) {
                assignment.beginAudition(performance)
            }
            statusMessage = "Comparing: playing “\(performance.preset.name)” in place of "
                + "“\(assignment.activePreset?.name ?? "the active preset")”. "
                + "Nothing is changed or saved."
        } catch {
            endCompare()
            statusMessage = "Could not compare with “\(performance.preset.name)”: \(error)"
        }
    }

    /// Put the active preset back on the engine, at the same place in the
    /// music. Does nothing when Compare is off, apart from cancelling one that
    /// is still being prepared.
    func endCompare() {
        compareGeneration += 1
        guard let back = compareReturn else { return }
        compareReturn = nil
        do {
            try switchPerformance(
                score: back.score,
                timeline: back.timeline,
                timelineTempoPercent: back.timelineTempoPercent,
                reloadsTimeline: back.reloadsTimeline,
                producedMaster: producedMaster,
                tuning: tuning
            ) {
                assignment.endAudition()
            }
            statusMessage = "Back to “\(assignment.activePreset?.name ?? "the active preset")”."
        } catch {
            // Whatever the engine managed, the model is off Compare: the panel
            // and the next rebuild both describe the active preset.
            assignment.endAudition()
            statusMessage = "Could not return to the active preset: \(error)"
        }
    }

    /// The one switch both directions use: fade out, rebuild whatever differs,
    /// resume at the same score position, fade in (`PlaybackEngine.switchFaded`).
    ///
    /// **Position is carried in score ticks, not microseconds**, the way the
    /// tempo control carries it, so when the two presets' tempos differ the
    /// playhead lands on the same measure and beat (plan decision 10).
    private func switchPerformance(
        score: CompiledScore,
        timeline arriving: PerformanceTimeline,
        timelineTempoPercent arrivingTempoPercent: Int,
        reloadsTimeline: Bool,
        producedMaster: ProducedMasterSettings,
        tuning: TuningSettings,
        voices: () -> Void
    ) throws {
        let ticks = playheadTicks()
        let arrivingNavigator = PlaybackNavigator(score: score)
        let resumeAt = min(
            max(0, score.tempoMap.microseconds(atPlaybackTicks: ticks)),
            max(0, arrivingNavigator.totalMicroseconds)
        )

        try engine.switchFaded(resumingAtMicroseconds: resumeAt, producedMaster: producedMaster) {
            try engine.setTuning(tuning)
            if reloadsTimeline { try engine.load(timeline: arriving) }
            voices()
        }

        timeline = arriving
        timelineTempoPercent = arrivingTempoPercent
        compiledScore = score
        navigator = arrivingNavigator
        if let loop {
            // A loop is a pair of measures; its seconds follow the tempo.
            self.loop = arrivingNavigator.loopRange(
                fromMeasureNumber: loop.startMeasureNumber, toMeasureNumber: loop.endMeasureNumber
            )
        }
        positionMicroseconds = resumeAt
        refreshTransport()
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
            playheadJumpCount += 1
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
