import Foundation
import Observation
import SynthKit

/// A failure the assignment surface has to put in front of the owner.
///
/// The same shape as `SoundAlert`, and for the same reason: `PresetError`
/// already writes a headline and a recovery line, and the UI never invents
/// wording for a failure the model layer has described.
struct AssignmentAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: String?

    init(title: String, _ error: Error) {
        self.title = title
        self.message = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        self.recovery = (error as? LocalizedError)?.recoverySuggestion
    }
}

/// A piece whose saved preset exists but could not be read (#95).
///
/// Distinct from a piece with no preset yet, which is ordinary and says
/// nothing: this one plays under the standard settings *instead of* what the
/// owner saved, and they are told so — once, in the panel's banner, not in a
/// modal alert that would stand between them and the music.
struct UnreadablePreset: Equatable {
    let pieceTitle: String
    let reason: String
    let recovery: String?

    init(pieceTitle: String, _ error: Error) {
        self.pieceTitle = pieceTitle
        self.reason = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        self.recovery = (error as? LocalizedError)?.recoverySuggestion
    }

    /// The panel's banner: the piece, what is playing instead, the promise that
    /// the stored preset is left alone, and the store's own account of why.
    var banner: String {
        "Synth could not read the saved preset for “\(pieceTitle)”, so it is playing under "
            + "the standard settings and will not save anything over it. \(reason)"
    }
}

/// The assignment, mixer and preset surface of the open piece (REQ-005,
/// REQ-006, REQ-008, REQ-024, REQ-027).
///
/// **Everything here is a read of ASN001's model and a write through it.** No
/// preset rule lives in this file: "exactly one sound per line" is structural in
/// `PresetLine`, "exactly one active preset" is a partial unique index, and
/// "auto-saved" is the absence of a save path. What this class owns is the
/// order the two collaborators are touched in, which is the one thing neither
/// of them can own:
///
/// * **A mixer move goes to the engine first and the store second.** The strip
///   setters are single atomic stores, so the change is audible on the next
///   buffer — that is what REQ-008's "effective immediately during playback"
///   means. Persisting first would put a SQLite transaction between the
///   owner's gesture and the sound. If the write then fails, the strip is put
///   back to what is actually stored, which is the issue's failure clause.
/// * **An assignment change and a preset switch go through
///   `PresetPerformance.apply(to:)`**, because a voice is allocated once per
///   line when the program is built. That rebuild carries the playhead and the
///   mix across (ASN001), so the music resumes where it was.
///
/// The panel renders `lines`, which is always the *resolved* preset — live
/// library references dereferenced, embedded copies used verbatim, a vanished
/// sound flagged. So a control never shows a value the engine is not playing.
@Observable
@MainActor
final class AssignmentModel {
    private let store: LibraryStore
    private let engine: PlaybackEngine

    // MARK: What the panel renders

    private(set) var inventory: LineInventory?

    /// Every preset of this piece, in list order.
    private(set) var presets: [Preset] = []

    /// The one that is active. Exactly one always is, once the piece is open.
    private(set) var activePreset: Preset?

    /// The active preset resolved against the sound library: one row per line.
    private(set) var lines: [ResolvedLine] = []

    /// The sound library, for the pickers. Re-read whenever the studio may
    /// have changed it.
    private(set) var palette: [SoundEntry] = []

    private(set) var statusMessage: String?

    var alert: AssignmentAlert?

    /// Set while this piece's active preset exists but cannot be read (#95).
    ///
    /// While it is set nothing is written for this piece: `activePreset` is nil,
    /// so every setter's `guard let preset = activePreset` refuses, and `load`
    /// never reaches `PresetLibrary.activePreset(for:palette:)`, whose create
    /// and reconcile paths are the ones that could write over the stored row.
    private(set) var unreadablePreset: UnreadablePreset?

    // MARK: What the owner is doing

    /// Which strip the menu commands act on. Always one of `lines` once the
    /// piece is open, because a keyboard-only owner with nothing selected has
    /// no target at all.
    var selectedLineID: ScoreLineID?

    private(set) var renamingLineID: ScoreLineID?
    var lineNameDraft = ""

    private(set) var isRenamingPreset = false
    var presetNameDraft = ""

    /// The preset a delete is waiting for confirmation on.
    private(set) var pendingPresetDeletion: Preset?

    /// Bumped so the panel can move keyboard focus onto the selected strip
    /// after a menu command moved the selection — the mechanism the piece
    /// library and the sound studio both use.
    private(set) var lineFocusRequests = 0

    /// True while the sound studio is routing the whole piece through the sound
    /// it is editing (SYN003's ⌥⌘P).
    ///
    /// The preset is untouched and the panel still shows it; what is suspended
    /// is only *applying* it to the engine, because the studio has deliberately
    /// taken every line over. Turning play-through off puts the preset back.
    private(set) var isSuspendedByPlayThrough = false

    private var score: CompiledScore?

    /// This piece's mix and preset history (UND001). The model's own record is
    /// the truth; the window's undo manager only *shows* it, and only while
    /// the playback screen is what the window shows (P84-7).
    @ObservationIgnored private var undoSteps: [UndoStep] = []
    @ObservationIgnored private var redoSteps: [UndoStep] = []
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var isApplyingHistory = false

    /// True while one of the transport's own text fields (measure, time, loop)
    /// has focus. Set by `PlaybackScreen`, which owns that focus.
    @ObservationIgnored private var isTransportFieldFocused = false

    /// The preset a rename draft was begun on. A commit renames this preset
    /// or nothing — never whichever preset happens to be active by then.
    private var renamingPresetID: String?

    /// Hands a loaded preset's performance settings — humanization, expression,
    /// produced master, tuning and tempo — to the transport, which owns
    /// realization and adopts them as one unit (#96). Installed by
    /// `PlaybackModel`. One signal rather than five, so the transport sees a
    /// preset arrive once and can apply it in one order with one realization.
    var onPresetLoaded: ((PresetContent) -> Void)?

    /// The piece's title, for the one message that has to name it.
    private let pieceTitle: String

    init(store: LibraryStore, engine: PlaybackEngine, pieceTitle: String) {
        self.store = store
        self.engine = engine
        self.pieceTitle = pieceTitle
    }

    // MARK: Derived state

    var isReady: Bool { !lines.isEmpty }

    var lineCount: Int { lines.count }

    var selectedLine: ResolvedLine? {
        guard let selectedLineID else { return nil }
        return lines.first { $0.lineID == selectedLineID }
    }

    func entry(for lineID: ScoreLineID) -> LineEntry? { inventory?.entry(withID: lineID) }

    var mixSummary: String { AssignmentDisplay.mixSummary(lines) }

    var autoSaveText: String { AssignmentDisplay.autoSaveText(activePreset) }

    var spokenPreset: String { AssignmentDisplay.spokenPreset(activePreset, of: presets.count) }

    /// The sounds the pickers offer, grouped the way the studio groups them.
    var paletteByCategory: [(category: SoundCategory, sounds: [SoundEntry])] {
        SoundCategory.allCases.compactMap { category in
            let members = palette.filter { $0.category == category }
            return members.isEmpty ? nil : (category, members)
        }
    }

    /// The same sounds flattened, in exactly the order the picker lists them,
    /// so stepping through with the keyboard visits them in the order the eye
    /// would.
    var orderedPalette: [SoundEntry] { paletteByCategory.flatMap(\.sounds) }

    // MARK: Opening the piece

    /// Reads the piece's lines and its active preset, and puts that preset on
    /// the engine.
    ///
    /// Called after the transport has loaded a program, because the mixer half
    /// addresses the lines of the program that is loaded.
    func open(score: CompiledScore) {
        self.score = score
        load(applyingToEngine: true, because: "opened")
    }

    /// The transport rebuilt its program — a humanization change re-realizes the
    /// piece and reloads it, which allocates fresh strips at unity. The preset
    /// has to go back on.
    func programWasReloaded() {
        guard score != nil, !isSuspendedByPlayThrough else { return }
        applyToEngine()
    }

    /// Re-read the store because something outside this screen may have changed
    /// it — a sound created, edited or deleted in the studio.
    ///
    /// **Rebuilds only when a line's *sound* changed, never when its patch did.**
    /// A rebuild is a brief stop and start of the graph; a patch reaches the
    /// running voices through the line's channel and needs none. So coming back
    /// from the studio having edited a sound the piece uses costs the music
    /// nothing at all, and coming back having changed nothing costs it nothing
    /// either.
    func refreshFromStore() {
        guard score != nil else { return }
        endCompare()
        let before = lines.map { LineSound(lineID: $0.lineID, key: channelKey(for: $0)) }
        load(applyingToEngine: false, because: nil)
        let after = lines.map { LineSound(lineID: $0.lineID, key: channelKey(for: $0)) }

        guard before == after else { return applyToEngine() }
        // Same sounds on the same lines: only their patches can have moved, and
        // `voices(for:)` republishes each channel from what the store now says.
        guard !isSuspendedByPlayThrough else { return }
        _ = voices(for: lines)
    }

    private struct LineSound: Equatable {
        let lineID: ScoreLineID
        let key: String
    }

    /// The piece's stored active preset, read without creating or repairing
    /// anything — nil when it has none yet *or* when it could not be read.
    ///
    /// The two nils are told apart in `unreadablePreset`, which this sets or
    /// clears on every call: "no preset yet" is the ordinary first open and says
    /// nothing, while "could not read it" is the owner's saved settings being
    /// ignored and is always said. The transport reads through here before its
    /// first realization, and `load` does before anything that could write, so
    /// the two agree about which case the piece is in.
    func readStoredActivePreset(forPieceID pieceID: String) -> Preset? {
        do {
            let preset = try store.presets.activePreset(forPieceID: pieceID)
            unreadablePreset = nil
            return preset
        } catch {
            unreadablePreset = UnreadablePreset(pieceTitle: pieceTitle, error)
            return nil
        }
    }

    /// The saved preset cannot be read: forget whatever this panel last showed,
    /// so no setter has a preset to write through, and hand the standard
    /// settings to the transport by the one path every preset's settings take
    /// (#96's `onPresetLoaded`). On a first open those are already in force and
    /// nothing moves; on a later re-read they replace a preset that has since
    /// become unreadable, so what plays is what the banner says is playing.
    ///
    /// **Everything that could still act on the old preset is dropped too** —
    /// the inventory `confirmPresetDeletion` needs, a deletion waiting for its
    /// confirmation (which would otherwise create a fresh preset and delete the
    /// unreadable one), and any rename in progress.
    ///
    /// **The engine's sounds and mix are left as they were**, deliberately. The
    /// standard *performance* settings are what the transport adopts; there is
    /// no "standard" sound per line short of the auto-mapping, which is exactly
    /// the preset write this path refuses, and swapping every line onto the one
    /// base voice mid-piece would be a louder surprise than the banner.
    private func showUnreadablePreset() {
        presets = []
        activePreset = nil
        inventory = nil
        lines = []
        pendingPresetDeletion = nil
        isRenamingPreset = false
        renamingLineID = nil
        keepSelectionValid()
        onPresetLoaded?(PresetContent(lines: []))
    }

    private func load(applyingToEngine: Bool, because verb: String?) {
        guard let score else { return }
        // Before anything that could write: `activePreset(for:palette:)` creates
        // a preset when it finds none, and would throw on this one anyway — but
        // "would throw" is not a guarantee this file should lean on for the
        // owner's saved settings.
        _ = readStoredActivePreset(forPieceID: score.pieceID)
        if unreadablePreset != nil { return showUnreadablePreset() }
        do {
            palette = try store.sounds.allSounds()
            let inventory = try store.lineInventory(for: score)
            self.inventory = inventory

            let preset = try store.presets.activePreset(for: inventory, palette: palette)
            let performance = try PresetPerformance.resolve(
                preset, inventory: inventory, library: store.sounds,
                instruments: store.instruments
            )

            presets = try store.presets.presets(forPieceID: score.pieceID)
            activePreset = preset
            dropRenameDraftUnlessOn(preset)
            lines = performance.lines
            keepSelectionValid()
            keepReferenceValid()
            onPresetLoaded?(preset.content)

            if applyingToEngine { applyToEngine(performance) }
            if let verb {
                statusMessage = "\(preset.name) \(verb) — \(AssignmentDisplay.mixSummary(lines))."
            }
        } catch {
            alert = AssignmentAlert(title: "Could not read this piece's presets", error)
        }
    }

    /// Puts the current preset — sounds and mixer — on the engine.
    private func applyToEngine(_ performance: PresetPerformance? = nil) {
        guard !isSuspendedByPlayThrough else { return }
        guard let resolved = performance ?? audition ?? currentPerformance() else { return }
        do {
            // `PresetPerformance.apply(to:)` in two halves. The mixer half is
            // ASN001's, verbatim. The voice half is replaced by `voices(for:)`
            // below, which builds the same program out of live channels instead
            // of frozen patches so that editing an assigned sound is heard on
            // that line while the piece plays (REQ-018).
            let assignment = voices(for: resolved.lines)
            try engine.setVoices(assignment)
            resolved.applyMixer(to: engine)
            // `lines` is the active preset's; an audition's silent lines are
            // not flagged onto it.
            if audition == nil { flagSilentLines() }
        } catch {
            alert = AssignmentAlert(title: "Could not put this preset on the audio engine", error)
        }
    }

    /// Flag any line whose voice could not be built, so it is not silently
    /// silent (issue #24, carried forward from INS002).
    ///
    /// **Read here, immediately after the program is built, and nowhere else.**
    /// By the time `setVoices` has returned, every voice the program needs has
    /// been through `makeVoice`, so every allocation failure has already been
    /// recorded — no polling, no timer, and nothing on the audio thread. INS002
    /// chose silence over a substitute sound when `sample_voice_create` cannot
    /// allocate, precisely because an unasked-for substitute is the state this
    /// leaf gates; a line that is quietly *silent* would be the same violation
    /// by the other route, which is why this reads the count and says so.
    private func flagSilentLines() {
        guard let program = engine.loadedProgram else { return }
        let silent = LineRenderHealth.silentLines(in: program, resolvedAs: lines)
        guard !silent.isEmpty else { return }

        for report in silent {
            guard let index = lines.firstIndex(where: { $0.lineID == report.lineID }) else {
                continue
            }
            lines[index] = lines[index].adding(advice: report.advice)
        }

        let names = silent.map(\.soundName).joined(separator: ", ")
        statusMessage = silent.count == 1
            ? "\(names) could not be given a voice, so that line is playing silence."
            : "\(names) could not be given voices, so those lines are playing silence."
    }

    private func currentPerformance() -> PresetPerformance? {
        guard let activePreset else { return nil }
        return PresetPerformance(preset: activePreset, lines: lines)
    }

    // MARK: Export (REQ-026)

    /// This piece's active preset, frozen, as an offline render's input.
    ///
    /// **The same `PresetPerformance` the engine is playing right now**, read
    /// on the main actor and turned into values. So an export renders the
    /// sounds this panel is showing, through the same per-line decision
    /// `ResolvedLine.voiceProvider` makes for live playback, with the same
    /// mixer on it.
    ///
    /// The one deliberate difference is `live: nil` inside
    /// `PresetPerformance.exportRequest`: a live channel renders whatever the
    /// sound editor currently holds, and an export renders what the library
    /// stores. An unsaved knob position is REQ-018's audition, not the piece.
    ///
    /// Nil before the preset has resolved, which the export reports as "this
    /// piece has nothing to export yet" rather than writing an empty file.
    func exportRequest(
        timeline: PerformanceTimeline, settings: AudioExportSettings
    ) -> AudioExportRequest? {
        guard let performance = currentPerformance(), !lines.isEmpty else { return nil }
        return performance.exportRequest(
            timeline: timeline,
            settings: settings,
            instruments: store.sampledInstruments
        )
    }

    /// What the export sheet has to warn about, or nil when what is playing is
    /// what will be written.
    ///
    /// One case: the sound studio has taken every line over (SYN003's ⌥⌘P), so
    /// live playback is the sound under edit while an export is still of the
    /// preset. Saying nothing here would make the export sound wrong to an
    /// owner who is, at that moment, listening to something else.
    var exportCaveat: String? {
        guard isSuspendedByPlayThrough else { return nil }
        return "The sound studio is playing this piece through the sound being edited. "
            + "The export renders the preset’s own sounds."
    }

    // MARK: Live sounds (REQ-018)

    /// One publication channel per *sound*, not per line.
    ///
    /// **This is what makes REQ-018 true of an assigned line.**
    /// `PresetPerformance.voiceAssignment` hands the engine a frozen
    /// `SynthPatch`, which is right for an offline render and wrong for a piece
    /// that is playing while its sound is being designed: an edit would not be
    /// heard until the program was rebuilt, and rebuilding stops the graph.
    /// A `SynthPatchLiveVoices` renders whatever it currently holds, so
    /// publishing into it reaches the voices that are already sounding —
    /// SYN003's mechanism, per sound rather than for the whole piece.
    ///
    /// Keyed by sound, so two lines sharing a sound move together (which is
    /// what "the preset holds a live reference to that sound" means), and an
    /// embedded copy or a missing reference gets a private channel of its own,
    /// because neither can ever be edited again.
    private var channels: [String: SynthPatchLiveVoices] = [:]

    /// The same idea for a sampled instrument: one channel per *variant*, so
    /// moving a tone control reaches every line playing that variant and no
    /// other line.
    private var instrumentChannels: [String: SampledInstrumentLiveVoices] = [:]

    private func channelKey(for line: ResolvedLine) -> String {
        if let soundID = line.source.soundID, case .library = line.source {
            return "sound:\(soundID)"
        }
        return "line:\(line.lineID.rawValue)"
    }

    /// The engine's voices for these lines, each on its sound's live channel.
    ///
    /// Channels are created on demand and refreshed here, so the program a
    /// rebuild produces always starts from what the store says — an unsaved
    /// edit published into a channel does not survive a rebuild, which is the
    /// right answer: the preset references the *library* sound.
    ///
    /// **The decision about what a line actually plays is not made here.**
    /// `ResolvedLine.voiceProvider` makes it, once, so live playback and an
    /// offline render cannot disagree about whether a missing instrument goes
    /// quiet or gets substituted. This only supplies the two things that
    /// decision needs from the app: the shared instrument cache, and the live
    /// channel a sound's edits are published through.
    private func voices(for lines: [ResolvedLine]) -> LineVoiceAssignment {
        var kept: [String: SynthPatchLiveVoices] = [:]
        var keptInstruments: [String: SampledInstrumentLiveVoices] = [:]

        for line in lines {
            let key = channelKey(for: line)
            switch line.content {
            case .synth(let patch):
                let channel = channels[key] ?? SynthPatchLiveVoices(patch: patch)
                channel.apply(patch)
                kept[key] = channel
            case .instrument(let variant):
                let channel = instrumentChannels[key]
                    ?? SampledInstrumentLiveVoices(customization: variant.customization)
                channel.apply(variant.customization)
                keptInstruments[key] = channel
            }
        }
        // Only the channels this preset still uses; a sound that is no longer
        // assigned anywhere should not keep a channel alive.
        channels = kept
        instrumentChannels = keptInstruments

        var byLine: [ScoreLineID: any LineVoiceProvider] = [:]
        for line in lines {
            let key = channelKey(for: line)
            switch line.content {
            case .synth:
                // A synth line still goes through its channel rather than
                // through `ResolvedLine.voiceProvider`'s frozen patch, because
                // that is what makes an edit audible without a rebuild
                // (REQ-018). The line's own decision is unaffected: a synth
                // sound has no missing-asset case to decide about.
                guard let channel = channels[key] else { continue }
                byLine[line.lineID] = SynthPatchVoiceProvider(live: channel)
            case .instrument:
                byLine[line.lineID] = line.voiceProvider(
                    instruments: store.sampledInstruments,
                    live: { [instrumentChannels] soundID in instrumentChannels["sound:\(soundID)"] }
                )
            }
        }
        return LineVoiceAssignment(providersByLine: byLine)
    }

    /// The sound studio moved a knob on `soundID`. Every line that plays it
    /// hears the change on the next block, and no other line does.
    ///
    /// No rebuild, so the music does not stop — which is the whole of REQ-018's
    /// "edited live during piece playback" now that a piece has more than one
    /// sound in it.
    func publishEditedSound(id soundID: String, patch: SynthPatch) {
        guard !isSuspendedByPlayThrough,
              let channel = channels["sound:\(soundID)"] else { return }
        let result = channel.apply(patch)
        guard result.reachedAnyVoice else { return }
        // Kept in step so a later refresh can tell a patch edit (no rebuild
        // needed) from a change of which sound a line plays (rebuild needed).
        for index in lines.indices where channelKey(for: lines[index]) == "sound:\(soundID)" {
            lines[index] = lines[index].replacing(content: .synth(patch))
        }
    }

    /// The instrument editor moved a control on the variant `soundID`. Every
    /// line that plays it hears the change on the next block, and no other line
    /// does.
    ///
    /// The instrument half of the same requirement, through the same shape:
    /// a publish into the running voices rather than a rebuild, so a tone
    /// control moved during a passage is heard on the notes already sounding.
    func publishEditedVariant(id soundID: String, variant: InstrumentVariant) {
        guard !isSuspendedByPlayThrough,
              let channel = instrumentChannels["sound:\(soundID)"] else { return }

        // The audio and the panel are two separate questions here, and the
        // patch path's single `reachedAnyVoice` guard answers only the first.
        //
        // A synth line always has a voice to reach, so the two questions have
        // the same answer for it. An instrument line does not: a line whose
        // instrument is not downloaded is deliberately silent and has no voice
        // registered at all. Gating the panel on the audio would then leave the
        // strip showing the *old* tone of a variant the owner is editing in
        // front of them — a stale value on a line that is not playing anything
        // the new one could contradict.
        channel.apply(variant.customization)
        for index in lines.indices where channelKey(for: lines[index]) == "sound:\(soundID)" {
            lines[index] = lines[index].replacing(content: .instrument(variant))
        }
    }

    /// A rename draft belongs to the preset it was begun on; once another
    /// preset is active — a switch, an undo, a delete — the draft is dropped
    /// rather than committed onto the wrong one.
    private func dropRenameDraftUnlessOn(_ preset: Preset) {
        guard isRenamingPreset, renamingPresetID != preset.id else { return }
        cancelPresetRename()
    }

    private func keepSelectionValid() {
        if let selectedLineID, lines.contains(where: { $0.lineID == selectedLineID }) { return }
        selectedLineID = lines.first?.lineID
    }

    // MARK: Play-through (SYN003)

    /// The studio took every line over, or gave them back.
    ///
    /// Giving them back re-applies the preset, which is what makes ⌥⌘P
    /// symmetrical now that a piece has assigned sounds to return to.
    func setSuspendedByPlayThrough(_ isSuspended: Bool) {
        guard isSuspended != isSuspendedByPlayThrough else { return }
        isSuspendedByPlayThrough = isSuspended
        if isSuspended {
            statusMessage = "The sound studio is playing every line through the sound it is editing."
        } else {
            applyToEngine()
            statusMessage = "Back on this preset's own sounds."
        }
    }

    // MARK: Naming a line (REQ-005)

    func beginLineRename(_ lineID: ScoreLineID) {
        guard let entry = entry(for: lineID) else { return }
        selectedLineID = lineID
        renamingLineID = lineID
        lineNameDraft = entry.name
        resyncUndoManager()
    }

    func beginRenameOfSelectedLine() {
        guard let selectedLineID else { return }
        beginLineRename(selectedLineID)
    }

    func cancelLineRename() {
        renamingLineID = nil
        lineNameDraft = ""
        resyncUndoManager()
    }

    func commitLineRename() {
        guard let lineID = renamingLineID, let entry = entry(for: lineID) else { return }
        let requested = lineNameDraft
        cancelLineRename()
        guard requested.trimmingCharacters(in: .whitespacesAndNewlines) != entry.name else { return }

        write("rename “\(entry.name)”") { pieceID in
            let renamed = try store.presets.renameLine(entry, inPieceID: pieceID, to: requested)
            reloadNames()
            statusMessage = "Renamed “\(entry.name)” to “\(renamed.name)”."
        }
    }

    /// Puts a renamed line back to the name the score implies. A delete rather
    /// than a write of the current default, so a later improvement to the name
    /// deriver still reaches it — ASN001's rule, surfaced.
    func resetName(ofLine lineID: ScoreLineID) {
        guard let entry = entry(for: lineID), entry.isRenamed else { return }
        write("rename “\(entry.name)”") { pieceID in
            let reset = try store.presets.resetLineName(entry, inPieceID: pieceID)
            reloadNames()
            statusMessage = "“\(entry.name)” is called “\(reset.name)” again."
        }
    }

    /// A rename changes names and nothing else, so the engine is not touched:
    /// no rebuild, no interruption to the music.
    private func reloadNames() {
        guard let score, let preset = activePreset else { return }
        do {
            let inventory = try store.lineInventory(for: score)
            self.inventory = inventory
            lines = try PresetPerformance.resolve(
                preset, inventory: inventory, library: store.sounds,
                instruments: store.instruments
            ).lines
        } catch {
            alert = AssignmentAlert(title: "Could not re-read this piece's line names", error)
        }
    }

    // MARK: Assigning a sound (REQ-006)

    func assign(soundID: String, toLine lineID: ScoreLineID) {
        guard let preset = activePreset,
              let sound = palette.first(where: { $0.id == soundID }),
              let line = lines.first(where: { $0.lineID == lineID }) else { return }
        guard !line.source.isLibrarySound(soundID) else { return }

        write("give “\(line.name)” the sound “\(sound.name)”") { _ in
            activePreset = try store.presets.assign(
                .library(kind: sound.kind, soundID: soundID), toLine: lineID, in: preset
            )
            reloadPresetAndApply()
            statusMessage = "“\(line.name)” now plays “\(sound.name)”."
        }
    }

    /// Steps the selected line through the sound library.
    ///
    /// The picker beside the line is the ordinary way to choose a sound. This
    /// is the keyboard's way, and it exists for the reason the sound studio's
    /// Select Next Sound does: arrow keys move *inside* a control that already
    /// has focus, and opening a pop-up menu is not something a keyboard-only
    /// owner can be assumed to be able to do (REQ-027).
    func cycleSoundOnSelectedLine(by offset: Int) {
        guard let line = selectedLine else { return }
        let ordered = orderedPalette
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { line.source.isLibrarySound($0.id) }
        let index = current.map { ($0 + offset + ordered.count) % ordered.count } ?? 0
        assign(soundID: ordered[index].id, toLine: line.lineID)
    }

    // MARK: Missing instruments (issue #24)

    /// Every line the owner has something to be told about.
    var flaggedLines: [ResolvedLine] { lines.filter { !$0.advice.isEmpty } }

    /// Every line that is currently producing no sound at all.
    var silentLines: [ResolvedLine] { lines.filter(\.isSilent) }

    /// One sentence for the panel's own banner, or nil when nothing is wrong.
    var instrumentBanner: String? {
        let silent = silentLines
        guard !silent.isEmpty else { return nil }
        let names = silent.map(\.name).joined(separator: ", ")
        return silent.count == 1
            ? "\(names) is silent — its instrument is not available. See the note on that line."
            : "\(silent.count) lines are silent because their instruments are not available "
                + "(\(names))."
    }

    /// The owner has read the flag and asked to hear something on this line
    /// while its instrument is missing (issue #24's explicit acknowledgment).
    ///
    /// **The only path to a substituted line.** Nothing infers this, no default
    /// grants it, and it is recorded in the preset so the answer survives a
    /// relaunch. Until it is pressed the line renders silence, which is the
    /// whole point: a piece that quietly plays a synth patch where a cello was
    /// assigned is the state this leaf exists to prevent.
    func acceptSubstitution(forLine lineID: ScoreLineID) {
        guard let preset = activePreset,
              let line = lines.first(where: { $0.lineID == lineID }),
              let substitute = line.substitute else { return }

        write("play a substitute on “\(line.name)”") { _ in
            activePreset = try store.presets.setAcceptsSubstitution(
                true, forLine: lineID, in: preset
            )
            reloadPresetAndApply()
            statusMessage = "“\(line.name)” is playing “\(substitute.name)” until "
                + "“\(line.source.displayName)” is available."
        }
    }

    /// Take the substitute back off: the line returns to silence and its flag.
    func withdrawSubstitution(forLine lineID: ScoreLineID) {
        guard let preset = activePreset,
              let line = lines.first(where: { $0.lineID == lineID }) else { return }

        write("stop the substitute on “\(line.name)”") { _ in
            activePreset = try store.presets.setAcceptsSubstitution(
                false, forLine: lineID, in: preset
            )
            reloadPresetAndApply()
            statusMessage = "“\(line.name)” is silent again until "
                + "“\(line.source.displayName)” is available."
        }
    }

    /// The Mix menu's version, acting on whichever line is selected.
    func toggleSubstitutionOnSelectedLine() {
        guard let line = selectedLine else { return }
        if line.acceptsSubstitution {
            withdrawSubstitution(forLine: line.lineID)
        } else if line.canOfferSubstitution {
            acceptSubstitution(forLine: line.lineID)
        }
    }

    // MARK: The mixer (REQ-008)

    /// A slider being dragged: heard now, written when the drag ends.
    ///
    /// The split exists because the two halves have different right answers.
    /// The *engine* must hear every intermediate value — that is REQ-008. The
    /// *store* must not: a drag across a fader is a hundred values, and a
    /// hundred SQLite transactions between one gesture is work nobody asked for
    /// and a hundred revisions nobody wants. The humanization slider made the
    /// same split for the same reason.
    func previewVolume(_ volume: Double, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.volume = clampedVolume(volume) }
    }

    func previewPan(_ pan: Double, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.pan = min(max(pan, -1), 1) }
    }

    func setVolume(_ volume: Double, forLine lineID: ScoreLineID) {
        previewVolume(volume, forLine: lineID)
        commitMixer(forLine: lineID, describedAs: "volume")
    }

    func setPan(_ pan: Double, forLine lineID: ScoreLineID) {
        previewPan(pan, forLine: lineID)
        commitMixer(forLine: lineID, describedAs: "pan")
    }

    /// D7's per-line room send, on the same preview-then-commit split as volume
    /// and pan: every intermediate value is heard, only the last one is written.
    func previewRoomSend(_ send: Double, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.roomSend = min(max(send, 0), 1) }
    }

    func setRoomSend(_ send: Double, forLine lineID: ScoreLineID) {
        previewRoomSend(send, forLine: lineID)
        commitMixer(forLine: lineID, describedAs: "room send")
    }

    func previewDepth(_ depth: Double, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.depth = min(1, max(0, depth)) }
    }

    func setDepth(_ depth: Double, forLine lineID: ScoreLineID) {
        previewDepth(depth, forLine: lineID)
        commitMixer(forLine: lineID, describedAs: "depth")
    }

    func nudgeDepthOnSelectedLine(by delta: Double) {
        guard let line = selectedLine else { return }
        setDepth(line.mixer.depth + delta, forLine: line.lineID)
    }

    func nudgeRoomSendOnSelectedLine(by delta: Double) {
        guard let line = selectedLine else { return }
        setRoomSend(line.mixer.roomSend + delta, forLine: line.lineID)
    }

    func setMuted(_ isMuted: Bool, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.isMuted = isMuted }
        commitMixer(forLine: lineID, describedAs: "mute")
    }

    func setSoloed(_ isSoloed: Bool, forLine lineID: ScoreLineID) {
        preview(ofLine: lineID) { $0.isSoloed = isSoloed }
        commitMixer(forLine: lineID, describedAs: "solo")
    }

    func toggleMuteOnSelectedLine() {
        guard let line = selectedLine else { return }
        setMuted(!line.mixer.isMuted, forLine: line.lineID)
    }

    func toggleSoloOnSelectedLine() {
        guard let line = selectedLine else { return }
        setSoloed(!line.mixer.isSoloed, forLine: line.lineID)
    }

    func nudgeVolumeOnSelectedLine(byDecibels delta: Double) {
        guard let line = selectedLine else { return }
        let current = AssignmentDisplay.decibels(forVolume: line.mixer.volume)
        setVolume(
            AssignmentDisplay.volume(forDecibels: current + delta), forLine: line.lineID
        )
    }

    func nudgePanOnSelectedLine(by delta: Double) {
        guard let line = selectedLine else { return }
        setPan(line.mixer.pan + delta, forLine: line.lineID)
    }

    func centrePanOnSelectedLine() {
        guard let line = selectedLine else { return }
        setPan(0, forLine: line.lineID)
    }

    private func clampedVolume(_ volume: Double) -> Double {
        min(max(volume, 0), LineMixerState.maximumVolume)
    }

    /// **The engine first, the store second.**
    ///
    /// The strip setters are single atomic stores that land on the next buffer,
    /// so the owner hears the move as they make it. Persisting first would put a
    /// transaction between the gesture and the sound, and REQ-008 asks for the
    /// opposite.
    private func preview(
        ofLine lineID: ScoreLineID, _ change: (inout LineMixerState) -> Void
    ) {
        guard let index = lines.firstIndex(where: { $0.lineID == lineID }) else { return }
        var updated = lines[index].mixer
        change(&updated)
        guard updated != lines[index].mixer else { return }
        endCompare()

        writeStrip(updated, toLine: lineID)
        lines[index] = withMixer(updated, on: lines[index])
    }

    /// Writes whatever the strip currently shows into the preset.
    ///
    /// `activePreset` always holds what is on disk, so the two only diverge
    /// while a drag is in flight — and comparing them is how this knows whether
    /// there is anything to write. A write that fails puts the strip *and* the
    /// row back to the persisted value, so the control never shows a number the
    /// library does not hold. `PresetLibrary` guarantees the store is untouched
    /// on a throw, so that value is still correct.
    ///
    /// A write that lands is one undo step (UND001): the preview/commit split
    /// already makes a whole drag one commit, so a drag is one step for free.
    /// Returns false only when a write was attempted and failed.
    @discardableResult
    func commitMixer(forLine lineID: ScoreLineID, describedAs what: String = "mix") -> Bool {
        guard let preset = activePreset,
              let index = lines.firstIndex(where: { $0.lineID == lineID }) else { return true }

        let wanted = lines[index].mixer
        let stored = preset.line(withID: lineID)?.mixer
        guard wanted != stored else { return true }
        endCompare()

        do {
            activePreset = try store.presets.setMixer(wanted, forLine: lineID, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
            statusMessage = "\(lines[index].name) — \(AssignmentDisplay.mixSummary(lines))"
            recordUndo(
                .mixer(
                    presetID: preset.id, lineID: lineID,
                    before: stored ?? .neutral, after: wanted, what: what
                ),
                named: "\(what.capitalized) Change"
            )
            return true
        } catch {
            let persisted = stored ?? .neutral
            writeStrip(persisted, toLine: lineID)
            lines[index] = withMixer(persisted, on: lines[index])
            alert = AssignmentAlert(title: "Could not save the \(what) change", error)
            return false
        }
    }

    /// Stores the whole-piece tempo on the active preset. Auto-saved.
    func saveTempoPercent(_ percent: Int) {
        guard let preset = activePreset, preset.content.tempoPercent != percent else { return }
        endCompare()
        do {
            activePreset = try store.presets.setTempoPercent(percent, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not save the tempo change", error)
        }
    }

    /// Stores the whole-piece phrase expression on the active preset, like any
    /// other custom value the preset holds (REQ-024). Auto-saved.
    func saveExpression(_ settings: ExpressionSettings) {
        guard let preset = activePreset, preset.content.expression != settings else { return }
        endCompare()
        do {
            activePreset = try store.presets.setExpression(settings, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not save the expression change", error)
        }
    }

    /// Stores the whole-piece produced master on the active preset, like any
    /// other custom value the preset holds (REQ-024). Auto-saved.
    func saveProducedMaster(_ settings: ProducedMasterSettings) {
        guard let preset = activePreset, preset.content.producedMaster != settings else { return }
        endCompare()
        do {
            activePreset = try store.presets.setProducedMaster(settings, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not save the produced master change", error)
        }
    }

    /// Stores the whole-piece tuning on the active preset, like any other custom
    /// value the preset holds (REQ-024, REQ-006). Auto-saved.
    func saveTuning(_ settings: TuningSettings) {
        guard let preset = activePreset, preset.content.tuning != settings else { return }
        endCompare()
        do {
            activePreset = try store.presets.setTuning(settings, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not save the tuning change", error)
        }
    }

    /// Stores the whole-piece humanization on the active preset, like any
    /// other custom value the preset holds (REQ-024). Auto-saved.
    func saveHumanization(_ settings: HumanizationSettings) {
        guard let preset = activePreset, preset.content.humanization != settings else { return }
        endCompare()
        do {
            activePreset = try store.presets.setHumanization(settings, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not save the humanization change", error)
        }
    }

    /// What the engine's strip for a line holds right now — the audible half
    /// of the mixer, read by the app tests to prove an undo reached the ear.
    func engineStrip(for lineID: ScoreLineID) -> PlaybackEngine.LineMixer? {
        engine.mixer(for: lineID)
    }

    private func writeStrip(_ state: LineMixerState, toLine lineID: ScoreLineID) {
        guard !isSuspendedByPlayThrough, let strip = engine.mixer(for: lineID) else { return }
        strip.gain = Float(state.volume)
        strip.pan = Float(state.pan)
        strip.isMuted = state.isMuted
        strip.isSoloed = state.isSoloed
        strip.roomSend = Float(state.roomSend)
        strip.depth = Float(state.depth)
    }

    private func withMixer(_ mixer: LineMixerState, on line: ResolvedLine) -> ResolvedLine {
        line.replacing(mixer: mixer)
    }

    // MARK: Presets (REQ-024)

    /// A new preset that starts as a copy of the one showing, and becomes
    /// active immediately.
    ///
    /// A copy rather than a fresh auto-mapping, because the owner presses New
    /// Preset in the middle of a mix they like and wants a variation of it. The
    /// auto-mapping is what a piece with *no* preset gets, and ASN001 owns that.
    func createPreset() {
        guard let preset = activePreset else { return }
        write("make a new preset") { _ in
            let created = try store.presets.duplicate(preset, makeActive: true)
            activePreset = created
            reloadPresetAndApply()
            clearUndoHistory()
            beginPresetRename()
            statusMessage = "Made “\(created.name)” and switched to it."
        }
    }

    /// A new preset that plays the piece the way *Switched-On Bach* would
    /// have: every line whose part the score names gets the Baroque Modular
    /// sound built for that instrument, and the mix carries over untouched.
    ///
    /// By part name only, never by guessing — `SwitchedOnAssignment` says
    /// which words map where. A piece whose score names no instrument the
    /// table knows gets no preset and a status line saying why, because a
    /// preset identical to the one showing is not something the owner asked
    /// for.
    func createSwitchedOnPreset() {
        guard let preset = activePreset, let inventory else { return }
        let plan = SwitchedOnAssignment.plan(from: preset.content, inventory: inventory)
        guard plan.assignedCount > 0 else {
            statusMessage = plan.unnamedCount == inventory.entries.count
                ? "No Switched-On preset made: the score names no instruments, so there is "
                    + "nothing to go on."
                : "No Switched-On preset made: none of the score's instrument names is in the "
                    + "Switched-On table."
            return
        }
        write("make a Switched-On preset") { pieceID in
            let name = SwitchedOnAssignment.presetName(existing: presets.map(\.name))
            let created = try store.presets.create(
                named: name, forPieceID: pieceID, content: plan.content, makeActive: true
            )
            activePreset = created
            reloadPresetAndApply()
            clearUndoHistory()
            statusMessage = plan.summary(named: created.name)
        }
    }

    func beginPresetRename() {
        guard let preset = activePreset else { return }
        isRenamingPreset = true
        renamingPresetID = preset.id
        presetNameDraft = preset.name
        resyncUndoManager()
    }

    func cancelPresetRename() {
        isRenamingPreset = false
        renamingPresetID = nil
        presetNameDraft = ""
        resyncUndoManager()
    }

    func commitPresetRename() {
        let beganOn = renamingPresetID
        let requested = presetNameDraft
        cancelPresetRename()
        guard let preset = activePreset, preset.id == beganOn else { return }
        guard requested.trimmingCharacters(in: .whitespacesAndNewlines) != preset.name else { return }
        renamePreset(preset, to: requested)
    }

    /// The one path a preset rename takes, whether the owner typed it or an
    /// undo is putting a name back. A drafted name registers nothing; only a
    /// rename that reaches the store is a step.
    @discardableResult
    private func renamePreset(_ preset: Preset, to requested: String) -> Bool {
        write("rename “\(preset.name)”") { pieceID in
            let renamed = try store.presets.rename(preset, to: requested)
            activePreset = renamed
            presets = try store.presets.presets(forPieceID: pieceID)
            statusMessage = "Renamed “\(preset.name)” to “\(renamed.name)”."
            recordUndo(
                .presetName(presetID: preset.id, before: preset.name, after: renamed.name),
                named: "Preset Rename"
            )
        }
    }

    /// REQ-024's switch. Immediate and audible: the sounds and the whole mix of
    /// the preset being left are already on disk, so there is nothing to save
    /// first and nothing of it survives into the one arriving.
    ///
    /// A switch is itself an undo step, which is what keeps every older mixer
    /// step pointed at the right preset: unwinding in order re-activates the
    /// preset those steps changed before any of them is applied (P84-6).
    @discardableResult
    func activate(presetID: String) -> Bool {
        guard let target = presets.first(where: { $0.id == presetID }), !target.isActive else {
            return true
        }
        let previousID = activePreset?.id
        return write("switch to “\(target.name)”") { _ in
            activePreset = try store.presets.activate(target)
            reloadPresetAndApply()
            statusMessage = "Switched to “\(target.name)” — \(AssignmentDisplay.mixSummary(lines))."
            if let previousID {
                recordUndo(.activePreset(before: previousID, after: target.id), named: "Preset Switch")
            }
        }
    }

    func activateNextPreset() {
        guard presets.count > 1, let active = activePreset,
              let index = presets.firstIndex(where: { $0.id == active.id }) else { return }
        activate(presetID: presets[(index + 1) % presets.count].id)
    }

    func requestPresetDeletion() {
        guard let preset = activePreset else { return }
        pendingPresetDeletion = preset
    }

    func cancelPresetDeletion() { pendingPresetDeletion = nil }

    /// Deleting the last preset does not leave the piece preset-less: a fresh
    /// one is auto-mapped first and made active, and only then does the old one
    /// go. ASN001 refuses to delete the only preset precisely so that this
    /// decision is made here, in the open, rather than by the store.
    func confirmPresetDeletion(of preset: Preset) {
        pendingPresetDeletion = nil
        guard let inventory else { return }

        let wasTheOnlyOne = presets.count <= 1
        write("delete “\(preset.name)”") { pieceID in
            if wasTheOnlyOne {
                _ = try store.presets.create(
                    named: PresetLibrary.initialPresetName,
                    forPieceID: pieceID,
                    content: try PresetAutoAssignment.initialContent(
                        for: inventory, palette: palette
                    ),
                    makeActive: true
                )
            }
            try store.presets.delete(preset)
            reloadPresetAndApply()
            clearUndoHistory()
            let successor = activePreset?.name ?? PresetLibrary.initialPresetName
            statusMessage = wasTheOnlyOne
                ? "Deleted “\(preset.name)”. A piece always has a preset, so “\(successor)” "
                    + "took its place."
                : "Deleted “\(preset.name)”. Now on “\(successor)”."
        }
    }

    // MARK: Compare with a reference preset (#92)

    /// The preset Compare plays in place of the active one. Session state for
    /// this open piece only — never stored (plan decision 9) — so a new piece,
    /// which gets a new model, starts with none.
    private(set) var referencePresetID: String?

    /// The reference's resolved performance while Compare is on, nil otherwise.
    ///
    /// **A second performance beside the active one, never instead of it.**
    /// `activePreset` and `lines` go on describing what is stored and what the
    /// panel edits; only the engine hears this. Compare never calls
    /// `PresetLibrary.activate` and never writes a preset.
    private(set) var audition: PresetPerformance?

    var isComparing: Bool { audition != nil }

    var referencePreset: Preset? {
        referencePresetID.flatMap { id in presets.first { $0.id == id } }
    }

    /// Compare needs a reference that exists and is not the active preset, and
    /// the piece's own sounds on the lines (not the studio's play-through).
    var canCompare: Bool {
        guard let reference = referencePreset else { return false }
        return reference.id != activePreset?.id && !isSuspendedByPlayThrough
    }

    /// Why Compare cannot start, for the status line; nil when it can.
    var compareUnavailableReason: String? {
        guard let reference = referencePreset else {
            return "Choose a reference preset to compare with first."
        }
        if reference.id == activePreset?.id {
            return "“\(reference.name)” is the active preset — choose another one to compare with."
        }
        if isSuspendedByPlayThrough {
            return "Compare is unavailable while the sound studio is playing the piece."
        }
        return nil
    }

    /// Installed by `PlaybackModel`: puts the active preset back on the engine
    /// if Compare is on. Called before any preset edit, activation or re-read,
    /// so a change always lands on — and is heard as — the active preset.
    var onCompareMustEnd: (() -> Void)?

    /// Installed by `PlaybackModel`, which owns the timeline half of the switch;
    /// the panel's Compare toggle calls it.
    var onToggleCompare: (() -> Void)?

    func toggleCompare() { onToggleCompare?() }

    /// Pick the reference, or clear it with nil. Ends Compare if it is on, so
    /// what is heard is never a reference nobody chose.
    func chooseReference(presetID: String?) {
        guard presetID != referencePresetID else { return }
        endCompare()
        referencePresetID = presetID.flatMap { id in presets.contains { $0.id == id } ? id : nil }
    }

    /// The reference, resolved against this piece's lines and ready to play,
    /// or nil when Compare is unavailable. Reads only.
    func referencePerformance() -> PresetPerformance? {
        guard canCompare, let reference = referencePreset, let inventory else { return nil }
        do {
            return try PresetPerformance.resolve(
                reference, inventory: inventory, library: store.sounds,
                instruments: store.instruments
            )
        } catch {
            alert = AssignmentAlert(title: "Could not read the reference preset", error)
            return nil
        }
    }

    /// Put `performance` — sounds and mix — on the engine in place of the
    /// active preset. The caller has already paused and will resume.
    func beginAudition(_ performance: PresetPerformance) {
        audition = performance
        applyToEngine(performance)
    }

    /// Put the active preset back on the engine.
    func endAudition() {
        guard audition != nil else { return }
        audition = nil
        applyToEngine()
    }

    private func endCompare() {
        onCompareMustEnd?()
    }

    /// A deleted reference is forgotten, so Compare cannot come back to it.
    private func keepReferenceValid() {
        guard let id = referencePresetID, !presets.contains(where: { $0.id == id }) else { return }
        referencePresetID = nil
    }

    // MARK: Keyboard navigation (REQ-027)

    func selectNextLine() { moveSelection(by: 1) }
    func selectPreviousLine() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !lines.isEmpty else { return }
        guard let selectedLineID,
              let index = lines.firstIndex(where: { $0.lineID == selectedLineID }) else {
            self.selectedLineID = lines.first?.lineID
            lineFocusRequests += 1
            return
        }
        let next = min(max(index + offset, 0), lines.count - 1)
        self.selectedLineID = lines[next].lineID
        lineFocusRequests += 1
        statusMessage = AssignmentDisplay.spokenStrip(lines[next])
    }

    // MARK: Internals

    /// Re-reads the active preset, re-resolves it, and puts it on the engine.
    ///
    /// Used by every change that alters *which sound* a line plays — an
    /// assignment, a switch, a delete — because those are the changes that need
    /// the program rebuilt.
    private func reloadPresetAndApply() {
        guard let score else { return }
        do {
            let inventory = try store.lineInventory(for: score)
            self.inventory = inventory
            let preset = try store.presets.activePreset(for: inventory, palette: palette)
            let performance = try PresetPerformance.resolve(
                preset, inventory: inventory, library: store.sounds,
                instruments: store.instruments
            )
            presets = try store.presets.presets(forPieceID: score.pieceID)
            activePreset = preset
            dropRenameDraftUnlessOn(preset)
            lines = performance.lines
            keepSelectionValid()
            keepReferenceValid()
            onPresetLoaded?(preset.content)
            applyToEngine(performance)
        } catch {
            alert = AssignmentAlert(title: "Could not re-read this piece's presets", error)
        }
    }

    /// Every write, in one shape: do it against the piece, and turn a failure
    /// into an alert that names what was being attempted.
    ///
    /// `PresetLibrary` guarantees the store is untouched when a write throws, so
    /// there is nothing to undo here — only something to say, and a re-read so
    /// the panel shows what is really stored.
    @discardableResult
    private func write(_ what: String, _ body: (String) throws -> Void) -> Bool {
        guard let pieceID = score?.pieceID else { return false }
        endCompare()
        do {
            try body(pieceID)
            return true
        } catch {
            alert = AssignmentAlert(title: "Could not \(what)", error)
            load(applyingToEngine: false, because: nil)
            return false
        }
    }
}

// MARK: - Undo and redo (UND001, #89)

/// One committed change the owner can take back.
///
/// Each records the preset (and line) it changed, so it can only ever be
/// applied there (P84-6), and both sides of the change, so undo and redo are
/// the same write in opposite directions.
struct UndoStep: Equatable {
    enum Change: Equatable {
        case mixer(
            presetID: String, lineID: ScoreLineID,
            before: LineMixerState, after: LineMixerState, what: String
        )
        case presetName(presetID: String, before: String, after: String)
        case activePreset(before: String, after: String)
    }

    let id = UUID()
    let change: Change
    let actionName: String
}

/// Why a step was refused rather than applied somewhere else.
private struct UndoTargetGone: LocalizedError {
    var errorDescription: String? { "The preset this change was made to is no longer there." }
    var recoverySuggestion: String? { "Undo history for this piece has been cleared." }
}

extension AssignmentModel {
    /// A text field on the playback screen has focus, or has let it go.
    func setTransportFieldFocused(_ isFocused: Bool) {
        guard isFocused != isTransportFieldFocused else { return }
        isTransportFieldFocused = isFocused
        resyncUndoManager()
    }

    /// True while any playback-screen text field is being edited: a preset or
    /// line rename, or a transport field.
    ///
    /// **While it is, the window's manager holds none of the mix.** The field
    /// editor records typing on that same manager, so once the owner has
    /// undone their typing the next ⌘Z would otherwise fall through to the mix
    /// — "undo in a focused text field undoes text, not the mix" (#89).
    private var isEditingText: Bool {
        isTransportFieldFocused || isRenamingPreset || renamingLineID != nil
    }

    /// The manager the mix steps are on right now: the window's, unless text
    /// is being edited.
    private var offeredManager: UndoManager? { isEditingText ? nil : undoManager }

    /// Makes the window's manager hold exactly the model's record, or nothing
    /// while text is being edited. From inside the manager's own undo, where
    /// removing actions does not take, this waits until that undo returns.
    private func resyncUndoManager() {
        guard let manager = undoManager else { return }
        guard !manager.isUndoing, !manager.isRedoing else {
            DispatchQueue.main.async { [weak self, weak manager] in
                MainActor.assumeIsolated {
                    guard let self, let manager, manager === self.undoManager else { return }
                    self.resyncUndoManager()
                }
            }
            return
        }
        manager.removeAllActions(withTarget: self)
        if !isEditingText { mirrorHistory(onto: manager) }
    }

    /// The playback screen is now what the window shows: put this piece's
    /// history on the window's undo manager, so the Edit menu's Undo and Redo
    /// offer it (with "Undo Volume Change" and the like) and ⌘Z / ⇧⌘Z reach it.
    ///
    /// **Rebuilt from the model's own record every time**, because the history
    /// has to survive a trip into the sound studio and back while the window's
    /// manager must not carry it there.
    func attachUndoManager(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        detachUndoManager()
        guard let manager else { return }
        undoManager = manager
        resyncUndoManager()
    }

    /// The playback screen is no longer showing — the studio or the catalog
    /// covers it, or the piece closed. Takes every step off the window's
    /// manager so ⌘Z there can never change a mix the owner cannot see; the
    /// model keeps the history for when the screen comes back.
    func detachUndoManager() {
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    /// Preset creation and deletion change which presets exist, so no older
    /// step is allowed to survive them (P84-2).
    func clearUndoHistory() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        resyncUndoManager()
    }

    private func recordUndo(_ change: UndoStep.Change, named name: String) {
        guard !isApplyingHistory else { return }
        let step = UndoStep(change: change, actionName: name)
        undoSteps.append(step)
        redoSteps.removeAll()
        if let manager = offeredManager { register(step, on: manager) { $0.performUndo(step) } }
    }

    private func performUndo(_ step: UndoStep) {
        // Defensive: the manager holds no mix step while text is edited.
        guard !isEditingText else { return resyncUndoManager() }
        guard undoSteps.last == step else { return clearUndoHistory() }
        undoSteps.removeLast()
        guard apply(step.change, undoing: true) else { return clearUndoHistory() }
        redoSteps.append(step)
        if let manager = offeredManager { register(step, on: manager) { $0.performRedo(step) } }
    }

    private func performRedo(_ step: UndoStep) {
        guard !isEditingText else { return resyncUndoManager() }
        guard redoSteps.last == step else { return clearUndoHistory() }
        redoSteps.removeLast()
        guard apply(step.change, undoing: false) else { return clearUndoHistory() }
        undoSteps.append(step)
        if let manager = offeredManager { register(step, on: manager) { $0.performUndo(step) } }
    }

    /// **Through the same setters the controls use** — engine first, store
    /// second, the existing alert on failure — so there is one write path and
    /// the strip, the row and the saved preset cannot disagree.
    private func apply(_ change: UndoStep.Change, undoing: Bool) -> Bool {
        isApplyingHistory = true
        defer { isApplyingHistory = false }

        switch change {
        case let .mixer(presetID, lineID, before, after, what):
            guard activePreset?.id == presetID,
                  lines.contains(where: { $0.lineID == lineID }) else { return targetGone() }
            let target = undoing ? before : after
            preview(ofLine: lineID) { $0 = target }
            selectedLineID = lineID
            return commitMixer(forLine: lineID, describedAs: what)

        case let .presetName(presetID, before, after):
            guard let preset = activePreset, preset.id == presetID else { return targetGone() }
            return renamePreset(preset, to: undoing ? before : after)

        case let .activePreset(before, after):
            let id = undoing ? before : after
            guard presets.contains(where: { $0.id == id }) else { return targetGone() }
            return activate(presetID: id)
        }
    }

    private func targetGone() -> Bool {
        alert = AssignmentAlert(title: "Could not undo that change", UndoTargetGone())
        return false
    }

    /// One closed undo group per step, so two steps registered in the same
    /// event (a rebuild, a test) stay two steps.
    ///
    /// `groupsByEvent` is off for the instant the group is open because with it
    /// on, `beginUndoGrouping` at level 0 first opens the event's own group and
    /// nests inside it — and every step of that event would then undo as one.
    /// Inside an undo or redo the manager has its own group open and the step
    /// simply joins it; so does a step made while some other group is open.
    private func register(
        _ step: UndoStep, on manager: UndoManager,
        _ handler: @escaping @MainActor (AssignmentModel) -> Void
    ) {
        let standalone = manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        let groupsByEvent = manager.groupsByEvent
        if standalone {
            manager.groupsByEvent = false
            manager.beginUndoGrouping()
        }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { handler(model) }
        }
        manager.setActionName(step.actionName)
        if standalone {
            manager.endUndoGrouping()
            manager.groupsByEvent = groupsByEvent
        }
    }

    /// Puts the model's record back on a manager that has none of it.
    ///
    /// The undo side is ordinary registration, oldest first. The redo side
    /// cannot be registered directly, so each redo step is registered as a
    /// placeholder undo and then undone: undoing a placeholder does nothing but
    /// register the real redo action, which is exactly how a manager's redo
    /// stack is built. Nothing is applied to the mix.
    private func mirrorHistory(onto manager: UndoManager) {
        for step in undoSteps {
            register(step, on: manager) { $0.performUndo(step) }
        }
        guard !redoSteps.isEmpty else { return }
        guard manager.groupingLevel == 0 else {
            // Mid-event with a group open: undoing now would take that group
            // with it. Rare (a screen change and an edit in the same event),
            // and dropping redo is the safe loss.
            redoSteps.removeAll()
            return
        }
        for step in redoSteps.reversed() {
            register(step, on: manager) { model in
                guard let manager = model.undoManager else { return }
                model.register(step, on: manager) { $0.performRedo(step) }
            }
        }
        for _ in redoSteps { manager.undo() }
    }
}

extension ResolvedSoundSource {
    /// True when this line is a live reference to exactly this library sound.
    func isLibrarySound(_ soundID: String) -> Bool {
        if case .library(let id, _) = self { return id == soundID }
        return false
    }
}
