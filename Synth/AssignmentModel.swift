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

    init(store: LibraryStore, engine: PlaybackEngine) {
        self.store = store
        self.engine = engine
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

    private func load(applyingToEngine: Bool, because verb: String?) {
        guard let score else { return }
        do {
            palette = try store.sounds.allSounds()
            let inventory = try store.lineInventory(for: score)
            self.inventory = inventory

            let preset = try store.presets.activePreset(for: inventory, palette: palette)
            let performance = try PresetPerformance.resolve(
                preset, inventory: inventory, library: store.sounds
            )

            presets = try store.presets.presets(forPieceID: score.pieceID)
            activePreset = preset
            lines = performance.lines
            keepSelectionValid()

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
        guard let resolved = performance ?? currentPerformance() else { return }
        do {
            // `PresetPerformance.apply(to:)` in two halves. The mixer half is
            // ASN001's, verbatim. The voice half is replaced by `voices(for:)`
            // below, which builds the same program out of live channels instead
            // of frozen patches so that editing an assigned sound is heard on
            // that line while the piece plays (REQ-018).
            try engine.setVoices(voices(for: resolved.lines))
            resolved.applyMixer(to: engine)
        } catch {
            alert = AssignmentAlert(title: "Could not put this preset on the audio engine", error)
        }
    }

    private func currentPerformance() -> PresetPerformance? {
        guard let activePreset else { return nil }
        return PresetPerformance(preset: activePreset, lines: lines)
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

    private func channelKey(for line: ResolvedLine) -> String {
        if case .library(let soundID, _) = line.source { return "sound:\(soundID)" }
        return "line:\(line.lineID.rawValue)"
    }

    /// The engine's voices for these lines, each on its sound's live channel.
    ///
    /// Channels are created on demand and refreshed here, so the program a
    /// rebuild produces always starts from what the store says — an unsaved
    /// edit published into a channel does not survive a rebuild, which is the
    /// right answer: the preset references the *library* sound.
    private func voices(for lines: [ResolvedLine]) -> LineVoiceAssignment {
        var byLine: [ScoreLineID: any LineVoiceProvider] = [:]
        var kept: [String: SynthPatchLiveVoices] = [:]
        for line in lines {
            let key = channelKey(for: line)
            let channel = channels[key] ?? SynthPatchLiveVoices(patch: line.patch)
            channel.apply(line.patch)
            kept[key] = channel
            byLine[line.lineID] = SynthPatchVoiceProvider(live: channel)
        }
        // Only the channels this preset still uses; a sound that is no longer
        // assigned anywhere should not keep a channel alive.
        channels = kept
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
            lines[index] = ResolvedLine(
                lineID: lines[index].lineID,
                name: lines[index].name,
                source: lines[index].source,
                patch: patch,
                mixer: lines[index].mixer
            )
        }
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
    }

    func beginRenameOfSelectedLine() {
        guard let selectedLineID else { return }
        beginLineRename(selectedLineID)
    }

    func cancelLineRename() {
        renamingLineID = nil
        lineNameDraft = ""
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
                preset, inventory: inventory, library: store.sounds
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
                .library(kind: .synth, soundID: soundID), toLine: lineID, in: preset
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
    func commitMixer(forLine lineID: ScoreLineID, describedAs what: String = "mix") {
        guard let preset = activePreset,
              let index = lines.firstIndex(where: { $0.lineID == lineID }) else { return }

        let wanted = lines[index].mixer
        let stored = preset.line(withID: lineID)?.mixer
        guard wanted != stored else { return }

        do {
            activePreset = try store.presets.setMixer(wanted, forLine: lineID, in: preset)
            presets = try store.presets.presets(forPieceID: preset.pieceID)
            statusMessage = "\(lines[index].name) — \(AssignmentDisplay.mixSummary(lines))"
        } catch {
            let persisted = stored ?? .neutral
            writeStrip(persisted, toLine: lineID)
            lines[index] = withMixer(persisted, on: lines[index])
            alert = AssignmentAlert(title: "Could not save the \(what) change", error)
        }
    }

    private func writeStrip(_ state: LineMixerState, toLine lineID: ScoreLineID) {
        guard !isSuspendedByPlayThrough, let strip = engine.mixer(for: lineID) else { return }
        strip.gain = Float(state.volume)
        strip.pan = Float(state.pan)
        strip.isMuted = state.isMuted
        strip.isSoloed = state.isSoloed
    }

    private func withMixer(_ mixer: LineMixerState, on line: ResolvedLine) -> ResolvedLine {
        ResolvedLine(
            lineID: line.lineID,
            name: line.name,
            source: line.source,
            patch: line.patch,
            mixer: mixer
        )
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
            beginPresetRename()
            statusMessage = "Made “\(created.name)” and switched to it."
        }
    }

    func beginPresetRename() {
        guard let preset = activePreset else { return }
        isRenamingPreset = true
        presetNameDraft = preset.name
    }

    func cancelPresetRename() {
        isRenamingPreset = false
        presetNameDraft = ""
    }

    func commitPresetRename() {
        guard let preset = activePreset else { return }
        let requested = presetNameDraft
        cancelPresetRename()
        guard requested.trimmingCharacters(in: .whitespacesAndNewlines) != preset.name else { return }

        write("rename “\(preset.name)”") { pieceID in
            let renamed = try store.presets.rename(preset, to: requested)
            activePreset = renamed
            presets = try store.presets.presets(forPieceID: pieceID)
            statusMessage = "Renamed “\(preset.name)” to “\(renamed.name)”."
        }
    }

    /// REQ-024's switch. Immediate and audible: the sounds and the whole mix of
    /// the preset being left are already on disk, so there is nothing to save
    /// first and nothing of it survives into the one arriving.
    func activate(presetID: String) {
        guard let target = presets.first(where: { $0.id == presetID }), !target.isActive else { return }
        write("switch to “\(target.name)”") { _ in
            activePreset = try store.presets.activate(target)
            reloadPresetAndApply()
            statusMessage = "Switched to “\(target.name)” — \(AssignmentDisplay.mixSummary(lines))."
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
            let successor = activePreset?.name ?? PresetLibrary.initialPresetName
            statusMessage = wasTheOnlyOne
                ? "Deleted “\(preset.name)”. A piece always has a preset, so “\(successor)” "
                    + "took its place."
                : "Deleted “\(preset.name)”. Now on “\(successor)”."
        }
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
                preset, inventory: inventory, library: store.sounds
            )
            presets = try store.presets.presets(forPieceID: score.pieceID)
            activePreset = preset
            lines = performance.lines
            keepSelectionValid()
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
    private func write(_ what: String, _ body: (String) throws -> Void) {
        guard let pieceID = score?.pieceID else { return }
        do {
            try body(pieceID)
        } catch {
            alert = AssignmentAlert(title: "Could not \(what)", error)
            load(applyingToEngine: false, because: nil)
        }
    }
}

extension ResolvedSoundSource {
    /// True when this line is a live reference to exactly this library sound.
    func isLibrarySound(_ soundID: String) -> Bool {
        if case .library(let id, _) = self { return id == soundID }
        return false
    }
}
