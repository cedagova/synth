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
        assignment.assign(soundID: sound.id, toLine: line)
        XCTAssertNil(assignment.alert, "Assigning should have succeeded")

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
        assignment.assign(soundID: assigned.id, toLine: line)

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
    /// deliberate: what is under test is the *wiring*, and a variant resolves
    /// and publishes through exactly the same path whether or not its samples
    /// are on disk. That its line is also flagged and silent is the subject of
    /// `InstrumentAssignmentTests` in `SynthKitTests`, not of this one.
    func testEditingAnAssignedVariantReachesThatLineOfTheOpenPiece() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let line = try XCTUnwrap(assignment.lines.first).lineID

        let reference = InstrumentReference(
            libraryID: "vsco2-ce",
            instrumentID: "vsco2.cello.section",
            libraryName: "VSCO 2 Community Edition",
            instrumentName: "Cello section"
        )
        let variant = try store().sounds.createVariant(
            InstrumentVariant(reference: reference), named: "Darker Cello", in: .strings
        )
        assignment.assign(soundID: variant.id, toLine: line)
        XCTAssertNil(assignment.alert, "Assigning a variant should have succeeded")

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = variant.id
        XCTAssertEqual(
            studio.instrumentEditor.entry?.id, variant.id,
            "A variant must open in the instrument editor, not the synth one"
        )
        XCTAssertTrue(studio.isEditingInstrument)

        studio.instrumentEditor.setValue(-6, for: .toneLow)

        let resolved = try XCTUnwrap(assignment.lines.first { $0.lineID == line })
        XCTAssertEqual(
            try XCTUnwrap(resolved.variant).customization.toneLowDecibels, -6, accuracy: 0.001,
            "The customization edit must reach the open piece's line through AppModel's wiring"
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
}
