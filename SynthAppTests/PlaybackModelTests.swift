import XCTest
@testable import Synth
import SynthKit

/// `PlaybackModel` directly: preparing a piece, the transport's seeks, loops
/// and measure stepping, and the tempo and performance-setting changes — plus
/// what the owner is told when a piece cannot be prepared or a setting cannot
/// be saved (issue #99).
///
/// Reading the active preset during `prepare()` is covered for the case #95
/// is about — a saved preset that exists but cannot be read. Adopting a
/// switched preset's settings is #96's, tested alongside that change.
///
/// **No audio output.** Nothing here presses Play: every transport assertion is
/// about where the model put the playhead and what it said, which is what the
/// readout and the status bar show. Assertions that read the playhead are made
/// synchronously after the action, with no suspension point in between, so the
/// model's own ticker cannot interleave; and while the graph is not running a
/// seek never settles, so the ticker leaves the model's intended position alone
/// anyway.
@MainActor
final class PlaybackModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var piece: PieceRecord!
    private var playback: PlaybackModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        piece = try library.importPiece(
            musicXML: ModelFixtures.score(title: "Four Bars", parts: ["Flute"], measures: 4)
        )
        playback = PlaybackModel(piece: piece, store: library.store)
    }

    override func tearDown() async throws {
        playback?.close()
        playback = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private func prepared() async throws -> PlaybackModel {
        await playback.prepare()
        XCTAssertTrue(playback.isReady, "The fixture should prepare: \(playback.loadState)")
        return playback
    }

    private func storedTempo() throws -> Int? {
        try library.store.presets.activePreset(forPieceID: piece.id)?.content.tempoPercent
    }

    // MARK: Preparing

    func testPreparingAPieceMakesItReady() async throws {
        let playback = try await prepared()

        XCTAssertEqual(playback.loadState, .ready)
        XCTAssertTrue(
            playback.statusMessage?.hasPrefix("Ready — 4 measures") == true,
            String(describing: playback.statusMessage)
        )
        XCTAssertNotNil(playback.timeline)
        XCTAssertGreaterThan(playback.totalMicroseconds, 0)
        XCTAssertTrue(playback.assignment.isReady, "The preset goes on once the program exists")
        XCTAssertEqual(playback.measureText, "1")
    }

    /// The failure path: the piece's stored score has gone, so the transport
    /// says it cannot play rather than showing an empty, silent piece — and the
    /// transport's commands do nothing.
    func testAPieceWhoseScoreIsMissingFailsToPrepareAndSaysWhy() async throws {
        let content = library.store.container.piecesURL.appending(path: piece.contentFileName)
        try FileManager.default.removeItem(at: content)

        await playback.prepare()

        guard case .failed(let failure) = playback.loadState else {
            return XCTFail("Expected a failed load, got \(playback.loadState)")
        }
        XCTAssertFalse(failure.summary.isEmpty, "The failure is described to the owner")
        XCTAssertFalse(playback.isReady)
        XCTAssertNil(playback.statusMessage)

        playback.play()
        playback.stop()
        XCTAssertNil(playback.statusMessage, "A piece that did not prepare has no transport")
        XCTAssertFalse(playback.isPlaying)
    }

    func testASeekAskedForBeforeThePieceIsReadyWaitsForIt() async throws {
        playback.seek(toMicroseconds: 1_000_000)
        XCTAssertEqual(playback.statusMessage, "Will jump there once the piece is ready.")

        let playback = try await prepared()
        XCTAssertTrue(
            playback.statusMessage?.hasPrefix("Jumped to") == true,
            "The queued seek runs once the piece is ready: \(String(describing: playback.statusMessage))"
        )
    }

    func testAMeasureAskedForBeforeThePieceIsReadyWaitsForIt() async throws {
        playback.measureField = "3"
        playback.seekToTypedMeasure()
        XCTAssertEqual(playback.statusMessage, "Will jump to measure 3 once the piece is ready.")

        let playback = try await prepared()
        XCTAssertTrue(playback.statusMessage?.hasPrefix("Jumped to") == true)
    }

    // MARK: Seeking

    func testTypingAMeasureJumpsToIt() async throws {
        let playback = try await prepared()
        playback.measureField = "3"
        playback.beatField = "1"
        playback.seekToTypedMeasure()

        XCTAssertEqual(playback.measureText, "3")
        XCTAssertTrue(playback.statusMessage?.hasPrefix("Jumped to") == true)
    }

    func testATypedMeasureOrBeatThatDoesNotExistIsRefused() async throws {
        let playback = try await prepared()

        playback.measureField = ""
        playback.seekToTypedMeasure()
        XCTAssertEqual(playback.statusMessage, "Type a measure number to jump to.")

        playback.measureField = "99"
        playback.seekToTypedMeasure()
        XCTAssertEqual(playback.statusMessage, "This piece has no measure “99”.")

        playback.measureField = "2"
        playback.beatField = "x"
        playback.seekToTypedMeasure()
        XCTAssertEqual(playback.statusMessage, "“x” is not a beat. Beats start at 1.")
        XCTAssertEqual(playback.measureText, "1", "A refused jump leaves the playhead alone")
    }

    func testTypingATimeJumpsToItAndNonsenseIsRefused() async throws {
        let playback = try await prepared()

        playback.timeField = "0:02"
        playback.seekToTypedTime()
        XCTAssertEqual(playback.positionMicroseconds, 2_000_000)

        playback.timeField = "soon"
        playback.seekToTypedTime()
        XCTAssertEqual(playback.statusMessage, "“soon” is not a time. Try 1:23 or 83.4.")
        XCTAssertEqual(playback.positionMicroseconds, 2_000_000)
    }

    func testSkipsAreClampedInsideThePieceAndStartAndStopRewind() async throws {
        let playback = try await prepared()

        playback.skip(byMicroseconds: -5_000_000)
        XCTAssertEqual(playback.positionMicroseconds, 0)

        playback.skip(byMicroseconds: .max / 2)
        XCTAssertEqual(playback.positionMicroseconds, playback.totalMicroseconds)
        XCTAssertEqual(playback.statusMessage, "Jumped to the end of the piece.")

        playback.goToStart()
        XCTAssertEqual(playback.positionMicroseconds, 0)
        XCTAssertEqual(playback.statusMessage, "At the start.")

        playback.skip(byMicroseconds: PlaybackModel.skipMicroseconds)
        playback.stop()
        XCTAssertEqual(playback.positionMicroseconds, 0)
        XCTAssertEqual(playback.statusMessage, "Stopped.")
    }

    func testSteppingMeasures() async throws {
        let playback = try await prepared()

        playback.stepMeasure(by: 1)
        XCTAssertEqual(playback.measureText, "2")
        playback.stepMeasure(by: 1)
        XCTAssertEqual(playback.measureText, "3")
        playback.stepMeasure(by: -1)
        XCTAssertEqual(playback.measureText, "2")
        playback.stepMeasure(by: -10)
        XCTAssertEqual(playback.measureText, "1", "Clamped at the first measure")
    }

    func testEditingAReadoutSegmentReplacesJustThatPart() async throws {
        let playback = try await prepared()

        playback.segmentDraft = "3"
        playback.commitSegment(.measure)
        XCTAssertEqual(playback.measureText, "3")

        playback.segmentDraft = "1"
        playback.commitSegment(.seconds)
        XCTAssertEqual(playback.positionMicroseconds, 1_000_000)

        XCTAssertEqual(PlaybackModel.sanitizedDraft("1a2.3.4", for: .beat), "12.3")
        XCTAssertEqual(PlaybackModel.sanitizedDraft("123", for: .seconds), "12")
    }

    // MARK: Looping

    func testALoopFromTheFieldsMovesThePlayheadIntoIt() async throws {
        let playback = try await prepared()
        playback.loopFromField = "2"
        playback.loopToField = "3"

        playback.setLoopFromFields()

        XCTAssertTrue(playback.isLooping)
        XCTAssertTrue(playback.statusMessage?.hasPrefix("Looping") == true)
        XCTAssertEqual(playback.measureText, "2", "The loop starts from its beginning")
        XCTAssertNotNil(playback.loopDescription)

        playback.toggleLoop()
        XCTAssertFalse(playback.isLooping)
        XCTAssertEqual(playback.statusMessage, "Loop off.")
    }

    func testALoopThatNamesNoRangeIsRefused() async throws {
        let playback = try await prepared()

        playback.loopFromField = ""
        playback.loopToField = "3"
        playback.setLoopFromFields()
        XCTAssertEqual(playback.statusMessage, "A loop needs a first and a last measure.")

        playback.loopFromField = "3"
        playback.loopToField = "2"
        playback.setLoopFromFields()
        XCTAssertFalse(playback.isLooping)
        XCTAssertTrue(playback.statusMessage?.hasPrefix("No loop from measure 3 to measure 2") == true)
    }

    func testCapturingTheLoopEndsFromThePlayhead() async throws {
        let playback = try await prepared()
        playback.stepMeasure(by: 1)

        playback.captureLoopStart()
        XCTAssertEqual(playback.loopFromField, "2")
        XCTAssertFalse(playback.isLooping, "Only the start is marked so far")

        playback.stepMeasure(by: 1)
        playback.captureLoopEnd()
        XCTAssertEqual(playback.loopToField, "3")
        XCTAssertTrue(playback.isLooping)
    }

    // MARK: Tempo (REQ-009) and performance settings

    func testChangingTheTempoRescalesAndIsSaved() async throws {
        let playback = try await prepared()
        let total = playback.totalMicroseconds

        await playback.setTempoPercent(50)

        XCTAssertEqual(playback.tempoPercent, 50)
        XCTAssertEqual(playback.tempoDraft, 50)
        XCTAssertGreaterThan(playback.totalMicroseconds, total, "Half the tempo is a longer piece")
        XCTAssertEqual(try storedTempo(), 50)
        XCTAssertEqual(
            playback.statusMessage, "Tempo 50% — ♩=120 becomes ♩=60.",
            "Named against the score's own marking, not the rescaled one"
        )

        await playback.nudgeTempo(by: 5)
        XCTAssertEqual(playback.tempoPercent, 55)

        await playback.resetTempo()
        XCTAssertEqual(playback.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertEqual(playback.statusMessage, "Tempo back to the score's own.")
        XCTAssertEqual(try storedTempo(), TempoMap.defaultTempoPercent)
    }

    func testATempoOutsideTheRangeIsClamped() async throws {
        let playback = try await prepared()
        await playback.setTempoPercent(10_000)
        XCTAssertEqual(playback.tempoPercent, PresetContent.clampedTempo(10_000))
    }

    /// The failure path: the change still applies to what is playing, and the
    /// owner is told it could not be saved.
    func testATempoTheStoreCannotSaveStillAppliesAndIsReported() async throws {
        let playback = try await prepared()
        let before = try storedTempo()
        try library.failWrites(.update, on: PresetCatalog.tableName)

        await playback.setTempoPercent(70)

        XCTAssertEqual(playback.tempoPercent, 70, "The session plays the owner's tempo")
        XCTAssertEqual(playback.assignment.alert?.title, "Could not save the tempo change")
        XCTAssertEqual(try storedTempo(), before)
    }

    func testPerformanceSettingsApplyAndSave() async throws {
        let playback = try await prepared()

        await playback.setHumanizationEnabled(false)
        XCTAssertFalse(playback.humanization.isEnabled)
        XCTAssertFalse(try XCTUnwrap(playback.timeline).settings.humanization.isEnabled)

        await playback.setProducedMasterEnabled(false)
        XCTAssertEqual(playback.producedMaster, .off)

        await playback.setTemperament(.werckmeisterIII)
        XCTAssertEqual(playback.tuning.temperament, .werckmeisterIII)
        XCTAssertEqual(playback.loadedProgramTuning?.temperament, .werckmeisterIII)

        let stored = try XCTUnwrap(
            library.store.presets.activePreset(forPieceID: piece.id)
        ).content
        XCTAssertFalse(stored.humanization.isEnabled)
        XCTAssertEqual(stored.producedMaster, .off)
        XCTAssertEqual(stored.tuning.temperament, .werckmeisterIII)
        XCTAssertNil(playback.assignment.alert)
    }

    // MARK: An unreadable saved preset (#95)

    /// Opens the fixture once so it has a saved preset, then damages that row
    /// and returns what it now holds.
    private func damageTheSavedPreset() async throws -> [String] {
        _ = try await prepared()
        let saved = try XCTUnwrap(library.store.presets.activePreset(forPieceID: piece.id))
        playback.close()
        try library.corruptDocument(inTable: PresetCatalog.tableName, id: saved.id)
        XCTAssertThrowsError(
            try library.store.presets.activePreset(forPieceID: piece.id),
            "The fixture has to be a preset the store cannot read"
        )
        playback = PlaybackModel(piece: piece, store: library.store)
        return try library.storedPresetRows(forPieceID: piece.id)
    }

    /// The issue's acceptance test: the piece plays under the standard
    /// settings, the owner is told which piece and why — in the banner, not a
    /// modal — and the stored row is not written, even when the owner changes a
    /// setting that would ordinarily be auto-saved.
    func testAnUnreadableSavedPresetPlaysUnderStandardSettingsAndIsReportedNotOverwritten()
        async throws
    {
        let damaged = try await damageTheSavedPreset()

        let playback = try await prepared()
        await playback.settlePresetAdoption()

        XCTAssertEqual(playback.humanization, .standard)
        XCTAssertEqual(playback.expression, .standard)
        XCTAssertEqual(playback.producedMaster, .standard)
        XCTAssertEqual(playback.tuning, .standard)
        XCTAssertEqual(playback.tempoPercent, TempoMap.defaultTempoPercent)

        let unreadable = try XCTUnwrap(playback.assignment.unreadablePreset)
        XCTAssertTrue(unreadable.banner.contains("“Four Bars”"), unreadable.banner)
        XCTAssertTrue(unreadable.banner.contains("standard settings"), unreadable.banner)
        XCTAssertTrue(
            unreadable.banner.contains("could not read the preset"),
            "The banner carries the store's own reason: \(unreadable.banner)"
        )
        XCTAssertNil(playback.assignment.alert, "One message, not a banner and an alert")
        XCTAssertNil(playback.assignment.activePreset)

        // Coming back from the studio re-reads the store; an owner edit would
        // ordinarily auto-save. Neither may touch the damaged row.
        await playback.prepare()
        await playback.setTempoPercent(70)
        await playback.setHumanizationEnabled(false)
        XCTAssertEqual(try library.storedPresetRows(forPieceID: piece.id), damaged)
        XCTAssertEqual(try library.store.presets.presetCount(forPieceID: piece.id), 1)
    }

    /// A preset that becomes unreadable while the piece is open is re-read on
    /// the way back from the studio, and the standard settings replace the ones
    /// it had — through the same adoption path any preset's settings take, so
    /// what plays is what the banner says.
    func testAPresetThatBecomesUnreadableIsReplacedByStandardSettingsOnReRead() async throws {
        let playback = try await prepared()
        await playback.setTempoPercent(70)
        await playback.settlePresetAdoption()
        XCTAssertEqual(playback.tempoPercent, 70)
        let saved = try XCTUnwrap(library.store.presets.activePreset(forPieceID: piece.id))

        try library.corruptDocument(inTable: PresetCatalog.tableName, id: saved.id)
        let damaged = try library.storedPresetRows(forPieceID: piece.id)
        await playback.prepare()
        await playback.settlePresetAdoption()

        XCTAssertEqual(playback.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertNotNil(playback.assignment.unreadablePreset)
        XCTAssertNil(playback.assignment.alert)
        XCTAssertEqual(try library.storedPresetRows(forPieceID: piece.id), damaged)
    }

    /// "No preset yet" is the ordinary first open: standard settings, and
    /// nothing to report.
    func testAPieceWithNoPresetYetOpensSilentlyUnderStandardSettings() async throws {
        XCTAssertNil(try library.store.presets.activePreset(forPieceID: piece.id))

        let playback = try await prepared()

        XCTAssertEqual(playback.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertEqual(playback.humanization, .standard)
        XCTAssertNil(playback.assignment.unreadablePreset)
        XCTAssertNil(playback.assignment.alert)
        XCTAssertNotNil(playback.assignment.activePreset, "The first preset is created")
    }

    func testFocusRequestsAreCounted() async throws {
        let playback = try await prepared()
        let measure = playback.measureFocusRequests
        let time = playback.timeFocusRequests
        playback.requestMeasureFocus()
        playback.requestTimeFocus()
        XCTAssertEqual(playback.measureFocusRequests, measure + 1)
        XCTAssertEqual(playback.timeFocusRequests, time + 1)
    }
}
