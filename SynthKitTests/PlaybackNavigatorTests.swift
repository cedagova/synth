import XCTest
@testable import SynthKit

/// The transport's position mapping (REQ-009).
///
/// The playback screen shows no score (D2), so measure/beat and elapsed time
/// are the owner's *only* orientation. Everything here is therefore checked
/// against a score whose expanded order is known measure by measure, not
/// against a straight-through piece where every mapping happens to be the
/// identity.
final class PlaybackNavigatorTests: XCTestCase {
    /// Played order 1 2 3 4 2 3 5 6 7 8 1 2 3 — printed number `2` appears at
    /// playback indices 1, 4 and 11, which is exactly the case a naive
    /// "measure number is an index" mapping gets wrong.
    private func repeatScore() throws -> CompiledScore {
        try ScoreCompiler().compile(
            pieceID: "repeats",
            musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )
    }

    /// A pickup, two tempo changes and a fermata: the tick↔time map is not
    /// linear anywhere in it.
    private func tempoScore() throws -> CompiledScore {
        try ScoreCompiler().compile(
            pieceID: "tempo",
            musicXML: MusicXMLScoreFixtures.tempoChangesAndFermata()
        )
    }

    // MARK: The expanded order is what the navigator sees

    func testThePlaybackOrderIsTheExpandedSequenceNotTheNotatedOne() throws {
        let score = try repeatScore()
        let numbers = score.playbackMeasures.map {
            score.sourceMeasures[$0.sourceMeasureIndex].number
        }
        XCTAssertEqual(numbers, ["1", "2", "3", "4", "2", "3", "5", "6", "7", "8", "1", "2", "3"])
    }

    // MARK: Finding a printed measure number

    func testAMeasureNumberResolvesToItsFirstPlaybackOccurrence() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        XCTAssertEqual(navigator.playbackMeasureIndex(forMeasureNumber: "2"), 1)
        XCTAssertEqual(navigator.playbackMeasureIndex(forMeasureNumber: "8"), 9)
    }

    func testAMeasureNumberCanBeFoundAgainLaterInThePiece() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        XCTAssertEqual(navigator.playbackMeasureIndex(forMeasureNumber: "2", atOrAfter: 2), 4)
        XCTAssertEqual(navigator.playbackMeasureIndex(forMeasureNumber: "2", atOrAfter: 5), 11)
        XCTAssertNil(navigator.playbackMeasureIndex(forMeasureNumber: "2", atOrAfter: 12))
    }

    func testANumberTheScoreNeverPrintsIsRefused() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        XCTAssertNil(navigator.playbackMeasureIndex(forMeasureNumber: "99"))
        XCTAssertNil(navigator.playbackMeasureIndex(forMeasureNumber: ""))
        XCTAssertNil(navigator.playbackMeasureIndex(forMeasureNumber: "   "))
        // "12a" and "12" are different printed measures and must not collide.
        XCTAssertNil(navigator.playbackMeasureIndex(forMeasureNumber: "2a"))
    }

    func testSurroundingWhitespaceInATypedMeasureNumberIsIgnored() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        XCTAssertEqual(navigator.playbackMeasureIndex(forMeasureNumber: "  5 "), 6)
    }

    // MARK: Seeking to a measure lands on that measure

    /// The whole point of the round-trip nudge: `TempoMap` rounds one way and
    /// truncates the other, so the exact microsecond of a measure's first tick
    /// can read back as the last tick of the measure before it. If that ever
    /// happens, "go to measure 5" displays "measure 4" and the owner has no
    /// score on screen to tell them otherwise.
    func testEveryMeasureStartSeeksToAPositionThatReadsBackAsThatMeasure() throws {
        for score in [try repeatScore(), try tempoScore()] {
            let navigator = PlaybackNavigator(score: score)
            for index in score.playbackMeasures.indices {
                let microseconds = try XCTUnwrap(
                    navigator.microseconds(atPlaybackMeasureIndex: index),
                    "no time for playback measure \(index)"
                )
                let position = try XCTUnwrap(
                    navigator.position(atMicroseconds: microseconds),
                    "no position at \(microseconds) µs"
                )
                XCTAssertEqual(
                    position.playbackMeasureIndex,
                    index,
                    "seeking to playback measure \(index) landed in \(position.playbackMeasureIndex)"
                )
                XCTAssertEqual(position.tickInMeasure, 0)
                XCTAssertEqual(position.beat, 1.0, accuracy: 0.0001)
            }
        }
    }

    func testTheThirdPlayingOfMeasureTwoIsLaterInTimeThanTheFirst() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        let first = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 1))
        let second = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 4))
        let third = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 11))
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)

        // And each really is measure 2, on its own pass.
        XCTAssertEqual(navigator.position(atMicroseconds: first)?.pass, 1)
        XCTAssertEqual(navigator.position(atMicroseconds: second)?.pass, 2)
        XCTAssertEqual(navigator.position(atMicroseconds: third)?.pass, 3)
    }

    // MARK: Beats

    func testSeekingToABeatLandsOnThatBeat() throws {
        let score = try repeatScore()
        let navigator = PlaybackNavigator(score: score)
        for beat in [1.0, 2.0, 3.0, 4.0, 2.5] {
            let microseconds = try XCTUnwrap(
                navigator.microseconds(atPlaybackMeasureIndex: 6, beat: beat)
            )
            let position = try XCTUnwrap(navigator.position(atMicroseconds: microseconds))
            XCTAssertEqual(position.playbackMeasureIndex, 6)
            XCTAssertEqual(position.beat, beat, accuracy: 0.02, "beat \(beat)")
        }
    }

    func testABeatPastTheEndOfTheMeasureStaysInsideIt() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        let microseconds = try XCTUnwrap(
            navigator.microseconds(atPlaybackMeasureIndex: 6, beat: 99)
        )
        let position = try XCTUnwrap(navigator.position(atMicroseconds: microseconds))
        XCTAssertEqual(
            position.playbackMeasureIndex,
            6,
            "a mistyped beat must not silently seek into the next measure"
        )
        XCTAssertLessThan(position.beat, 5.0)
    }

    func testABeatBelowOneClampsToTheStartOfTheMeasure() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        let atZero = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 3, beat: 0))
        let atOne = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 3, beat: 1))
        XCTAssertEqual(atZero, atOne)
    }

    func testTheTickOffsetForABeatUsesTheMeasuresOwnBeatLength() {
        // 4/4 at 768 ticks per quarter: one beat is 768 ticks.
        XCTAssertEqual(
            PlaybackNavigator.tickOffset(forBeat: 3, beatTicks: 768, measureDurationTicks: 3072),
            1536
        )
        // Half-way between beats 2 and 3.
        XCTAssertEqual(
            PlaybackNavigator.tickOffset(forBeat: 2.5, beatTicks: 768, measureDurationTicks: 3072),
            1152
        )
        // Never past the measure's last tick.
        XCTAssertEqual(
            PlaybackNavigator.tickOffset(forBeat: 40, beatTicks: 768, measureDurationTicks: 3072),
            3071
        )
        XCTAssertEqual(
            PlaybackNavigator.tickOffset(forBeat: .nan, beatTicks: 768, measureDurationTicks: 3072),
            0
        )
    }

    func testAMeasureIndexOutsideThePieceHasNoTime() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        XCTAssertNil(navigator.microseconds(atPlaybackMeasureIndex: -1))
        XCTAssertNil(navigator.microseconds(atPlaybackMeasureIndex: 13))
        XCTAssertNil(navigator.endMicroseconds(ofPlaybackMeasureIndex: 13))
    }

    // MARK: Loops

    func testALoopOverAMeasureRangeCoversExactlyThoseMeasures() throws {
        let score = try repeatScore()
        let navigator = PlaybackNavigator(score: score)
        let loop = try XCTUnwrap(navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "7"))

        XCTAssertEqual(loop.startPlaybackMeasureIndex, 7)
        XCTAssertEqual(loop.endPlaybackMeasureIndex, 8)
        XCTAssertEqual(loop.measureCount, 2)
        XCTAssertEqual(loop.displayText, "measures 6–7")

        XCTAssertEqual(
            loop.startMicroseconds,
            try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: 7))
        )
        XCTAssertEqual(
            loop.endMicroseconds,
            try XCTUnwrap(navigator.endMicroseconds(ofPlaybackMeasureIndex: 8))
        )

        // The measure after the loop starts exactly where the loop wraps.
        XCTAssertEqual(
            navigator.position(atMicroseconds: loop.endMicroseconds)?.playbackMeasureIndex,
            9
        )
    }

    func testAOneMeasureLoopIsAllowedAndNamedInTheSingular() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        let loop = try XCTUnwrap(navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "6"))
        XCTAssertEqual(loop.measureCount, 1)
        XCTAssertEqual(loop.displayText, "measure 6")
        XCTAssertGreaterThan(loop.durationMicroseconds, 0)
    }

    /// The loop end is looked for *at or after* the start, so a loop set over a
    /// repeated section takes the pass the owner is on rather than an earlier
    /// printing of the same number.
    func testTheLoopEndIsResolvedAfterTheLoopStart() throws {
        let score = try repeatScore()
        let navigator = PlaybackNavigator(score: score)
        // Printed 5 is at playback index 6; printed 2 is at 1, 4 and 11. The
        // only "2" after the start is the last one.
        let loop = try XCTUnwrap(navigator.loopRange(fromMeasureNumber: "5", toMeasureNumber: "2"))
        XCTAssertEqual(loop.startPlaybackMeasureIndex, 6)
        XCTAssertEqual(loop.endPlaybackMeasureIndex, 11)
    }

    func testALoopWhoseEndNeverComesAfterItsStartIsRefused() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        // Printed 4 occurs only once, at index 3, before printed 6 at index 7.
        XCTAssertNil(navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "4"))
        XCTAssertNil(navigator.loopRange(fromMeasureNumber: "99", toMeasureNumber: "1"))
        XCTAssertNil(navigator.loopRange(fromMeasureNumber: "1", toMeasureNumber: "99"))
    }

    func testALoopWrapsOnlyOnceThePlayheadHasLeftIt() throws {
        let navigator = PlaybackNavigator(score: try repeatScore())
        let loop = try XCTUnwrap(navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "7"))

        XCTAssertNil(loop.wrapTarget(forPosition: loop.startMicroseconds))
        XCTAssertNil(loop.wrapTarget(forPosition: loop.endMicroseconds - 1))
        XCTAssertEqual(loop.wrapTarget(forPosition: loop.endMicroseconds), loop.startMicroseconds)
        XCTAssertEqual(
            loop.wrapTarget(forPosition: loop.endMicroseconds + 5_000_000),
            loop.startMicroseconds
        )

        // A playhead before the loop is left alone: running into a loop from
        // earlier in the piece is how a player uses one.
        XCTAssertNil(loop.wrapTarget(forPosition: 0))
        XCTAssertFalse(loop.contains(0))
        XCTAssertTrue(loop.contains(loop.startMicroseconds))
        XCTAssertFalse(loop.contains(loop.endMicroseconds))
    }

    // MARK: Bounds and metadata

    func testTheNavigatorReportsThePiecesOwnBounds() throws {
        let score = try repeatScore()
        let navigator = PlaybackNavigator(score: score)
        XCTAssertEqual(navigator.playbackMeasureCount, 13)
        XCTAssertEqual(navigator.totalMicroseconds, score.totalMicroseconds)
        XCTAssertFalse(navigator.isEmpty)
        XCTAssertEqual(navigator.firstMeasureNumber, "1")
        XCTAssertEqual(navigator.lastMeasureNumber, "3")
    }

    /// A tempo change means equal measures are not equal times: the mapping has
    /// to go through the tempo map, and this fails if anything ever divides the
    /// total length by the measure count instead.
    func testMeasuresAtDifferentTemposTakeDifferentAmountsOfTime() throws {
        let score = try tempoScore()
        let navigator = PlaybackNavigator(score: score)
        XCTAssertGreaterThanOrEqual(score.playbackMeasures.count, 4)

        func length(_ index: Int) throws -> Int64 {
            let start = try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: index))
            let end = try XCTUnwrap(navigator.endMicroseconds(ofPlaybackMeasureIndex: index))
            return end - start
        }

        // ♩=60 up to measure 2, ♩=120 from measure 3: the later measure is
        // about half as long.
        let slow = try length(1)
        let fast = try length(3)
        XCTAssertGreaterThan(slow, fast)
        XCTAssertEqual(Double(slow) / Double(fast), 2.0, accuracy: 0.05)
    }
}
