import XCTest
@testable import Synth
import SynthKit

/// `SoundEditorModel` directly: editing, revert, save, edit-as-copy of a
/// shipped sound, play-through and the typing keyboard, and what the owner is
/// told when the library refuses a save (issue #99).
///
/// The editor starts its audition engine when a sound loads, exactly as the
/// wiring tests' studio does; nothing here asserts on audio output, and a
/// machine without an output device only sets `auditionFailure`.
@MainActor
final class SoundEditorModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var playbackChannel: SynthPatchLiveVoices!
    private var editor: SoundEditorModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        playbackChannel = SynthPatchLiveVoices(patch: .defaultVoice)
        editor = SoundEditorModel(store: library.store, playbackChannel: playbackChannel)
    }

    override func tearDown() async throws {
        editor?.suspend()
        editor = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private var sounds: SoundLibrary { library.store.sounds }

    private func userSound(named name: String = "Test Keys") throws -> SoundEntry {
        try sounds.create(patch: .newSound(), named: name, in: .keys)
    }

    private func shippedSynthSound() throws -> SoundEntry {
        try XCTUnwrap(sounds.shippedSounds.first { $0.kind == .synth })
    }

    private func cutoff() -> Double? { editor.value(for: .filterCutoff)?.numberValue }

    /// A cutoff different from whatever the sound has now.
    private func differentCutoff() -> Double { (cutoff() ?? 1_000) == 2_345 ? 3_456 : 2_345 }

    // MARK: Opening

    func testNothingIsOpenToBeginWith() {
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.title, "No sound selected")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testLoadingAUserSoundMakesItEditable() throws {
        let entry = try userSound()
        editor.load(entry)

        XCTAssertTrue(editor.isOpen)
        XCTAssertTrue(editor.isEditable)
        XCTAssertFalse(editor.isShipped)
        XCTAssertEqual(editor.title, "Test Keys")
        XCTAssertTrue(editor.subtitle.contains("your sound"), editor.subtitle)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testAShippedSoundLoadsReadOnlyAndIgnoresEdits() throws {
        let shipped = try shippedSynthSound()
        editor.load(shipped)
        let before = editor.patch

        editor.setValue(.number(differentCutoff()), for: .filterCutoff)

        XCTAssertTrue(editor.isShipped)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.patch, before, "A shipped sound is shown, never edited")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testCloseForgetsTheSound() throws {
        editor.load(try userSound())
        editor.close()
        XCTAssertFalse(editor.isOpen)
        XCTAssertNil(editor.entry)
    }

    // MARK: Editing, revert and save

    func testAnEditIsWorkingStateAndReachesTheOpenPiece() throws {
        let entry = try userSound()
        var published: [(String, SynthPatch)] = []
        editor.onPatchEdited = { published.append(($0, $1)) }
        editor.load(entry)
        let wanted = differentCutoff()

        editor.setValue(.number(wanted), for: .filterCutoff)

        XCTAssertEqual(cutoff() ?? .nan, wanted, accuracy: 0.5)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(published.last?.0, entry.id, "Lines using this sound hear the edit")
        XCTAssertEqual(
            try sounds.sound(withID: entry.id)?.synthPatch, entry.synthPatch,
            "Nothing is written until the owner saves"
        )
    }

    func testRevertGoesBackToTheStoredSound() throws {
        editor.load(try userSound())
        let saved = editor.savedPatch
        editor.setValue(.number(differentCutoff()), for: .filterCutoff)

        editor.revert()

        XCTAssertEqual(editor.patch, saved)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.statusMessage, "Reverted “Test Keys” to the saved version.")
    }

    func testSavingWritesTheEditAndReportsIt() throws {
        let entry = try userSound()
        var saved: [SoundEntry] = []
        editor.onSaved = { saved.append($0) }
        editor.load(entry)
        editor.setValue(.number(differentCutoff()), for: .filterCutoff)
        let edited = editor.patch

        editor.save()

        XCTAssertNil(editor.alert)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.statusMessage, "Saved “Test Keys”.")
        XCTAssertEqual(saved.map(\.id), [entry.id])
        let stored = try XCTUnwrap(sounds.sound(withID: entry.id))
        XCTAssertEqual(stored.synthPatch?.filter, edited.filter)
        XCTAssertGreaterThan(stored.revision, entry.revision)
    }

    /// The failure path: the library refuses the save, the owner is told, and
    /// the unsaved edit is kept rather than thrown away.
    func testASaveTheLibraryRefusesRaisesAnAlertAndKeepsTheEdit() throws {
        let entry = try userSound()
        editor.load(entry)
        editor.setValue(.number(differentCutoff()), for: .filterCutoff)
        try library.failWrites(.update, on: SoundCatalog.tableName)

        editor.save()

        XCTAssertEqual(editor.alert?.title, "Could not save “Test Keys”")
        XCTAssertTrue(editor.hasUnsavedChanges, "The edit is still there to retry")
        XCTAssertEqual(try sounds.sound(withID: entry.id)?.synthPatch, entry.synthPatch)
    }

    func testWalkingAwayFromAnUnsavedEditPutsThePieceBack() throws {
        let first = try userSound(named: "First")
        let second = try userSound(named: "Second")
        var published: [(String, SynthPatch)] = []
        editor.onPatchEdited = { published.append(($0, $1)) }
        editor.load(first)
        let stored = editor.savedPatch
        editor.setValue(.number(differentCutoff()), for: .filterCutoff)

        editor.load(second)

        XCTAssertEqual(published.last?.0, first.id)
        XCTAssertEqual(published.last?.1, stored, "The piece goes back to what the library holds")
        XCTAssertEqual(editor.entry?.id, second.id)
    }

    func testARenameMovesOnlyTheHeading() throws {
        let entry = try userSound()
        editor.load(entry)
        let renamed = try sounds.rename(entry, to: "Renamed Keys")

        editor.adoptRenamed(renamed)

        XCTAssertEqual(editor.title, "Renamed Keys")
        XCTAssertFalse(editor.hasUnsavedChanges, "A rename is not an edit")
    }

    // MARK: Edit-as-copy (REQ-017)

    func testDuplicatingAShippedSoundMakesAnEditableCopy() throws {
        let shipped = try shippedSynthSound()
        editor.load(shipped)

        let copy = try XCTUnwrap(editor.duplicateForEditing())

        XCTAssertEqual(copy.origin, .user)
        XCTAssertEqual(copy.shippedOriginID, shipped.id)
        XCTAssertNotNil(try sounds.sound(withID: copy.id))
        XCTAssertTrue(editor.statusMessage?.contains(copy.name) == true)
    }

    func testACopyTheLibraryRefusesRaisesAnAlert() throws {
        editor.load(try shippedSynthSound())
        try library.failWrites(.insert, on: SoundCatalog.tableName)

        XCTAssertNil(editor.duplicateForEditing())
        XCTAssertTrue(editor.alert?.title.hasPrefix("Could not copy") == true)
        XCTAssertEqual(try sounds.userSoundCount(), 0)
    }

    // MARK: Play-through (SYN003)

    func testPlayThroughTellsTheTransportAndStops() throws {
        editor.load(try userSound())
        var changes: [Bool] = []
        editor.onPlayThroughChanged = { changes.append($0) }

        editor.togglePlayingPieceThroughSound()
        XCTAssertTrue(editor.isPlayingPieceThroughSound)
        editor.togglePlayingPieceThroughSound()
        XCTAssertFalse(editor.isPlayingPieceThroughSound)

        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(editor.statusMessage, "The piece is back on the sounds its preset assigns.")
    }

    func testClosingStopsPlayThrough() throws {
        editor.load(try userSound())
        editor.startPlayingPieceThroughSound()
        editor.close()
        XCTAssertFalse(editor.isPlayingPieceThroughSound)
    }

    // MARK: The typing keyboard

    func testTheTypingKeyboardShiftsOctaveAndVelocityWithinBounds() throws {
        editor.load(try userSound())

        editor.shiftTypingOctave(by: 1)
        XCTAssertEqual(editor.typingLowestNote, SoundEditorModel.typingBaseNote + 12)
        editor.shiftTypingOctave(by: 10)
        XCTAssertEqual(editor.typingLowestNote, SoundEditorModel.typingBaseNote + 48, "Capped at +4")

        editor.nudgeTypingVelocity(by: 1_000)
        XCTAssertEqual(editor.typingVelocity, 127)
        editor.nudgeTypingVelocity(by: -1_000)
        XCTAssertEqual(editor.typingVelocity, 16)
    }

    func testATypedKeyReleasesTheNoteItStarted() throws {
        editor.load(try userSound())
        editor.typingKeyDown(semitone: 0)
        XCTAssertEqual(editor.soundingNotes, [SoundEditorModel.typingBaseNote])

        editor.shiftTypingOctave(by: 1)
        editor.typingKeyUp(semitone: 0)
        XCTAssertTrue(editor.soundingNotes.isEmpty, "The octave moved, but the held note still ends")
    }

    func testNothingSoundsWithNoSoundOpen() {
        editor.noteOn(60)
        XCTAssertTrue(editor.soundingNotes.isEmpty)
    }
}
