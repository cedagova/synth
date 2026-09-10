import XCTest
@testable import Synth
import SynthKit

/// The wiring between the sound studio and the open piece, at the level where
/// it is actually made (REQ-018).
///
/// **This suite exists because of a specific gap.** The increment-004 effort
/// review found that nothing covered the closures `AppModel.openSoundStudio`
/// installs: `SoundEditorModel` was proved to call `onPatchEdited`, and
/// `AssignmentModel.publishEditedSound` was proved to reach the running voices,
/// but the line joining them was proved nowhere. Deleting it would have passed
/// every test in the project while REQ-018 quietly stopped working in the app.
/// Increment 005 adds a second editor with the same shape, which doubles that
/// surface — so this leaf closes the gap rather than widening it.
///
/// It is a host-application test target because that is what proving this
/// requires: `AppModel`, `SoundStudioModel`, `SoundEditorModel` and
/// `InstrumentEditorModel` are the app's, not `SynthKit`'s, and a test that
/// could only see `SynthKit` is exactly the test that already existed and did
/// not catch this.
///
/// Everything here runs against a real store in a temporary container, driven
/// through the same methods the menus and the screens call. Nothing is stubbed:
/// the assertion is always "the open piece's line now plays what the editor
/// says", read from `AssignmentModel.lines`, which is the same value the mixer
/// strip renders.
@MainActor
final class AppModelWiringTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: directory)
        model = AppModel(container: container)
        await model.bootstrap()
        guard model.store != nil else {
            return XCTFail("The store did not open; nothing below can be meaningful.")
        }
        // A fresh store raises the first-run instrument offer over everything,
        // and the keyboard rightly does nothing while the catalog is showing.
        // These tests are about the studio and the transport, so decline it.
        model.closeInstrumentCatalog()
    }

    override func tearDown() async throws {
        model?.closePlayback()
        model = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: The fixture

    /// A one-part score, small enough to compile instantly and real enough to
    /// go through the whole import, compile, realize and preset path.
    private static let onePartScore = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>Cello</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>4</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>F</sign><line>4</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>3</octave></pitch>
                <duration>16</duration><type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """

    /// Import the fixture and open it on the transport, prepared and ready.
    private func openPreparedPiece() async throws -> PlaybackModel {
        let source = directory.appending(path: "fixture.musicxml")
        try Data(Self.onePartScore.utf8).write(to: source)

        let library = try XCTUnwrap(model.library, "The library model should exist once open")
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first, "The fixture should have imported")

        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback, "Opening a piece should make a transport")
        await playback.prepare()
        XCTAssertTrue(playback.assignment.isReady, "The piece should have resolved lines")
        return playback
    }

    private func store() throws -> LibraryStore {
        try XCTUnwrap(model.store, "The store should be open")
    }

    /// Installs one real catalog instrument into this test's own container.
    ///
    /// **A real catalog entry with placeholder bytes, not a fake catalog.** The
    /// store resolves an instrument by asking this build's catalog where its
    /// SFZ lives and then looking on disk, so writing the files that entry
    /// names is the whole of what a download does as far as everything above
    /// the transfer is concerned. Which is what this test needs: an instrument
    /// the capability gate will actually measure, because a customization
    /// control is offered only on an instrument there is something to measure.
    @discardableResult
    private func installFixtureCello() throws -> InstrumentReference {
        let library = try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        let coverage = try XCTUnwrap(
            library.coverage.first { $0.identifier == "vsco2.cello.section" }
        )
        let root = try store().instruments.stagingArea
            .installedURL(forLibraryID: library.identifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try Self.mono16BitWave(seconds: 0.25).write(to: root.appending(path: "cello.wav"))
        for path in coverage.allSFZPaths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try """
                <group> ampeg_attack=0 ampeg_release=0.2
                <region> sample=cello.wav lokey=36 hikey=72 pitch_keycenter=57
                """.write(to: url, atomically: true, encoding: .utf8)
        }

        try store().instruments.recordInstall(of: library)
        XCTAssertTrue(
            try store().instruments.resolve(InstrumentReference(library: library, coverage: coverage))
                .isPlayable,
            "The fixture install should resolve as playable"
        )
        return InstrumentReference(library: library, coverage: coverage)
    }

    /// A quarter-second 44.1 kHz mono sine as a canonical RIFF/WAVE file.
    ///
    /// Written by hand rather than borrowed from `SynthKitTests`: that target's
    /// fixtures are not visible from a host-application test bundle, and this is
    /// forty lines against a format that has not changed since 1991.
    private static func mono16BitWave(seconds: Double, hertz: Double = 220) -> Data {
        let sampleRate = 44_100
        let frames = Int(Double(sampleRate) * seconds)

        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = sin(2 * .pi * hertz * Double(frame) / Double(sampleRate)) * 0.4
            let quantised = Int16(max(-32_768, min(32_767, (value * 32_767).rounded())))
            withUnsafeBytes(of: quantised.littleEndian) { samples.append(contentsOf: $0) }
        }

        func chunk(_ identifier: String, _ payload: Data) -> Data {
            var out = Data(identifier.utf8)
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(payload)
            if payload.count % 2 == 1 { out.append(0) }
            return out
        }

        var format = Data()
        for value in [UInt16(1), UInt16(1)] {           // PCM, one channel
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }
        for value in [UInt32(sampleRate), UInt32(sampleRate * 2)] {  // rate, byte rate
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }
        for value in [UInt16(2), UInt16(16)] {          // block align, bit depth
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }

        let body = Data("WAVE".utf8) + chunk("fmt ", format) + chunk("data", samples)
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        return file + body
    }

    private func patch(cutoff: Double) -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.8),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: cutoff),
            outputLevel: 0.2
        )
    }

    // MARK: The three closures exist at all

    /// The cheapest half of the guard, and the one that catches a deletion.
    ///
    /// A closure that is never installed cannot be reached by any behaviour
    /// test further down, so this asserts the connection itself before the
    /// tests that assert what flows through it.
    func testOpeningTheStudioInstallsEveryPlaybackConnection() throws {
        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio, "Opening the studio should build it")

        XCTAssertNotNil(
            studio.editor.onPlayThroughChanged,
            "Play-through has to reach the transport, or ⌥⌘P silently does nothing."
        )
        XCTAssertNotNil(
            studio.editor.onPatchEdited,
            "A patch edit has to reach the open piece, or REQ-018 silently stops working."
        )
        XCTAssertNotNil(
            studio.instrumentEditor.onVariantEdited,
            "A customization edit has to reach the open piece for the same reason."
        )
    }

    // MARK: A synth edit reaches the line playing it (REQ-018)

    func testEditingAnAssignedSoundReachesThatLineOfTheOpenPiece() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        // A sound of the owner's own, assigned to the line, exactly as the
        // studio and the mixer would do it.
        let sound = try store().sounds.create(
            patch: patch(cutoff: 1_000), named: "Under Edit", in: .strings
        )
        // The panel's palette is read when the piece opens, so a sound made
        // after that has to be picked up before it can be assigned — which is
        // exactly what returning from the studio does.
        assignment.refreshFromStore()
        assignment.assign(soundID: sound.id, toLine: line)
        XCTAssertNil(assignment.alert, "Assigning should have succeeded")
        XCTAssertTrue(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line })
                .source.isLibrarySound(sound.id),
            "The line should now hold a live reference to that sound"
        )

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = sound.id
        XCTAssertEqual(studio.editor.entry?.id, sound.id, "The editor should hold that sound")

        // Move one parameter. Nothing is saved: the point of REQ-018 is that
        // the *working* patch is heard while the piece plays.
        studio.editor.setValue(.number(7_500), for: .filterCutoff)

        let resolved = try XCTUnwrap(assignment.lines.first { $0.lineID == line })
        XCTAssertEqual(
            try XCTUnwrap(resolved.patch).filter.cutoffHertz, 7_500, accuracy: 0.5,
            "The edit must reach the open piece's line through AppModel's own wiring"
        )
    }

    /// The other half of REQ-018's sentence: *and nothing else*.
    func testEditingASoundNoLineUsesLeavesTheOpenPieceAlone() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let assigned = try store().sounds.create(
            patch: patch(cutoff: 1_000), named: "Assigned", in: .strings
        )
        let unrelated = try store().sounds.create(
            patch: patch(cutoff: 2_000), named: "Unrelated", in: .pads
        )
        assignment.refreshFromStore()
        assignment.assign(soundID: assigned.id, toLine: line)
        XCTAssertNil(assignment.alert, "Assigning should have succeeded")

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = unrelated.id
        studio.editor.setValue(.number(9_000), for: .filterCutoff)

        let resolved = try XCTUnwrap(assignment.lines.first { $0.lineID == line })
        XCTAssertEqual(
            try XCTUnwrap(resolved.patch).filter.cutoffHertz, 1_000, accuracy: 0.5,
            "Editing a sound this line does not play must not change what it plays"
        )
    }

    // MARK: An instrument edit reaches the line playing it (REQ-018, INS003)

    /// The same claim for a customized instrument, through the second editor.
    ///
    /// The variant references an instrument no library here installs, which is
    /// deliberate: what is under test is the *wiring*, and a variant travels
    /// from the editor to the open piece's line through exactly the same
    /// closure whether or not its samples are on disk. That the edit also
    /// reaches a sampled voice that is already sounding is proved at the layer
    /// that can prove it, by
    /// `InstrumentCustomizationRenderTests.testAnEditReachesAVoiceThatIsAlreadySounding`;
    /// that the line is flagged and silent meanwhile is
    /// `InstrumentAssignmentTests`. Neither of those can see `AppModel`, which
    /// is the gap this file exists to close.
    func testEditingAnAssignedVariantReachesThatLineOfTheOpenPiece() async throws {
        // Installed first: a customization control is offered only on an
        // instrument there is something to measure, so a variant of a library
        // the owner has not downloaded is correctly inert — which is a
        // different claim, proved in `InstrumentAssignmentTests`.
        let playback = try await openPreparedPiece()
        let reference = try installFixtureCello()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let variant = try store().sounds.createVariant(
            InstrumentVariant(reference: reference), named: "Darker Cello", in: .strings
        )
        assignment.refreshFromStore()
        assignment.assign(soundID: variant.id, toLine: line)
        XCTAssertNil(assignment.alert, "Assigning a variant should have succeeded")
        XCTAssertEqual(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line }).content.kind, .instrument,
            "The line should now be an instrument line"
        )

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = variant.id
        XCTAssertEqual(
            studio.instrumentEditor.entry?.id, variant.id,
            "A variant must open in the instrument editor, not the synth one"
        )
        XCTAssertTrue(studio.isEditingInstrument)
        XCTAssertTrue(
            studio.instrumentEditor.isSupported(.toneLow),
            "The instrument is installed, so its tone controls are live"
        )

        studio.instrumentEditor.setValue(-6, for: .toneLow)

        let resolved = try XCTUnwrap(assignment.lines.first { $0.lineID == line })
        XCTAssertEqual(
            try XCTUnwrap(resolved.variant).customization.toneLowDecibels, -6, accuracy: 0.001,
            "The customization edit must reach the open piece's line through AppModel's wiring"
        )
    }

    /// …and an edit to a variant no line plays leaves the piece alone.
    func testEditingAVariantNoLineUsesLeavesTheOpenPieceAlone() async throws {
        let playback = try await openPreparedPiece()
        let reference = try installFixtureCello()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let assigned = try store().sounds.createVariant(
            InstrumentVariant(reference: reference), named: "Assigned Cello", in: .strings
        )
        let unrelated = try store().sounds.createVariant(
            InstrumentVariant(reference: reference), named: "Unrelated Cello", in: .strings
        )
        assignment.refreshFromStore()
        assignment.assign(soundID: assigned.id, toLine: line)

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = unrelated.id
        studio.instrumentEditor.setValue(9, for: .toneHigh)

        let resolved = try XCTUnwrap(assignment.lines.first { $0.lineID == line })
        XCTAssertEqual(
            try XCTUnwrap(resolved.variant).customization.toneHighDecibels, 0, accuracy: 0.001,
            "Editing a variant this line does not play must not change what it plays"
        )
    }

    // MARK: Play-through reaches the transport

    func testPlayThroughReachesTheTransportAndComesBack() async throws {
        let playback = try await openPreparedPiece()
        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = try XCTUnwrap(studio.sounds.first).id

        studio.editor.startPlayingPieceThroughSound()
        XCTAssertTrue(
            playback.assignment.isSuspendedByPlayThrough,
            "Turning play-through on must reach the transport"
        )

        studio.editor.stopPlayingPieceThroughSound()
        XCTAssertFalse(
            playback.assignment.isSuspendedByPlayThrough,
            "Turning it off must put the preset back"
        )
    }

    // MARK: The transport sends the owner to the studio (REQ-017)

    /// A line playing one of Synth's own sounds: "edit" means a copy of the
    /// owner's own, on the line, selected in the studio — three steps the
    /// owner used to make by hand across two screens.
    func testEditingAShippedSoundFromTheLineCopiesItOntoTheLine() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let shipped = try XCTUnwrap(
            try store().sounds.allSounds().first { $0.origin == .shipped && $0.kind == .synth }
        )
        assignment.assign(soundID: shipped.id, toLine: line)
        XCTAssertNil(assignment.alert)

        model.openSoundStudio(.editSound(ofLine: line))
        XCTAssertTrue(model.isStudioShowing, "The request should show the studio")
        let studio = try XCTUnwrap(model.studio)
        let copy = try XCTUnwrap(studio.selectedSound, "The studio should have selected something")

        XCTAssertNotEqual(copy.id, shipped.id, "The shipped sound must not be what is selected")
        XCTAssertEqual(copy.shippedOriginID, shipped.id, "The selection should be a copy of it")
        XCTAssertTrue(copy.isEditable, "…and the copy is the owner's to edit")
        XCTAssertEqual(studio.editor.entry?.id, copy.id, "The editor should hold the copy")
        XCTAssertTrue(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line }).source.isLibrarySound(copy.id),
            "The line should now play the copy, so the edits about to be made are the edits heard"
        )
        XCTAssertNil(assignment.alert, "Putting the copy on the line should have succeeded")
    }

    /// A line already playing a sound of the owner's own: nothing is copied,
    /// because there is nothing REQ-017 protects; the sound is simply opened.
    func testEditingAUserSoundFromTheLineSelectsItWithoutCopying() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let sound = try store().sounds.create(patch: patch(cutoff: 900), named: "Mine", in: .keys)
        assignment.refreshFromStore()
        assignment.assign(soundID: sound.id, toLine: line)
        let before = try store().sounds.allSounds().count

        model.openSoundStudio(.editSound(ofLine: line))
        let studio = try XCTUnwrap(model.studio)

        XCTAssertEqual(studio.selection, sound.id, "The line's own sound should be selected")
        XCTAssertEqual(studio.editor.entry?.id, sound.id)
        XCTAssertEqual(try store().sounds.allSounds().count, before, "Nothing should have been copied")
        XCTAssertTrue(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line }).source.isLibrarySound(sound.id),
            "The line's assignment must be untouched"
        )
    }

    /// The search must not hide what the transport asked for: a selection the
    /// list cannot show is replaced by the first visible row.
    func testRevealingASoundClearsASearchThatWouldHideIt() async throws {
        let playback = try await openPreparedPiece()
        let line = try XCTUnwrap(playback.assignment.lines.first).lineID
        let sound = try store().sounds.create(patch: patch(cutoff: 900), named: "Mine", in: .keys)
        playback.assignment.refreshFromStore()
        playback.assignment.assign(soundID: sound.id, toLine: line)

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.searchText = "no such sound anywhere"

        model.openSoundStudio(.editSound(ofLine: line))
        XCTAssertEqual(studio.searchText, "", "The search should have been cleared")
        XCTAssertEqual(studio.selection, sound.id)
    }

    /// A new sound for a line is created and on the line before the studio is
    /// even looked at.
    func testANewSoundForALineIsCreatedAndAssigned() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID
        let before = try store().sounds.allSounds().count

        model.openSoundStudio(.newSound(forLine: line))
        let studio = try XCTUnwrap(model.studio)
        let created = try XCTUnwrap(studio.selectedSound)

        XCTAssertEqual(try store().sounds.allSounds().count, before + 1, "One sound should exist now")
        XCTAssertTrue(created.isEditable)
        XCTAssertEqual(studio.editor.entry?.id, created.id, "The editor should hold it")
        XCTAssertTrue(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line }).source.isLibrarySound(created.id),
            "The line should play the new sound"
        )
        XCTAssertNil(assignment.alert)
    }

    /// A request the studio cannot meet still opens the studio and says why,
    /// rather than doing nothing: the plain request opens it on whatever it
    /// showed, and a line that no longer exists is not a reason to hide it.
    func testARequestForAMissingLineStillOpensTheStudio() async throws {
        _ = try await openPreparedPiece()
        model.openSoundStudio(.editSound(ofLine: ScoreLineID(rawValue: "no-such-line")))
        XCTAssertTrue(model.isStudioShowing, "The owner asked for the studio; they get it")
        XCTAssertNil(
            try XCTUnwrap(model.studio).selection,
            "Nothing could be found for that line, so nothing was selected on its behalf"
        )
    }

    // MARK: The Switched-On preset

    /// The fixture's one part is called "Cello": the button makes a new
    /// active preset named Switched-On with that line on Modular Cello.
    func testTheSwitchedOnPresetPutsANamedPartOnItsSound() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let before = assignment.presets.count
        let line = try XCTUnwrap(assignment.lines.first).lineID

        assignment.createSwitchedOnPreset()

        XCTAssertNil(assignment.alert)
        XCTAssertEqual(assignment.presets.count, before + 1, "One new preset")
        XCTAssertEqual(assignment.activePreset?.name, "Switched-On", "…active, and named")
        XCTAssertTrue(
            try XCTUnwrap(assignment.lines.first { $0.lineID == line })
                .source.isLibrarySound("shipped.modular-cello"),
            "The Cello part plays Modular Cello"
        )

        assignment.createSwitchedOnPreset()
        XCTAssertEqual(assignment.activePreset?.name, "Switched-On 2", "A second one steps the name")
    }

    // MARK: The computer keyboard (KeyboardControl)

    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, w: UInt16 = 13
        static let z: UInt16 = 6, x: UInt16 = 7, c: UInt16 = 8, v: UInt16 = 9
        static let space: UInt16 = 49, `return`: UInt16 = 36
        static let left: UInt16 = 123, comma: UInt16 = 43
    }

    /// Opens the studio on the first synth sound and returns its editor.
    private func openStudioOnASynthSound() throws -> SoundEditorModel {
        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = try XCTUnwrap(studio.sounds.first { $0.kind == .synth }).id
        XCTAssertTrue(studio.editor.isOpen)
        return studio.editor
    }

    func testTypingAKeyPlaysTheNoteAndReleasingItStopsIt() throws {
        let editor = try openStudioOnASynthSound()

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.a)), "A is a note key")
        XCTAssertEqual(editor.soundingNotes, [48], "A plays C3, the on-screen keyboard's lowest key")

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.w)))
        XCTAssertEqual(editor.soundingNotes, [48, 49], "W is the black key above it")

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.a, isKeyDown: false)))
        XCTAssertEqual(editor.soundingNotes, [49], "Releasing A releases only C3")

        model.keyboard.handle(KeyStroke(keyCode: Key.w, isKeyDown: false))
        XCTAssertTrue(editor.soundingNotes.isEmpty)
    }

    func testARepeatedKeyDoesNotStrikeAgain() throws {
        let editor = try openStudioOnASynthSound()
        model.keyboard.handle(KeyStroke(keyCode: Key.a))
        model.keyboard.handle(KeyStroke(keyCode: Key.a, isKeyDown: false))
        XCTAssertTrue(editor.soundingNotes.isEmpty)

        model.keyboard.handle(KeyStroke(keyCode: Key.a))
        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.a, isRepeat: true)),
                      "The repeat is still ours — it must not fall through to the window")
        XCTAssertEqual(editor.soundingNotes, [48], "…but it does not strike the note again")
    }

    func testOctaveAndVelocityKeysMoveTheTypingKeyboard() throws {
        let editor = try openStudioOnASynthSound()

        model.keyboard.handle(KeyStroke(keyCode: Key.x))
        XCTAssertEqual(editor.typingLowestNote, 60, "X moves an octave up")
        model.keyboard.handle(KeyStroke(keyCode: Key.a))
        XCTAssertEqual(editor.soundingNotes, [60])

        // The octave moves while the key is held: releasing it must release
        // the note it started, not the note A would play now.
        model.keyboard.handle(KeyStroke(keyCode: Key.z))
        model.keyboard.handle(KeyStroke(keyCode: Key.z))
        XCTAssertEqual(editor.typingLowestNote, 36)
        model.keyboard.handle(KeyStroke(keyCode: Key.a, isKeyDown: false))
        XCTAssertTrue(editor.soundingNotes.isEmpty, "The held C4 was released")

        for _ in 0..<10 { model.keyboard.handle(KeyStroke(keyCode: Key.z)) }
        XCTAssertEqual(editor.typingLowestNote, 0, "The octave stops at C-1... the MIDI floor")

        model.keyboard.handle(KeyStroke(keyCode: Key.v))
        XCTAssertEqual(editor.typingVelocity, 112, "V plays harder")
        for _ in 0..<10 { model.keyboard.handle(KeyStroke(keyCode: Key.c)) }
        XCTAssertEqual(editor.typingVelocity, 16, "C plays softer, down to a floor that is still audible")
    }

    func testTypingStandsAsideForTextFieldsMenusAndSheets() throws {
        let editor = try openStudioOnASynthSound()

        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.a, isTypingText: true)),
                       "A letter typed into the search field is a letter")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.a, hasMenuModifiers: true)),
                       "Command-A is Select All, not a note")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.a, isInSecondaryWindow: true)),
                       "A key in the variant-name sheet is the sheet's")
        XCTAssertTrue(editor.soundingNotes.isEmpty)
    }

    func testNothingSoundsWhenNoSynthSoundIsOpen() throws {
        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = nil
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.a)),
                       "With no sound under edit there is nothing to play, so the key is not ours")
    }

    func testReleasingEverythingForgetsHeldTypingKeys() throws {
        let editor = try openStudioOnASynthSound()
        model.keyboard.handle(KeyStroke(keyCode: Key.a))
        editor.releaseEverything()
        XCTAssertTrue(editor.soundingNotes.isEmpty)
        // The key is still physically down as far as the router knows; a fresh
        // press must play again rather than be refused as already held.
        model.keyboard.handle(KeyStroke(keyCode: Key.a))
        XCTAssertEqual(editor.soundingNotes, [48])
    }

    /// The transport state itself is read back from the render thread on a
    /// later tick, so what a synchronous test can see is the model's own
    /// account of what it asked the engine to do — which is also what the
    /// status bar shows.
    func testSpacePlaysAndReturnStops() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.space)))
        XCTAssertEqual(playback.statusMessage, "Playing.", "Space plays")

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.space, isRepeat: true)),
                      "A held Space is still ours…")
        XCTAssertEqual(playback.statusMessage, "Playing.", "…and does nothing more")

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.return)))
        XCTAssertEqual(playback.statusMessage, "Stopped.", "Return stops")
        XCTAssertEqual(playback.positionMicroseconds, 0, "…and returns to the start")
    }

    func testTransportKeysStandAsideWhereTheyWouldSteal() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.space, isTypingText: true)),
                       "A space in the search field is a space")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.left, hasMenuModifiers: true)),
                       "Option-Command-Left is the menu's")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.space, isInSecondaryWindow: true)),
                       "Space in the export sheet is the sheet's")
        XCTAssertFalse(playback.isPlaying)

        model.closePlayback()
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.space)),
                       "With no piece open there is no transport")
    }

    /// Under the studio the piece keeps playing, and Space still reaches it.
    /// The other transport keys do not: Return finishes a rename there and
    /// the arrows move a slider.
    func testOnlySpaceReachesTheTransportFromTheStudio() async throws {
        let playback = try await openPreparedPiece()
        _ = try openStudioOnASynthSound()

        XCTAssertTrue(model.keyboard.handle(KeyStroke(keyCode: Key.space)))
        XCTAssertEqual(playback.statusMessage, "Playing.", "Space plays the piece from the studio")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.comma)),
                       "Comma is not taken from the studio")
        XCTAssertFalse(model.keyboard.handle(KeyStroke(keyCode: Key.return)),
                       "Return is not taken from the studio")
        XCTAssertEqual(playback.statusMessage, "Playing.", "Neither reached the transport")
        playback.stop()
    }
}
