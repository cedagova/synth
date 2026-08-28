import Foundation
import Observation
import SynthKit

/// The sound under edit: its working patch, its audition, and its way back to
/// the library.
///
/// **Three things happen every time a knob moves**, and the order matters:
///
/// 1. the working patch changes, which is the only place an unsaved edit lives;
/// 2. it is published to the audition channel, so the next block of audio uses
///    it — including a note the owner is still holding down; and
/// 3. if the owner has asked for it, it is published to the *playback* channel
///    too, which is what makes an open piece play through the sound being
///    edited (REQ-018's in-increment form).
///
/// Nothing is written to the library on the way. A sound is saved when the
/// owner says so, and until then the stored version is exactly what it was —
/// which is what makes Revert an honest button rather than a second edit.
///
/// **A shipped sound is never the working sound.** REQ-017 says editing one
/// produces a copy, and the way that is enforced here is that the editor
/// refuses to become editable at all until a copy exists: a shipped sound loads
/// read-only, every control is disabled, and the one thing the panel offers is
/// "Duplicate to Edit". The alternative — let the owner edit and prompt at save
/// time — means an owner can spend ten minutes on something the library was
/// always going to refuse.
@Observable
@MainActor
final class SoundEditorModel {
    /// The library row being edited, or nil when nothing is open.
    private(set) var entry: SoundEntry?

    /// The sound as it currently is, including unsaved changes.
    private(set) var patch: SynthPatch = .defaultVoice

    /// The sound as the library last stored it. What Revert goes back to, and
    /// what `hasUnsavedChanges` compares against.
    private(set) var savedPatch: SynthPatch = .defaultVoice

    /// The channel the audition renders through. One per app; the editor
    /// publishes to it and `SoundAuditionEngine` renders from it.
    let auditionChannel: SynthPatchLiveVoices

    /// The channel the open piece's playback renders through.
    ///
    /// Held even when play-through is off, because turning it off has to put
    /// the ordinary voice back without rebuilding the program — which is the
    /// same mechanism as turning it on.
    private let playbackChannel: SynthPatchLiveVoices

    private let audition: SoundAuditionEngine
    private let library: SoundLibrary

    /// Called with the stored entry after a successful save.
    var onSaved: ((SoundEntry) -> Void)?

    /// Told when play-through starts and stops, so the transport can hand its
    /// lines over and take them back.
    ///
    /// A closure rather than a reference to the transport, so the studio still
    /// knows nothing about what else the window can show.
    var onPlayThroughChanged: ((Bool) -> Void)?

    /// Told, with the sound's identity, every time the working patch changes —
    /// so every line of the open piece that is assigned *this* sound hears it
    /// while the piece plays (REQ-018), and no other line does.
    var onPatchEdited: ((String, SynthPatch) -> Void)?

    /// Whether an open piece should play through the sound being edited.
    ///
    /// **Every line, deliberately, and now explicitly an override.** Before
    /// increment 004 there was nothing else it could be: the piece had one
    /// sound. Now the piece has a sound per line, and this suspends all of them
    /// so an edit is audible in real music without choosing which line to
    /// sacrifice. Turning it off restores the preset exactly.
    private(set) var isPlayingPieceThroughSound = false

    /// True while the owner is holding a key on the on-screen keyboard.
    private(set) var soundingNotes: Set<Int> = []

    /// Set when the audition could not start. The editor still edits — the
    /// patch is the patch whether or not a speaker exists — and says so.
    private(set) var auditionFailure: String?

    /// The last thing that happened, for the editor's own status line.
    private(set) var statusMessage: String?

    var alert: SoundAlert?

    /// Which panels are open. All of them, to begin with: a synthesizer's front
    /// panel does not hide the filter behind a disclosure, and D6's "fixed but
    /// rich" only reads as rich if the owner can see what there is.
    var collapsedGroups: Set<String> = []

    init(store: LibraryStore, playbackChannel: SynthPatchLiveVoices) {
        self.library = store.sounds
        self.playbackChannel = playbackChannel
        self.auditionChannel = SynthPatchLiveVoices(patch: .defaultVoice)
        self.audition = SoundAuditionEngine(live: auditionChannel)
    }

    // MARK: Derived state

    var isOpen: Bool { entry != nil }

    /// A shipped sound is shown, never edited (REQ-017).
    var isEditable: Bool { entry?.isEditable == true }
    var isShipped: Bool { entry?.origin == .shipped }

    var hasUnsavedChanges: Bool { isEditable && patch != savedPatch }

    var title: String { entry?.name ?? "No sound selected" }

    /// "Pads · your sound · revision 4", or "Keys · one of Synth's own sounds".
    var subtitle: String {
        guard let entry else { return "Choose a sound from the list, or create one." }
        var parts = [entry.category.displayName]
        switch entry.origin {
        case .shipped:
            parts.append("one of Synth's own sounds")
        case .user:
            parts.append("your sound")
            parts.append("revision \(entry.revision)")
        }
        if let origin = entry.shippedOriginID,
           let based = try? library.sound(withID: origin) {
            parts.append("based on “\(based.name)”")
        }
        return parts.joined(separator: " · ")
    }

    /// Shipped entries have no store row and therefore no timestamps —
    /// `SoundEntry` documents this as an empty string rather than an optional.
    /// Anything that shows a date has to branch on origin, so this is the one
    /// place that does.
    var lastSavedDescription: String? {
        guard let entry, entry.origin == .user, !entry.updatedAt.isEmpty else { return nil }
        return "Last saved \(Self.readableTimestamp(entry.updatedAt))"
    }

    /// "2026-08-28T09:39:18Z" as "2026-08-28 09:39 UTC".
    ///
    /// Sliced rather than formatted. The store writes ISO 8601 in UTC and
    /// nothing here should turn that into a locale's idea of a date: the same
    /// string has to mean the same instant to whoever reads it, and a
    /// `DateFormatter` would make the app's own evidence depend on where the
    /// machine thinks it is. Anything that is not the expected shape is shown
    /// exactly as stored rather than mangled.
    static func readableTimestamp(_ stored: String) -> String {
        guard stored.count >= 16, stored.hasSuffix("Z") else { return stored }
        let date = stored.prefix(10)
        let time = stored.dropFirst(11).prefix(5)
        guard stored[stored.index(stored.startIndex, offsetBy: 10)] == "T" else { return stored }
        return "\(date) \(time) UTC"
    }

    var isAuditionRunning: Bool { audition.isRunning }

    // MARK: Opening and closing

    func load(_ entry: SoundEntry) {
        // A key held on the previous sound must not be left held on the next.
        releaseEverything()
        // …and an unsaved edit to the previous sound must not be left in the
        // piece: the preset references the *library* sound, so walking away
        // from the editor puts the piece back on what the library holds.
        restoreStoredPatch(of: self.entry)

        self.entry = entry
        self.patch = entry.patch
        self.savedPatch = entry.patch
        self.statusMessage = nil

        auditionChannel.apply(entry.patch)
        if isPlayingPieceThroughSound { playbackChannel.apply(entry.patch) }
        startAuditionIfNeeded()
    }

    /// The row was renamed or re-filed. The patch did not change, so nothing is
    /// published and nothing becomes dirty; only the heading moves.
    func adoptRenamed(_ entry: SoundEntry) {
        guard self.entry?.id == entry.id else { return }
        self.entry = entry
        self.savedPatch = entry.patch
        if patch.name != entry.name {
            patch.name = entry.name
            patch.identifier = entry.id
        }
    }

    func close() {
        releaseEverything()
        restoreStoredPatch(of: entry)
        stopPlayingPieceThroughSound()
        entry = nil
        statusMessage = nil
    }

    /// Called when the studio screen goes away. Stops the hardware; the patch
    /// and the library are untouched.
    func suspend() {
        releaseEverything()
        audition.stop()
    }

    // MARK: Editing

    /// Set one parameter. The one path every control uses.
    func setValue(_ value: SynthParameterValue, for id: SynthParameterID) {
        guard isEditable else { return }
        let updated = patch.setting(id, to: value)
        guard updated != patch else { return }
        patch = updated
        publishWorkingPatch()
    }

    func value(for id: SynthParameterID) -> SynthParameterValue? {
        patch.value(for: id)
    }

    /// Put everything back to the stored sound.
    func revert() {
        guard let entry, isEditable else { return }
        patch = savedPatch
        publishWorkingPatch()
        statusMessage = "Reverted “\(entry.name)” to the saved version."
    }

    /// Write the working patch back to the library.
    ///
    /// The row's name and identity win over whatever the patch says about
    /// itself — that is `SoundLibrary.update`'s contract, not something this
    /// re-decides — so a save is a save and never an accidental rename.
    func save() {
        guard let entry, isEditable else { return }
        guard hasUnsavedChanges else { return }
        do {
            let stored = try library.update(entry, patch: patch)
            self.entry = stored
            self.savedPatch = stored.patch
            self.patch = stored.patch
            publishWorkingPatch()
            statusMessage = "Saved “\(stored.name)”."
            onSaved?(stored)
        } catch {
            alert = SoundAlert(title: "Could not save “\(entry.name)”", error)
        }
    }

    /// REQ-017: editing a shipped sound produces a copy, and the original stays
    /// exactly as it is.
    ///
    /// Returns the copy so the studio can select it. The shipped entry is not a
    /// row in anyone's store, so there is nothing this could have changed even
    /// if it wanted to.
    @discardableResult
    func duplicateForEditing() -> SoundEntry? {
        guard let entry else { return nil }
        do {
            let copy = try library.makeEditableCopy(of: entry)
            statusMessage = "“\(entry.name)” is one of Synth's own sounds, so this is your "
                + "copy of it: “\(copy.name)”. The original is unchanged."
            return copy
        } catch {
            alert = SoundAlert(title: "Could not copy “\(entry.name)”", error)
            return nil
        }
    }

    // MARK: Audition

    func startAuditionIfNeeded() {
        guard isOpen, !audition.isRunning else { return }
        do {
            try audition.start()
            auditionFailure = nil
        } catch let failure as SoundAuditionEngine.AuditionError {
            auditionFailure = failure.description
        } catch {
            auditionFailure = (error as NSError).localizedDescription
        }
    }

    func noteOn(_ note: Int, velocity: Int = 96) {
        guard isOpen else { return }
        startAuditionIfNeeded()
        guard !soundingNotes.contains(note) else { return }
        soundingNotes.insert(note)
        if !audition.noteOn(note, velocity: velocity) {
            statusMessage = "Too many notes at once — that one was dropped."
        }
    }

    func noteOff(_ note: Int) {
        guard soundingNotes.remove(note) != nil else { return }
        audition.noteOff(note)
    }

    /// One note, played and released, for a keyboard shortcut or a menu item.
    /// The release is queued behind the press, so the envelope gets its attack.
    func playTestChord() {
        guard isOpen else { return }
        for note in Self.testChord { noteOn(note, velocity: 100) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            for note in Self.testChord { noteOff(note) }
        }
    }

    /// A major triad with the root an octave below, which says more about a
    /// sound in one press than a single note does: it exercises the polyphony,
    /// the low end and the beating between partials all at once.
    static let testChord = [48, 60, 64, 67]

    func releaseEverything() {
        soundingNotes.removeAll()
        audition.allNotesOff()
    }

    // MARK: Playing a piece through this sound

    /// Route the open piece's playback through the sound being edited.
    ///
    /// Every line, because per-line assignment is increment 004's. What this
    /// buys now is the thing REQ-018 actually asks about: an edit that is
    /// audible in real music, while that music keeps playing. Turning it on
    /// publishes into the running voices rather than rebuilding the program, so
    /// the piece does not stop to let it happen.
    func startPlayingPieceThroughSound() {
        guard isOpen else { return }
        isPlayingPieceThroughSound = true
        playbackChannel.apply(patch)
        onPlayThroughChanged?(true)
        statusMessage = "Every line of the piece is now playing through “\(title)”."
    }

    func stopPlayingPieceThroughSound() {
        guard isPlayingPieceThroughSound else { return }
        isPlayingPieceThroughSound = false
        playbackChannel.apply(.defaultVoice)
        onPlayThroughChanged?(false)
        statusMessage = "The piece is back on the sounds its preset assigns."
    }

    func togglePlayingPieceThroughSound() {
        isPlayingPieceThroughSound
            ? stopPlayingPieceThroughSound()
            : startPlayingPieceThroughSound()
    }

    // MARK: Internals

    /// Publishes the patch as it now stands to everything that renders it.
    ///
    /// Three destinations, and they are not the same thing:
    ///
    /// * the **audition** channel, so the test keyboard plays the edit;
    /// * the **play-through** channel, when the studio has taken the whole
    ///   piece over; and
    /// * **every line of the open piece that is assigned this sound**, which is
    ///   REQ-018 as the definition words it — *edited live during piece
    ///   playback* — now that a piece has a sound per line rather than one for
    ///   all of them. The transport's channels reach the voices that are
    ///   already sounding, so this needs no rebuild and the music does not stop.
    private func publishWorkingPatch() {
        auditionChannel.apply(patch)
        if isPlayingPieceThroughSound { playbackChannel.apply(patch) }
        if let entry, entry.isEditable { onPatchEdited?(entry.id, patch) }
    }

    /// Puts a sound the owner edited and then walked away from back to what the
    /// library holds, so an unsaved edit never silently outlives the editor.
    private func restoreStoredPatch(of entry: SoundEntry?) {
        guard let entry, entry.isEditable, patch != savedPatch else { return }
        onPatchEdited?(entry.id, savedPatch)
    }
}
