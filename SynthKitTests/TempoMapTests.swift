import XCTest
@testable import SynthKit

/// The measure/beat ↔ elapsed-time mapping (REQ-009's basis) and the fermata
/// holds folded into it.
///
/// The numbers in these tests are worked out by hand in the comments, because
/// a timing test that only compares the code against itself proves nothing.
final class TempoMapTests: XCTestCase {
    private let compiler = ScoreCompiler()

    // MARK: Arithmetic

    func testBeatsPerMinuteConvertsToTheMIDIStyleTempoUnit() {
        XCTAssertEqual(TempoMap.microsecondsPerQuarter(beatsPerMinute: 120), 500_000)
        XCTAssertEqual(TempoMap.microsecondsPerQuarter(beatsPerMinute: 60), 1_000_000)
        XCTAssertEqual(TempoMap.microsecondsPerQuarter(beatsPerMinute: 72), 833_333)
    }

    func testAnImpossibleTempoIsRefusedRatherThanProducingInfinity() {
        XCTAssertNil(TempoMap.microsecondsPerQuarter(beatsPerMinute: 0))
        XCTAssertNil(TempoMap.microsecondsPerQuarter(beatsPerMinute: -40))
        XCTAssertNil(TempoMap.microsecondsPerQuarter(beatsPerMinute: .nan))
    }

    func testADottedMetronomeMarkCountsTheDot() throws {
        let element = try MusicXMLDocument.parse(
            Data(
                "<metronome><beat-unit>quarter</beat-unit><beat-unit-dot/>"
                    .appending("<per-minute>80</per-minute></metronome>").utf8
            )
        )
        // A dotted quarter at 80 is 120 quarter notes a minute.
        XCTAssertEqual(MusicXMLMetronome.microsecondsPerQuarter(element), 500_000)
    }

    func testAMetronomeMarkSetsTheTempoWhenNoSoundElementIsPresent() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .direction(ScoreXML.Direction(metronome: ("half", 30))),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compiler.compile(
            pieceID: "metronome-only",
            musicXML: ScoreXML.Score(
                parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]
            ).data()
        )
        // 30 half notes a minute is 60 quarters a minute: a 4/4 bar takes 4 s.
        XCTAssertEqual(score.tempoMap.segments.map(\.microsecondsPerQuarter), [1_000_000])
        XCTAssertEqual(score.totalMicroseconds, 4_000_000)
    }

    // MARK: Whole-map behaviour

    /// Worked by hand from `tempoChangesAndFermata`:
    /// a quarter-note pickup and two whole measures at ♩=60 → 9 s;
    /// one whole measure at ♩=120 → 2 s;
    /// a final whole measure under a fermata, ♩=120 stretched by 3/2 → 3 s.
    func testATempoChangeAndAFermataProduceTheHandComputedTotal() throws {
        let score = try compiler.compile(
            pieceID: "tempo",
            musicXML: MusicXMLScoreFixtures.tempoChangesAndFermata()
        )

        XCTAssertEqual(score.ticksPerQuarter, 4)
        XCTAssertEqual(score.totalTicks, 4 + 16 * 4)
        XCTAssertEqual(
            score.tempoMap.segments.map(\.microsecondsPerQuarter),
            [1_000_000, 500_000, 750_000]
        )
        XCTAssertEqual(score.tempoMap.segments.map(\.startTicks), [0, 36, 52])
        XCTAssertEqual(score.tempoMap.segments.map(\.startMicroseconds), [0, 9_000_000, 11_000_000])
        XCTAssertEqual(score.totalMicroseconds, 14_000_000)
    }

    func testTimeAndTicksRoundTripThroughTheMap() throws {
        let score = try compiler.compile(
            pieceID: "tempo",
            musicXML: MusicXMLScoreFixtures.tempoChangesAndFermata()
        )
        let map = score.tempoMap

        for ticks in stride(from: 0, through: map.totalTicks, by: 1) {
            let microseconds = map.microseconds(atPlaybackTicks: ticks)
            XCTAssertEqual(map.playbackTicks(atMicroseconds: microseconds), ticks, "at tick \(ticks)")
        }
        XCTAssertEqual(map.microseconds(atPlaybackTicks: map.totalTicks), map.totalMicroseconds)
    }

    func testTheMapIsClampedRatherThanCrashingOutsideThePiece() throws {
        let score = try compiler.compile(
            pieceID: "tempo",
            musicXML: MusicXMLScoreFixtures.tempoChangesAndFermata()
        )
        let map = score.tempoMap
        XCTAssertEqual(map.microseconds(atPlaybackTicks: -100), 0)
        XCTAssertEqual(map.microseconds(atPlaybackTicks: map.totalTicks * 10), map.totalMicroseconds)
        XCTAssertEqual(map.playbackTicks(atMicroseconds: -1), 0)
        XCTAssertEqual(map.playbackTicks(atMicroseconds: .max), map.totalTicks)
    }

    func testAScoreWithNoTempoMarkingFallsBackToTheNotationDefault() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compiler.compile(
            pieceID: "default-tempo",
            musicXML: ScoreXML.Score(
                parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]
            ).data()
        )

        XCTAssertEqual(
            score.tempoMap.segments.map(\.microsecondsPerQuarter),
            [TempoMap.defaultMicrosecondsPerQuarter]
        )
        XCTAssertEqual(score.totalMicroseconds, 2_000_000, "one 4/4 measure at ♩=120 is two seconds")
    }

    func testATempoChangeInsideARepeatedSectionComesBackOnEveryPass() throws {
        let score = try compiler.compile(
            pieceID: "repeats",
            musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )
        // One ♩=120 mark, thirteen played whole measures: 13 × 2 s.
        XCTAssertEqual(score.playbackMeasures.count, 13)
        XCTAssertEqual(score.totalMicroseconds, 26_000_000)
    }

    // MARK: Fermata folding

    func testTwoVoicesHoldingTheSameChordSlowItOnceNotTwice() {
        let builder = TempoMapBuilder(ticksPerQuarter: 4, totalTicks: 32)
        let doubled = builder.build(
            changes: [],
            holds: [
                TempoMapBuilder.Hold(startTicks: 16, endTicks: 32),
                TempoMapBuilder.Hold(startTicks: 16, endTicks: 32)
            ]
        )
        let single = builder.build(
            changes: [],
            holds: [TempoMapBuilder.Hold(startTicks: 16, endTicks: 32)]
        )
        XCTAssertEqual(doubled, single)
        XCTAssertEqual(doubled.segments.map(\.microsecondsPerQuarter), [500_000, 750_000])
    }

    /// Two parts carrying different tempo marks at the same moment is a
    /// malformed score, but it must still compile to the same bytes every
    /// time. The builder resolves the clash by the value, not by whichever
    /// order the changes happened to arrive in.
    func testConflictingTemposAtOneMomentResolveTheSameWayEveryTime() {
        let builder = TempoMapBuilder(ticksPerQuarter: 4, totalTicks: 32)
        let a = TempoMapBuilder.Change(startTicks: 16, microsecondsPerQuarter: 400_000)
        let b = TempoMapBuilder.Change(startTicks: 16, microsecondsPerQuarter: 600_000)

        let forward = builder.build(changes: [a, b], holds: [])
        let backward = builder.build(changes: [b, a], holds: [])
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.segments.map(\.microsecondsPerQuarter), [500_000, 600_000])
    }

    func testOverlappingHoldsAreMergedIntoOneSpan() {
        let merged = TempoMapBuilder.merged(
            holds: [
                TempoMapBuilder.Hold(startTicks: 0, endTicks: 8),
                TempoMapBuilder.Hold(startTicks: 4, endTicks: 12),
                TempoMapBuilder.Hold(startTicks: 20, endTicks: 24)
            ],
            totalTicks: 32
        )
        XCTAssertEqual(
            merged,
            [
                TempoMapBuilder.Hold(startTicks: 0, endTicks: 12),
                TempoMapBuilder.Hold(startTicks: 20, endTicks: 24)
            ]
        )
    }

    func testAHoldIsClippedToThePieceRatherThanRunningPastTheEnd() {
        let merged = TempoMapBuilder.merged(
            holds: [TempoMapBuilder.Hold(startTicks: 28, endTicks: 200)],
            totalTicks: 32
        )
        XCTAssertEqual(merged, [TempoMapBuilder.Hold(startTicks: 28, endTicks: 32)])
    }

    // MARK: Position reporting

    func testAPositionNamesTheMeasureNumberAndPassBeingPlayed() throws {
        let score = try compiler.compile(
            pieceID: "repeats",
            musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )

        // The fifth played measure is the second pass through measure 2.
        let start = try XCTUnwrap(score.microseconds(atPlaybackMeasure: 4))
        let position = try XCTUnwrap(score.position(atMicroseconds: start))
        XCTAssertEqual(position.playbackMeasureIndex, 4)
        XCTAssertEqual(position.measureNumber, "2")
        XCTAssertEqual(position.pass, 2)
        XCTAssertEqual(position.beat, 1.0, accuracy: 0.0001)
    }

    func testBeatsAdvanceInsideAMeasure() throws {
        let score = try compiler.compile(
            pieceID: "repeats",
            musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )
        let quarter = score.ticksPerQuarter
        let position = try XCTUnwrap(score.position(atPlaybackTicks: quarter * 2))
        XCTAssertEqual(position.playbackMeasureIndex, 0)
        XCTAssertEqual(position.beat, 3.0, accuracy: 0.0001, "two quarters in is beat three")
    }

    func testPastTheEndThereIsNoPosition() throws {
        let score = try compiler.compile(
            pieceID: "repeats",
            musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )
        XCTAssertNil(score.position(atPlaybackTicks: score.totalTicks))
        XCTAssertNil(score.position(atPlaybackTicks: -1))
    }

    func testEveryPlaybackMeasureResolvesBackToItself() throws {
        let score = try compiler.compile(
            pieceID: "quartet",
            musicXML: MusicXMLScoreFixtures.stringQuartetMovement()
        )
        for measure in score.playbackMeasures {
            let position = try XCTUnwrap(score.position(atPlaybackTicks: measure.startTicks))
            XCTAssertEqual(position.playbackMeasureIndex, measure.index)
            XCTAssertEqual(position.tickInMeasure, 0)
        }
    }
}
