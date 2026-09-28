import XCTest
@testable import Synth
import SynthKit

/// #92's toggle-to-compare, at the level the menu command and the panel's
/// Compare button drive it: a real store in a temporary container, a real
/// transport, and the preset rows re-read from disk to prove nothing moved.
///
/// The measured switch gap is `PresetSwitchDeclickTests`' job; this suite
/// proves the join — that the toggle keeps the score position (also across a
/// tempo difference), plays the reference's whole performance, never touches
/// the stored presets, and ends whenever something would otherwise write, switch
/// or export while the reference is playing.
@MainActor
final class CompareWiringTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "CompareWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: directory.appending(path: "container"))
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

    /// Eight measures of 4/4 quarter notes at the default 120 bpm.
    private static func score() -> String {
        let measures = (1...8).map { number in
            let attributes = number == 1
                ? """
                  <attributes>
                    <divisions>4</divisions>
                    <key><fifths>0</fifths></key>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                    <clef><sign>G</sign><line>2</line></clef>
                  </attributes>
                  """
                : ""
            let notes = ["C", "D", "E", "F"].map { step in
                """
                <note>
                  <pitch><step>\(step)</step><octave>5</octave></pitch>
                  <duration>4</duration><type>quarter</type>
                </note>
                """
            }.joined()
            return "<measure number=\"\(number)\">\(attributes)\(notes)</measure>"
        }.joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>Compare Fixture</work-title></work>
              <part-list>
                <score-part id="P1"><part-name>Flute</part-name></score-part>
              </part-list>
              <part id="P1">
            \(measures)
              </part>
            </score-partwise>
            """
    }

    private var store: LibraryStore {
        get throws { try XCTUnwrap(model.store) }
    }

    private func openPreparedPiece() async throws -> PlaybackModel {
        let source = directory.appending(path: "compare-fixture.musicxml")
        try Data(Self.score().utf8).write(to: source)

        let library = try XCTUnwrap(model.library, "The library model should exist once open")
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first, "The fixture should have imported")

        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback, "Opening a piece should make a transport")
        await playback.prepare()
        XCTAssertTrue(playback.assignment.isReady, "The piece should have resolved lines")
        return playback
    }

    /// The piece opened on its first preset, plus a second one — the reference —
    /// that differs in tempo (150%), expression and one line's volume, then
    /// switched back so the first is active again.
    private func pieceWithAReference() async throws -> (PlaybackModel, active: Preset, reference: Preset) {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment
        let original = try XCTUnwrap(assignment.activePreset)

        assignment.createPreset()
        assignment.cancelPresetRename()
        await playback.setTempoPercent(150)
        await playback.setExpressionEnabled(false)
        let line = try XCTUnwrap(assignment.lines.first?.lineID)
        assignment.setVolume(0.25, forLine: line)
        let referenceID = try XCTUnwrap(assignment.activePreset?.id)

        assignment.activate(presetID: original.id)
        await playback.settlePresetAdoption()
        XCTAssertEqual(playback.tempoPercent, 100)
        XCTAssertEqual(playback.expression, .standard)
        let active = try XCTUnwrap(assignment.activePreset)
        XCTAssertEqual(active.id, original.id)

        // Re-read, so the returned row is the stored one: inactive now.
        let reference = try XCTUnwrap(assignment.presets.first { $0.id == referenceID })
        XCTAssertEqual(reference.content.tempoPercent, 150)
        XCTAssertFalse(reference.isActive)
        assignment.chooseReference(presetID: reference.id)
        XCTAssertTrue(assignment.canCompare)
        return (playback, active, reference)
    }

    private func storedPresets(_ playback: PlaybackModel) throws -> [Preset] {
        try store.presets.presets(forPieceID: playback.piece.id)
    }

    private func seek(_ playback: PlaybackModel, toMeasure measure: String, beat: String) {
        playback.measureField = measure
        playback.beatField = beat
        playback.seekToTypedMeasure()
    }

    // MARK: Acceptance

    /// The issue's acceptance: while playing, Compare on and off keeps the
    /// playhead on the same measure and beat — although the reference plays at
    /// 150%, so the same beat is at a different second — and the presets on
    /// disk, the active flag included, are exactly as they were.
    func testTogglingWhilePlayingKeepsTheScorePositionAndChangesNothingOnDisk() async throws {
        let (playback, active, reference) = try await pieceWithAReference()
        let fileLength = playback.totalMicroseconds
        let before = try storedPresets(playback)

        seek(playback, toMeasure: "5", beat: "3")
        playback.play()
        let startMicroseconds = playback.positionMicroseconds
        XCTAssertEqual(playback.position?.measureNumber, "5")

        await playback.toggleCompare()
        XCTAssertTrue(playback.isComparing)
        XCTAssertTrue(playback.assignment.isComparing)
        XCTAssertEqual(playback.position?.measureNumber, "5", "Compare moved the playhead")
        XCTAssertEqual(try XCTUnwrap(playback.position?.beat), 3, accuracy: 0.1)
        XCTAssertEqual(
            Double(playback.positionMicroseconds), Double(startMicroseconds) * 100 / 150,
            accuracy: 50_000,
            "At 150% the same beat is two thirds as far in"
        )
        // The reference's whole performance is what is loaded…
        XCTAssertEqual(
            Double(playback.totalMicroseconds), Double(fileLength) * 100 / 150, accuracy: 1_000
        )
        XCTAssertFalse(try XCTUnwrap(playback.timeline).settings.expression.isEnabled)
        XCTAssertEqual(playback.assignment.audition?.preset.id, reference.id)
        // …while everything the owner edits still describes the active preset.
        XCTAssertEqual(playback.assignment.activePreset?.id, active.id)
        XCTAssertEqual(playback.tempoPercent, 100)
        XCTAssertEqual(playback.expression, .standard)

        await playback.toggleCompare()
        XCTAssertFalse(playback.isComparing)
        XCTAssertNil(playback.assignment.audition)
        XCTAssertEqual(playback.position?.measureNumber, "5", "Returning moved the playhead")
        XCTAssertEqual(try XCTUnwrap(playback.position?.beat), 3, accuracy: 0.1)
        XCTAssertEqual(
            Double(playback.positionMicroseconds), Double(startMicroseconds), accuracy: 50_000
        )
        XCTAssertEqual(playback.totalMicroseconds, fileLength)
        XCTAssertTrue(try XCTUnwrap(playback.timeline).settings.expression.isEnabled)

        XCTAssertEqual(try storedPresets(playback), before, "Compare wrote to a preset")
        XCTAssertEqual(try store.presets.activePreset(forPieceID: playback.piece.id)?.id, active.id)
        playback.stop()
    }

    // MARK: When Compare is unavailable

    func testWithoutAUsableReferenceCompareRefusesAndSaysWhy() async throws {
        let playback = try await openPreparedPiece()
        let assignment = playback.assignment

        await playback.toggleCompare()
        XCTAssertFalse(playback.isComparing)
        XCTAssertEqual(playback.statusMessage, "Choose a reference preset to compare with first.")

        // The active preset is no reference for itself.
        let active = try XCTUnwrap(assignment.activePreset)
        assignment.chooseReference(presetID: active.id)
        XCTAssertFalse(assignment.canCompare)
        await playback.toggleCompare()
        XCTAssertFalse(playback.isComparing)
        XCTAssertEqual(
            playback.statusMessage,
            "“\(active.name)” is the active preset — choose another one to compare with."
        )
    }

    // MARK: What ends Compare

    /// An edit lands on — and is heard as — the active preset: Compare ends
    /// first, and the reference is left exactly as stored.
    func testAMixerEditEndsCompareAndIsWrittenToTheActivePreset() async throws {
        let (playback, active, reference) = try await pieceWithAReference()
        let line = try XCTUnwrap(playback.assignment.lines.first?.lineID)

        await playback.toggleCompare()
        XCTAssertTrue(playback.isComparing)

        playback.assignment.setVolume(0.5, forLine: line)
        XCTAssertFalse(playback.isComparing, "An edit during Compare must end it first")
        let stored = try storedPresets(playback)
        XCTAssertEqual(
            stored.first { $0.id == active.id }?.line(withID: line)?.mixer.volume, 0.5
        )
        XCTAssertEqual(stored.first { $0.id == reference.id }, reference, "The reference moved")
        XCTAssertEqual(playback.tempoPercent, 100)
        XCTAssertEqual(playback.totalMicroseconds, try XCTUnwrap(playback.navigator).totalMicroseconds)
    }

    /// A performance-setting edit likewise ends Compare before it writes.
    func testATempoEditEndsCompareAndLeavesTheReferenceAlone() async throws {
        let (playback, active, reference) = try await pieceWithAReference()

        await playback.toggleCompare()
        await playback.setTempoPercent(80)
        XCTAssertFalse(playback.isComparing)
        let stored = try storedPresets(playback)
        XCTAssertEqual(stored.first { $0.id == active.id }?.content.tempoPercent, 80)
        XCTAssertEqual(stored.first { $0.id == reference.id }, reference)
    }

    /// Activating ends Compare, and activating the reference itself makes it
    /// unavailable — there is nothing left to compare it with.
    func testActivatingEndsCompare() async throws {
        let (playback, _, reference) = try await pieceWithAReference()

        await playback.toggleCompare()
        playback.assignment.activate(presetID: reference.id)
        XCTAssertFalse(playback.isComparing)
        XCTAssertFalse(playback.assignment.canCompare)
    }

    /// A deleted reference is forgotten, and Compare ends with it.
    func testDeletingTheReferenceEndsCompareAndClearsIt() async throws {
        let (playback, _, reference) = try await pieceWithAReference()

        await playback.toggleCompare()
        playback.assignment.confirmPresetDeletion(of: reference)
        XCTAssertFalse(playback.isComparing)
        XCTAssertNil(playback.assignment.referencePresetID)
        XCTAssertFalse(playback.assignment.canCompare)
    }

    /// Export always renders the active preset (D5): opening the sheet ends
    /// Compare, so the timeline the request reads is the active one.
    func testExportEndsCompareSoItRendersTheActivePreset() async throws {
        let (playback, _, _) = try await pieceWithAReference()
        let fileLength = playback.totalMicroseconds

        await playback.toggleCompare()
        XCTAssertNotEqual(playback.totalMicroseconds, fileLength)
        playback.export.present()
        XCTAssertFalse(playback.isComparing)
        XCTAssertEqual(playback.totalMicroseconds, fileLength)
        XCTAssertEqual(try XCTUnwrap(playback.timeline).settings.expression, .standard)
        playback.export.isPresented = false
    }

    /// Stems follow the same rule (#90, D5): opening the stems sheet, and
    /// starting a stem render, each end Compare, so the request is built from
    /// the active preset's timeline.
    func testStemExportEndsCompareSoItRendersTheActivePreset() async throws {
        let (playback, _, _) = try await pieceWithAReference()
        let fileLength = playback.totalMicroseconds

        await playback.toggleCompare()
        XCTAssertTrue(playback.isComparing)
        playback.stemExport.present()
        XCTAssertFalse(playback.isComparing, "Opening the stems sheet left Compare on.")
        XCTAssertEqual(playback.totalMicroseconds, fileLength)
        XCTAssertEqual(try XCTUnwrap(playback.timeline).settings.expression, .standard)

        // Compare turned back on with the sheet open: starting the render ends it.
        await playback.toggleCompare()
        XCTAssertTrue(playback.isComparing)
        let folder = directory.appending(path: "stems-compare")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        playback.stemExport.start(in: folder)
        XCTAssertFalse(playback.isComparing, "Starting a stem render left Compare on.")
        XCTAssertEqual(playback.totalMicroseconds, fileLength)
        playback.stemExport.cancel()
        for _ in 0..<600 where playback.stemExport.isExporting {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        playback.stemExport.isPresented = false
    }

    /// Choosing another reference while comparing ends Compare rather than
    /// silently playing something else.
    func testChangingTheReferenceEndsCompare() async throws {
        let (playback, _, _) = try await pieceWithAReference()

        await playback.toggleCompare()
        playback.assignment.chooseReference(presetID: nil)
        XCTAssertFalse(playback.isComparing)
        XCTAssertNil(playback.assignment.referencePresetID)
    }
}
