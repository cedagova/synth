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
