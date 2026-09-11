import XCTest
@testable import Synth
import SynthKit

/// The join between the Performance settings group and the realized timeline,
/// at the level where it is actually made (P65-6, REQ-003, REQ-012).
///
/// **This suite exists for the reason `ExportWiringTests` exists.** Both ends of
/// the expression setting are proved elsewhere — `PerformanceExpressionTests`
/// proves the realizer shapes and bypasses, `PresetExpressionTests` proves the
/// document stores and defaults — and neither would notice if the line joining
/// them were deleted. What only this suite can prove is that moving the control
/// re-renders *this* piece, writes to *this* piece's preset, announces itself,
/// and that a preset switch adopts the arriving value without writing it back.
///
/// Everything runs against a real store in a temporary container, driven through
/// the same methods the group's controls and the menu items call.
@MainActor
final class PerformanceSettingsWiringTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "PerformanceSettingsWiringTests-\(UUID().uuidString)")
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

    /// Eight measures of three quarter notes and a rest: every measure is one
    /// phrase, so the setting has something to do.
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
                  <direction><direction-type><dynamics><mp/></dynamics></direction-type></direction>
                  """
                : ""
            let notes = ["C", "D", "E"].map { step in
                """
                <note>
                  <pitch><step>\(step)</step><octave>5</octave></pitch>
                  <duration>4</duration><type>quarter</type>
                </note>
                """
            }.joined()
            return """
                <measure number="\(number)">\(attributes)\(notes)
                  <note><rest/><duration>4</duration><type>quarter</type></note>
                </measure>
                """
        }.joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>Phrase Fixture</work-title></work>
              <part-list>
                <score-part id="P1"><part-name>Flute</part-name></score-part>
              </part-list>
              <part id="P1">
            \(measures)
              </part>
            </score-partwise>
            """
    }

    @discardableResult
    private func openPreparedPiece() async throws -> PlaybackModel {
        let source = directory.appending(path: "phrase-fixture.musicxml")
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

    private func velocities(_ playback: PlaybackModel) throws -> [Int] {
        try XCTUnwrap(playback.timeline).lines.flatMap { $0.events.map(\.velocity) }
    }

    // MARK: Opening

    /// A fresh piece opens with expression on, and the timeline it is playing
    /// says so — which is where owner decision D65-3 actually reaches the ear.
    func testAPieceOpensWithExpressionOnAndRealizesUnderIt() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertEqual(playback.expression, .standard)
        XCTAssertEqual(playback.expressionAmountDraft, Double(ExpressionSettings.standard.amount))
        XCTAssertEqual(
            playback.assignment.activePreset?.content.expression, .standard,
            "the piece's first preset should store the setting it is playing under"
        )
        XCTAssertEqual(
            try XCTUnwrap(playback.timeline).settings.expression, .standard,
            "the realization has to be the one the setting asks for, not the default of the type"
        )
        XCTAssertGreaterThan(
            Set(try velocities(playback)).count, 1,
            "one written dynamic and no phrase shaping would give one velocity throughout"
        )
    }

    /// A preset that stores expression off opens playing it off. With
    /// `PresetExpressionTests`'s decode default, this is the whole D65-3 path: a
    /// stored value reaches the realization, and a document with no value reads
    /// as on.
    func testAStoredSettingIsWhatThePieceOpensUnder() async throws {
        let playback = try await openPreparedPiece()
        let store = try XCTUnwrap(model.store)
        let preset = try XCTUnwrap(playback.assignment.activePreset)
        try store.presets.setExpression(.off, in: preset)

        model.closePlayback()
        model.openPlayback(for: playback.piece)
        let reopened = try XCTUnwrap(model.playback)
        await reopened.prepare()

        XCTAssertEqual(reopened.expression, .off)
        XCTAssertEqual(
            try XCTUnwrap(reopened.timeline).settings.expression, .off,
            "the stored setting did not reach the realization"
        )
        // With the other setting off too, only the written `mp` is left, which
        // is REQ-004's recipe reached through the stored preset rather than
        // through a realizer call.
        await reopened.setHumanizationEnabled(false)
        XCTAssertEqual(
            Set(try velocities(reopened)).count, 1,
            "with both settings off and one written dynamic, every note should be at that dynamic"
        )
    }

    // MARK: Changing a setting re-renders and saves

    /// The acceptance clause, end to end: toggling re-renders and saves, exactly
    /// as humanization does.
    func testTogglingExpressionReRendersTheTimelineAndSavesToThePreset() async throws {
        let playback = try await openPreparedPiece()
        let shaped = try velocities(playback)
        let revision = try XCTUnwrap(playback.assignment.activePreset?.revision)

        await playback.setExpressionEnabled(false)

        XCTAssertFalse(playback.expression.isEnabled)
        XCTAssertEqual(try XCTUnwrap(playback.timeline).settings.expression.isEnabled, false)
        XCTAssertNotEqual(try velocities(playback), shaped, "the piece was not re-rendered")
        XCTAssertLessThan(
            try spread(velocities(playback)), try spread(shaped),
            "expression off should leave less variation than expression on — only the written "
                + "dynamic and the uniform humanization"
        )
        XCTAssertEqual(
            playback.assignment.activePreset?.content.expression.isEnabled, false,
            "the change was not saved to the preset"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(playback.assignment.activePreset?.revision), revision,
            "a save that did not bump the revision did not happen"
        )
        XCTAssertEqual(
            playback.statusMessage, PlaybackModel.expressionMessage(.off),
            "the change has to be announced, or the group is unusable without seeing it"
        )

        // And back on: the first timeline returns, because realization is a
        // pure function of the same inputs.
        await playback.setExpressionEnabled(true)
        XCTAssertEqual(try velocities(playback), shaped, "turning it back on did not restore it")
    }

    /// The amount slider's commit, which is the drag-end call the control makes.
    func testCommittingTheAmountReRendersAndSaves() async throws {
        let playback = try await openPreparedPiece()
        let atDefault = try velocities(playback)

        playback.expressionAmountDraft = 100
        await playback.commitExpressionAmount()

        XCTAssertEqual(playback.expression.amount, 100)
        XCTAssertEqual(playback.assignment.activePreset?.content.expression.amount, 100)
        XCTAssertNotEqual(try velocities(playback), atDefault, "the amount changed nothing")

        let fullSpread = try spread(velocities(playback))
        XCTAssertGreaterThan(
            fullSpread, try spread(atDefault), "a larger amount should shape further"
        )

        // A commit that does not move the value must not re-render: every
        // re-render stops the graph for an instant.
        let before = try velocities(playback)
        playback.expressionAmountDraft = 100
        await playback.commitExpressionAmount()
        XCTAssertEqual(try velocities(playback), before)
    }

    private func spread(_ velocities: [Int]) throws -> Int {
        let highest = try XCTUnwrap(velocities.max())
        let lowest = try XCTUnwrap(velocities.min())
        return highest - lowest
    }

    /// The change keeps the playhead, which is the shared re-realization path's
    /// one subtle promise — and the one a second copy of that path would break.
    func testChangingASettingKeepsThePlayhead() async throws {
        let playback = try await openPreparedPiece()
        playback.seek(toMicroseconds: 4_000_000)
        let position = playback.positionMicroseconds
        XCTAssertGreaterThan(position, 0, "the seek has to have moved somewhere")

        await playback.setExpressionEnabled(false)
        XCTAssertEqual(
            playback.positionMicroseconds, position,
            "the expression change restarted the piece"
        )

        await playback.setHumanizationEnabled(false)
        XCTAssertEqual(
            playback.positionMicroseconds, position,
            "the humanization change restarted the piece — a regression from before this group"
        )
    }

    // MARK: No regression in humanization

    /// The group's other acceptance clause: humanization still behaves exactly
    /// as it did, including being saved and announced.
    func testHumanizationStillReRendersSavesAndAnnounces() async throws {
        let playback = try await openPreparedPiece()
        let revision = try XCTUnwrap(playback.assignment.activePreset?.revision)

        await playback.setHumanizationEnabled(false)
        XCTAssertFalse(playback.humanization.isEnabled)
        XCTAssertTrue(try XCTUnwrap(playback.timeline).settings.humanization.isLiteral)
        XCTAssertEqual(playback.assignment.activePreset?.content.humanization.isEnabled, false)
        XCTAssertGreaterThan(try XCTUnwrap(playback.assignment.activePreset?.revision), revision)
        XCTAssertEqual(playback.statusMessage, "Humanization off — playing exactly as written.")

        playback.intensityDraft = 90
        await playback.commitIntensity()
        XCTAssertEqual(playback.humanization.intensity, 90)
        XCTAssertEqual(playback.assignment.activePreset?.content.humanization.intensity, 90)
    }

    /// The two settings are independent: neither one's off state disturbs the
    /// other's value, which is what REQ-004's recipe needs in order to name one
    /// term at a time.
    func testTheTwoSettingsAreIndependent() async throws {
        let playback = try await openPreparedPiece()

        await playback.setExpressionEnabled(false)
        XCTAssertEqual(playback.humanization, .standard, "expression moved the humanization")
        XCTAssertTrue(playback.humanization.isEnabled)

        await playback.setHumanizationEnabled(false)
        XCTAssertEqual(
            playback.expression.amount, ExpressionSettings.standard.amount,
            "humanization moved the expression amount"
        )
        let both = try XCTUnwrap(playback.timeline).settings
        XCTAssertTrue(both.humanization.isLiteral)
        XCTAssertFalse(both.expression.isEnabled)
    }

    // MARK: Switching presets

    /// The `onExpressionLoaded` closure, which nothing else would notice the
    /// loss of: an arriving preset's setting is played, and not written back
    /// over the preset that is arriving.
    func testSwitchingPresetsAdoptsTheArrivingSettingWithoutWritingItBack() async throws {
        let playback = try await openPreparedPiece()
        await playback.setExpressionEnabled(false)

        // A second preset, which starts as a copy and is then given expression
        // back at a distinctive amount.
        playback.assignment.createPreset()
        let second = try XCTUnwrap(playback.assignment.activePreset)
        let wanted = ExpressionSettings(isEnabled: true, amount: 85)
        let store = try XCTUnwrap(model.store)
        try store.presets.setExpression(wanted, in: second)
        playback.assignment.refreshFromStore()
        try await waitForExpression(wanted, on: playback)

        XCTAssertEqual(playback.expression, wanted, "the arriving preset's setting was not adopted")
        XCTAssertEqual(playback.expressionAmountDraft, 85, "and the slider did not follow it")
        XCTAssertEqual(
            try XCTUnwrap(playback.timeline).settings.expression, wanted,
            "adopting a setting has to re-realize, or the piece plays the old one"
        )
        let reread = try XCTUnwrap(
            store.presets.presets(forPieceID: playback.piece.id).first { $0.id == second.id }
        )
        XCTAssertEqual(
            reread.content.expression, wanted,
            "adopting a preset's own value must not write it back over the preset"
        )
    }

    // MARK: The produced master (REQ-005, MST001)

    /// A fresh piece opens with the produced master on and the engine levelling
    /// it — the other half of D65-3 reaching the ear.
    func testAPieceOpensWithTheProducedMasterOnAndTheProgramMeasured() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertEqual(playback.producedMaster, .standard)
        XCTAssertEqual(
            playback.assignment.activePreset?.content.producedMaster, .standard,
            "the piece's first preset should store the setting it is playing under"
        )
        let calibration = try XCTUnwrap(
            playback.masterCalibration,
            "the engine never measured the program, so nothing is being levelled"
        )
        XCTAssertEqual(calibration.outcome, .calibrated)
        XCTAssertNotEqual(calibration.gain, 1, "the measurement produced no gain at all")
    }

    /// Toggling the row applies the change, saves it, and announces it — and does
    /// it *without* re-realizing the piece, which is the one way this row
    /// deliberately differs from the three above it.
    func testTogglingTheProducedMasterSavesAndAnnouncesWithoutReRealizing() async throws {
        let playback = try await openPreparedPiece()
        let timeline = try XCTUnwrap(playback.timeline)
        let revision = try XCTUnwrap(playback.assignment.activePreset?.revision)

        await playback.setProducedMasterEnabled(false)

        XCTAssertFalse(playback.producedMaster.isEnabled)
        XCTAssertEqual(
            playback.assignment.activePreset?.content.producedMaster, .off,
            "the change was not saved to the preset"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(playback.assignment.activePreset?.revision), revision,
            "a save that did not bump the revision did not happen"
        )
        let after = try XCTUnwrap(playback.timeline)
        XCTAssertEqual(
            try after.canonicalData(), try timeline.canonicalData(),
            "the produced master re-realized the timeline; it changes the bus, not the notes"
        )
        XCTAssertEqual(
            playback.statusMessage,
            PlaybackModel.producedMasterMessage(.off, calibration: playback.masterCalibration),
            "the change has to be announced, or the group is unusable without seeing it"
        )

        await playback.setProducedMasterEnabled(true)
        XCTAssertTrue(playback.producedMaster.isEnabled)
        XCTAssertEqual(playback.assignment.activePreset?.content.producedMaster, .standard)
    }

    /// A preset that stores the produced master off opens with it off.
    func testAStoredProducedMasterIsWhatThePieceOpensUnder() async throws {
        let playback = try await openPreparedPiece()
        let store = try XCTUnwrap(model.store)
        let preset = try XCTUnwrap(playback.assignment.activePreset)
        try store.presets.setProducedMaster(.off, in: preset)

        model.closePlayback()
        model.openPlayback(for: playback.piece)
        let reopened = try XCTUnwrap(model.playback)
        await reopened.prepare()

        XCTAssertEqual(reopened.producedMaster, .off)
        XCTAssertNil(
            reopened.masterCalibration,
            "the piece opened with the produced master off, so it should not have paid for a "
                + "measurement at all"
        )
    }

    // MARK: Tuning (REQ-006, TUN001)

    /// A fresh piece opens at equal temperament and A=440 — the identity, which is
    /// REQ-006's default and therefore what a library of existing pieces keeps
    /// sounding like.
    func testAPieceOpensAtTheDefaultTuning() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertEqual(playback.tuning, .standard)
        XCTAssertTrue(playback.tuning.isDefault)
        XCTAssertEqual(
            playback.assignment.activePreset?.content.tuning, .standard,
            "the piece's first preset should store the tuning it is playing under"
        )
    }

    /// Picking a temperament applies it, rebuilds the program around the *same*
    /// notes, saves it to the preset, and announces it.
    ///
    /// **The three things only this suite can prove**, and the middle one is this
    /// row's own character: tuning changes neither the timeline (so the realized
    /// events are byte-identical afterwards) nor only the bus (so the program is a
    /// new one, carrying the new table into every voice).
    func testPickingATemperamentRebuildsTheProgramSavesAndAnnounces() async throws {
        let playback = try await openPreparedPiece()
        let timeline = try XCTUnwrap(playback.timeline)
        let revision = try XCTUnwrap(playback.assignment.activePreset?.revision)

        await playback.setTemperament(.werckmeisterIII)

        XCTAssertEqual(playback.tuning.temperament, .werckmeisterIII)
        XCTAssertEqual(
            playback.assignment.activePreset?.content.tuning,
            TuningSettings(temperament: .werckmeisterIII),
            "the change was not saved to the preset"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(playback.assignment.activePreset?.revision), revision,
            "a save that did not bump the revision did not happen"
        )
        let after = try XCTUnwrap(playback.timeline)
        XCTAssertEqual(
            try after.canonicalData(), try timeline.canonicalData(),
            "a tuning change re-realized the timeline; it changes what each note is tuned to, "
                + "not which notes there are"
        )
        XCTAssertEqual(
            playback.statusMessage,
            PlaybackModel.tuningMessage(TuningSettings(temperament: .werckmeisterIII)),
            "the change has to be announced, or the group is unusable without seeing it"
        )
    }

    /// And the reference-pitch row is its own control: it moves independently of the
    /// temperament and saves the pair.
    func testPickingAReferencePitchIsIndependentOfTheTemperament() async throws {
        let playback = try await openPreparedPiece()

        await playback.setReferencePitch(.a415)
        XCTAssertEqual(
            playback.tuning, TuningSettings(temperament: .equal, referencePitch: .a415)
        )

        await playback.setTemperament(.werckmeisterIII)
        XCTAssertEqual(
            playback.tuning,
            TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415),
            "picking a temperament discarded the reference pitch"
        )
        XCTAssertEqual(
            playback.assignment.activePreset?.content.tuning,
            TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        )

        await playback.setReferencePitch(.a440)
        XCTAssertEqual(
            playback.tuning, TuningSettings(temperament: .werckmeisterIII, referencePitch: .a440),
            "going back to concert pitch discarded the temperament"
        )
    }

    /// **A tuning change keeps the playhead.**
    ///
    /// This one caught a real defect and is here to stop it coming back. Every
    /// engine-level assertion was already true — `PlaybackEngine.setTuning` does
    /// carry the playhead across its rebuild — and the piece still restarted from
    /// the top, because putting the preset back re-seats the voices and that is a
    /// *second* rebuild: the engine's carry re-issues a seek, a seek lands when the
    /// render thread applies it, and the second rebuild therefore read zero. The
    /// position is held in the model now (`restorePlayback`), which is the only layer
    /// that knows the two rebuilds are one act.
    func testATuningChangeKeepsThePlayhead() async throws {
        let playback = try await openPreparedPiece()
        playback.seek(toMicroseconds: 4_000_000)
        let position = playback.positionMicroseconds
        XCTAssertGreaterThan(position, 0, "the seek has to have moved somewhere")

        await playback.setTemperament(.werckmeisterIII)
        XCTAssertEqual(
            playback.positionMicroseconds, position,
            "the temperament change restarted the piece"
        )

        await playback.setReferencePitch(.a415)
        XCTAssertEqual(
            playback.positionMicroseconds, position,
            "the reference-pitch change restarted the piece"
        )

        // And the mix survived both, which is the other thing the second rebuild
        // would have thrown away.
        XCTAssertEqual(
            playback.assignment.activePreset?.content.tuning,
            TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        )
    }

    /// A preset that stores a tuning opens under it, and the program the transport
    /// loaded is built with it.
    func testAStoredTuningIsWhatThePieceOpensUnder() async throws {
        let playback = try await openPreparedPiece()
        let store = try XCTUnwrap(model.store)
        let preset = try XCTUnwrap(playback.assignment.activePreset)
        let stored = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        try store.presets.setTuning(stored, in: preset)

        model.closePlayback()
        model.openPlayback(for: playback.piece)
        let reopened = try XCTUnwrap(model.playback)
        await reopened.prepare()

        XCTAssertEqual(reopened.tuning, stored)
        XCTAssertEqual(
            reopened.loadedProgramTuning, stored,
            "the piece opened under the stored tuning but built its program without it"
        )
    }

    /// A preset whose stored temperament this build does not know opens the piece —
    /// in equal temperament, with the sentence in the status bar.
    ///
    /// REQ-006's failure clause at the level the owner meets it: not a thrown error,
    /// not a silent line, a piece that plays and a status bar that explains.
    func testAnUnknownStoredTemperamentOpensThePieceAndIsReported() async throws {
        let playback = try await openPreparedPiece()
        let store = try XCTUnwrap(model.store)
        let preset = try XCTUnwrap(playback.assignment.activePreset)
        // Written the way a later version of the app would have written it.
        try store.presets.setTuning(
            TuningSettings(
                temperament: .equal, referencePitch: .a415,
                unrecognizedTemperament: "kirnberger-iii"
            ),
            in: preset
        )

        model.closePlayback()
        model.openPlayback(for: playback.piece)
        let reopened = try XCTUnwrap(model.playback)
        await reopened.prepare()

        XCTAssertTrue(reopened.isReady, "the piece must still open")
        XCTAssertEqual(reopened.tuning.temperament, .equal)
        XCTAssertEqual(reopened.tuning.referencePitch, .a415)
        let status = try XCTUnwrap(reopened.statusMessage)
        XCTAssertTrue(
            status.contains("kirnberger-iii"),
            "the owner is not told which temperament could not be read: “\(status)”"
        )
    }

    /// The adoption runs in a task off the closure, so it is awaited rather than
    /// assumed.
    private func waitForExpression(
        _ wanted: ExpressionSettings, on playback: PlaybackModel, timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while playback.expression != wanted, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
