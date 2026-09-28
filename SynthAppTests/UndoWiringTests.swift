import XCTest
@testable import Synth
import SynthKit

/// Undo and redo of mix and preset changes (UND001, #89), driven through a real
/// `UndoManager` exactly as the Edit menu drives the window's.
///
/// Every assertion checks all three places a mix value lives — the row the
/// panel renders, the engine strip the owner hears, and the preset on disk —
/// because an undo that reaches only one of them is the bug this leaf exists
/// to prevent. Preset switches are awaited until the transport has adopted the
/// arriving preset's settings (#96), so each test asserts the final state.
@MainActor
final class UndoWiringTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var undo: UndoManager!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "UndoWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(container: AppContainer(rootURL: directory.appending(path: "container")))
        await model.bootstrap()
        guard model.store != nil else {
            return XCTFail("The store did not open; nothing below can be meaningful.")
        }
        undo = UndoManager()
    }

    override func tearDown() async throws {
        model?.playback?.assignment.detachUndoManager()
        model?.closePlayback()
        model = nil
        undo = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: Fixture

    private static let score = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <work><work-title>Undo Fixture</work-title></work>
          <part-list>
            <score-part id="P1"><part-name>Flute</part-name></score-part>
            <score-part id="P2"><part-name>Cello</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef></attributes>
              <note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type></note>
            </measure>
          </part>
          <part id="P2">
            <measure number="1">
              <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>F</sign><line>4</line></clef></attributes>
              <note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><type>whole</type></note>
            </measure>
          </part>
        </score-partwise>
        """

    private func openPiece() async throws -> AssignmentModel {
        let source = directory.appending(path: "undo-fixture.musicxml")
        try Data(Self.score.utf8).write(to: source)
        let library = try XCTUnwrap(model.library)
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first, "The fixture should have imported")
        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback)
        await playback.prepare()
        let assignment = playback.assignment
        XCTAssertTrue(assignment.isReady)
        // What the playback screen does when it appears.
        assignment.attachUndoManager(undo)
        return assignment
    }

    private func firstLine(_ assignment: AssignmentModel) throws -> ScoreLineID {
        try XCTUnwrap(assignment.lines.first).lineID
    }

    private func row(_ lineID: ScoreLineID, _ assignment: AssignmentModel) throws -> LineMixerState {
        try XCTUnwrap(assignment.lines.first { $0.lineID == lineID }).mixer
    }

    private func stored(_ presetID: String, _ lineID: ScoreLineID) throws -> LineMixerState {
        try XCTUnwrap(storedPreset(presetID).line(withID: lineID)).mixer
    }

    private func storedPreset(_ presetID: String) throws -> Preset {
        let store = try XCTUnwrap(model.store)
        let pieceID = try XCTUnwrap(model.playback).piece.id
        return try XCTUnwrap(store.presets.presets(forPieceID: pieceID).first { $0.id == presetID })
    }

    private func gain(_ lineID: ScoreLineID, _ assignment: AssignmentModel) throws -> Float {
        try XCTUnwrap(assignment.engineStrip(for: lineID)).gain
    }

    /// Waits until the transport has adopted the active preset's settings, so a
    /// switch is asserted after adoption completes rather than racing it (#96).
    private func waitForAdoption(timeout: TimeInterval = 10) async throws {
        let playback = try XCTUnwrap(model.playback)
        let deadline = Date().addingTimeInterval(timeout)
        func adopted() -> Bool {
            guard let content = playback.assignment.activePreset?.content else { return false }
            return playback.tempoPercent == content.tempoPercent
                && playback.humanization == content.humanization
                && playback.expression == content.expression
                && playback.producedMaster == content.producedMaster
                && playback.tuning == content.tuning
        }
        while !adopted(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(adopted(), "the transport never adopted the active preset's settings")
    }

    /// A second preset that differs from the first in tempo, so switching
    /// between them actually has something to adopt. Returns (first, second).
    private func twoPresets(_ assignment: AssignmentModel) async throws -> (String, String) {
        let first = try XCTUnwrap(assignment.activePreset).id
        assignment.createPreset()
        assignment.cancelPresetRename()
        let second = try XCTUnwrap(assignment.activePreset)
        XCTAssertNotEqual(first, second.id)
        try XCTUnwrap(model.store).presets.setTempoPercent(80, in: second)
        assignment.refreshFromStore()
        try await waitForAdoption()
        XCTAssertFalse(undo.canUndo, "making a preset leaves no history behind")
        return (first, second.id)
    }

    // MARK: Volume

    /// A drag is a hundred previews and one commit; it is one step, and undoing
    /// it puts the row, the strip and the saved preset back together.
    func testAVolumeDragIsOneStepAndUndoRestoresRowStripAndStore() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)
        let presetID = try XCTUnwrap(assignment.activePreset).id
        let before = try row(line, assignment).volume

        for value in [0.9, 0.7, 0.5, 0.3] { assignment.previewVolume(value, forLine: line) }
        assignment.commitMixer(forLine: line, describedAs: "volume")

        XCTAssertEqual(try stored(presetID, line).volume, 0.3)
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Volume Change")

        undo.undo()
        XCTAssertEqual(try row(line, assignment).volume, before)
        XCTAssertEqual(try gain(line, assignment), Float(before))
        XCTAssertEqual(try stored(presetID, line).volume, before)
        XCTAssertFalse(undo.canUndo, "the whole drag was one step, so one undo takes all of it")
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(undo.redoActionName, "Volume Change")

        undo.redo()
        XCTAssertEqual(try row(line, assignment).volume, 0.3)
        XCTAssertEqual(try gain(line, assignment), 0.3)
        XCTAssertEqual(try stored(presetID, line).volume, 0.3)
        XCTAssertNil(assignment.alert)
    }

    // MARK: Mute

    func testUndoAndRedoOfMute() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)
        let presetID = try XCTUnwrap(assignment.activePreset).id

        assignment.setMuted(true, forLine: line)
        XCTAssertEqual(undo.undoActionName, "Mute Change")

        undo.undo()
        XCTAssertFalse(try row(line, assignment).isMuted)
        XCTAssertFalse(try XCTUnwrap(assignment.engineStrip(for: line)).isMuted)
        XCTAssertFalse(try stored(presetID, line).isMuted)

        undo.redo()
        XCTAssertTrue(try row(line, assignment).isMuted)
        XCTAssertTrue(try XCTUnwrap(assignment.engineStrip(for: line)).isMuted)
        XCTAssertTrue(try stored(presetID, line).isMuted)
    }

    // MARK: Preset switch (P84-6)

    /// A switch is a step, so unwinding re-activates the preset an older mixer
    /// step was made on before that step is applied — and the step never
    /// touches the other preset.
    func testPresetSwitchIsAStepAndUnwindsInOrder() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)
        let (first, second) = try await twoPresets(assignment)
        let secondVolume = try stored(second, line).volume

        assignment.activate(presetID: first)
        try await waitForAdoption()
        XCTAssertEqual(undo.undoActionName, "Preset Switch")
        let before = try row(line, assignment).volume
        assignment.setVolume(0.25, forLine: line)

        undo.undo()   // the volume, on the first preset
        XCTAssertEqual(assignment.activePreset?.id, first)
        XCTAssertEqual(try stored(first, line).volume, before)
        XCTAssertEqual(try gain(line, assignment), Float(before))

        undo.undo()   // the switch
        try await waitForAdoption()
        XCTAssertEqual(assignment.activePreset?.id, second)
        XCTAssertTrue(try storedPreset(second).isActive)
        XCTAssertEqual(try XCTUnwrap(model.playback).tempoPercent, 80)
        XCTAssertEqual(try stored(second, line).volume, secondVolume, "never written to the other preset")

        undo.redo()   // back to the first
        try await waitForAdoption()
        XCTAssertEqual(assignment.activePreset?.id, first)
        undo.redo()   // and its volume
        XCTAssertEqual(try stored(first, line).volume, 0.25)
        XCTAssertEqual(try row(line, assignment).volume, 0.25)
        XCTAssertEqual(try gain(line, assignment), 0.25)
        XCTAssertEqual(try stored(second, line).volume, secondVolume)
        XCTAssertNil(assignment.alert)
    }

    /// A step whose preset has gone is refused and the history cleared, rather
    /// than applied to whatever is showing (P84-6).
    func testAStepWhosePresetIsGoneClearsHistoryInsteadOfApplyingElsewhere() async throws {
        let assignment = try await openPiece()
        let (first, second) = try await twoPresets(assignment)
        assignment.activate(presetID: first)
        try await waitForAdoption()
        assignment.activate(presetID: second)
        try await waitForAdoption()
        // Removed behind the model's back — the case deletion's own clear
        // cannot see.
        try XCTUnwrap(model.store).presets.delete(try storedPreset(first))
        assignment.refreshFromStore()

        undo.undo()
        XCTAssertNotNil(assignment.alert)
        XCTAssertEqual(assignment.activePreset?.id, second)
        XCTAssertFalse(assignment.canUndoMix)
        XCTAssertFalse(assignment.canRedoMix)
        // The manager is resynchronized once its own undo has returned.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    // MARK: Preset rename

    func testUndoAndRedoOfPresetRenameAndADraftRegistersNothing() async throws {
        let assignment = try await openPiece()
        let preset = try XCTUnwrap(assignment.activePreset)
        let original = preset.name

        assignment.beginPresetRename()
        assignment.presetNameDraft = "Drafted"
        XCTAssertFalse(undo.canUndo, "a drafted name is not a step until it commits")

        assignment.presetNameDraft = "Loud"
        assignment.commitPresetRename()
        XCTAssertEqual(undo.undoActionName, "Preset Rename")

        undo.undo()
        XCTAssertEqual(assignment.activePreset?.name, original)
        XCTAssertEqual(try storedPreset(preset.id).name, original)

        undo.redo()
        XCTAssertEqual(assignment.activePreset?.name, "Loud")
        XCTAssertEqual(try storedPreset(preset.id).name, "Loud")
    }

    // MARK: Creation and deletion clear history (P84-2)

    func testCreatingOrDeletingAPresetClearsHistory() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)

        assignment.setVolume(0.4, forLine: line)
        XCTAssertTrue(undo.canUndo)
        assignment.createPreset()
        assignment.cancelPresetRename()
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(assignment.canUndoMix)
        try await waitForAdoption()

        assignment.setVolume(0.6, forLine: line)
        undo.undo()
        XCTAssertTrue(undo.canRedo)
        let doomed = try XCTUnwrap(assignment.activePreset)
        assignment.requestPresetDeletion()
        assignment.confirmPresetDeletion(of: doomed)
        try await waitForAdoption()
        XCTAssertNotEqual(assignment.activePreset?.id, doomed.id)
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        XCTAssertFalse(assignment.canUndoMix)
        XCTAssertFalse(assignment.canRedoMix)
    }

    // MARK: Only while the playback screen shows (P84-7)

    /// With the studio or the catalog showing, the window's manager holds none
    /// of the mix, so ⌘Z there cannot touch it; coming back restores both the
    /// undo and the redo side, in order.
    func testHistoryIsNotOfferedAwayFromPlaybackAndSurvivesTheTrip() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)
        let presetID = try XCTUnwrap(assignment.activePreset).id
        let before = try row(line, assignment).volume

        assignment.setVolume(0.5, forLine: line)
        assignment.setMuted(true, forLine: line)
        undo.undo()   // the mute; leaves one undo and one redo

        assignment.detachUndoManager()   // the studio takes the window
        XCTAssertFalse(undo.canUndo, "⌘Z in the studio must not reach the mix")
        XCTAssertFalse(undo.canRedo)
        XCTAssertTrue(assignment.canUndoMix, "the history is kept for the way back")
        XCTAssertTrue(assignment.canRedoMix)
        XCTAssertEqual(try row(line, assignment).volume, 0.5)

        assignment.attachUndoManager(undo)   // back on the playback screen
        XCTAssertEqual(undo.undoActionName, "Volume Change")
        XCTAssertEqual(undo.redoActionName, "Mute Change")
        XCTAssertEqual(try row(line, assignment).volume, 0.5, "rebuilding applies nothing")
        XCTAssertFalse(try row(line, assignment).isMuted)

        undo.redo()
        XCTAssertTrue(try stored(presetID, line).isMuted)
        undo.undo()
        undo.undo()
        XCTAssertEqual(try stored(presetID, line).volume, before)
        XCTAssertFalse(try stored(presetID, line).isMuted)
        XCTAssertFalse(undo.canUndo)
    }

    // MARK: Play-through

    /// While the studio plays every line through its sound the strips are not
    /// the preset's, so an undo updates the row and the stored preset and is
    /// heard when play-through ends.
    func testUndoDuringPlayThroughIsHeardWhenItEnds() async throws {
        let assignment = try await openPiece()
        let line = try firstLine(assignment)
        let presetID = try XCTUnwrap(assignment.activePreset).id
        let before = try row(line, assignment).volume

        assignment.setVolume(0.3, forLine: line)
        assignment.setSuspendedByPlayThrough(true)
        undo.undo()
        XCTAssertEqual(try row(line, assignment).volume, before)
        XCTAssertEqual(try stored(presetID, line).volume, before)

        assignment.setSuspendedByPlayThrough(false)
        XCTAssertEqual(try gain(line, assignment), Float(before))
        XCTAssertNil(assignment.alert)
    }
}
