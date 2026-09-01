import XCTest
@testable import SynthKit

/// What the transport readout says and what the owner may type into it.
///
/// Both directions matter equally: the readout is the product's only positional
/// orientation (D2), and the seek fields are how a position is asked for.
final class TransportDisplayTests: XCTestCase {
    // MARK: Elapsed time

    func testElapsedTimeReadsAsMinutesSecondsAndTenths() {
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 0), "0:00.0")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 400_000), "0:00.4")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 9_000_000), "0:09.0")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 63_400_000), "1:03.4")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 600_000_000), "10:00.0")
    }

    func testAnHourLongPieceGrowsAnHoursField() {
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 3_723_400_000), "1:02:03.4")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 3_600_000_000), "1:00:00.0")
    }

    func testTenthsRoundRatherThanTruncate() {
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 449_999), "0:00.4")
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 450_000), "0:00.5")
        // Rounding up across a second boundary must carry.
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: 59_960_000), "1:00.0")
    }

    func testANegativePositionReadsAsZeroRatherThanAsGarbage() {
        XCTAssertEqual(TransportDisplay.elapsedText(microseconds: -1), "0:00.0")
    }

    func testElapsedAgainstTotalNamesBoth() {
        XCTAssertEqual(
            TransportDisplay.elapsedOfTotalText(microseconds: 63_400_000, total: 245_000_000),
            "1:03.4 of 4:05.0"
        )
    }

    func testASpokenDurationIsWordsRatherThanPunctuation() {
        XCTAssertEqual(TransportDisplay.spokenElapsed(microseconds: 0), "0 seconds")
        XCTAssertEqual(TransportDisplay.spokenElapsed(microseconds: 1_000_000), "1 second")
        XCTAssertEqual(TransportDisplay.spokenElapsed(microseconds: 63_400_000), "1 minute 3.4 seconds")
        XCTAssertEqual(TransportDisplay.spokenElapsed(microseconds: 125_000_000), "2 minutes 5 seconds")
    }

    // MARK: Measure and beat

    func testABeatIsNamedAsTheDiscreteBeatUnderWay() {
        XCTAssertEqual(TransportDisplay.beatText(1), "1")
        XCTAssertEqual(TransportDisplay.beatText(3.24), "3")
        XCTAssertEqual(TransportDisplay.beatText(3.96), "3", "beat 4 has not arrived at 3.96")
        XCTAssertEqual(TransportDisplay.beatText(0.2), "1", "beats start at 1")
        XCTAssertEqual(TransportDisplay.beatText(.nan), "1")
    }

    private func position(
        measureNumber: String,
        pass: Int,
        beat: Double
    ) -> ScorePosition {
        ScorePosition(
            playbackMeasureIndex: 0,
            sourceMeasureIndex: 0,
            measureNumber: measureNumber,
            pass: pass,
            tickInMeasure: 0,
            beat: beat
        )
    }

    func testThePositionReadoutNamesTheMeasureAndTheBeat() {
        XCTAssertEqual(
            TransportDisplay.positionText(position(measureNumber: "12", pass: 1, beat: 3.2)),
            "Measure 12 · beat 3"
        )
    }

    /// The pass is shown only when it is not the first, because a repeat plays
    /// one printed number several times and "measure 2" alone would be
    /// ambiguous exactly then.
    func testThePassIsShownOnlyOnceThePieceIsRepeatingAMeasure() {
        XCTAssertEqual(
            TransportDisplay.positionText(position(measureNumber: "2", pass: 3, beat: 1)),
            "Measure 2 (pass 3) · beat 1"
        )
    }

    func testPastTheEndOfThePieceThereIsNoMeasureToName() {
        XCTAssertEqual(TransportDisplay.positionText(nil), "—")
    }

    func testTheSpokenPositionIsOneSentence() {
        XCTAssertEqual(
            TransportDisplay.spokenPosition(
                position(measureNumber: "12", pass: 2, beat: 3.2),
                microseconds: 63_400_000,
                total: 245_000_000
            ),
            "Position: measure 12, pass 2, beat 3, 1 minute 3.4 seconds of 4 minutes 5 seconds."
        )
        XCTAssertEqual(
            TransportDisplay.spokenPosition(nil, microseconds: 245_000_000, total: 245_000_000),
            "Position: end of the piece, 4 minutes 5 seconds of 4 minutes 5 seconds."
        )
    }

    // MARK: Parsing a typed time

    func testATypedTimeIsReadAsMinutesAndSeconds() {
        XCTAssertEqual(TransportDisplay.parseTime("0"), 0)
        XCTAssertEqual(TransportDisplay.parseTime("83"), 83_000_000)
        XCTAssertEqual(TransportDisplay.parseTime("83.4"), 83_400_000)
        XCTAssertEqual(TransportDisplay.parseTime("1:23"), 83_000_000)
        XCTAssertEqual(TransportDisplay.parseTime("1:23.4"), 83_400_000)
        XCTAssertEqual(TransportDisplay.parseTime("1:02:03.4"), 3_723_400_000)
        XCTAssertEqual(TransportDisplay.parseTime("  1:23.4  "), 83_400_000)
    }

    func testAFractionIsReadByPositionNotByDigitCount() {
        XCTAssertEqual(TransportDisplay.parseTime("0.5"), 500_000)
        XCTAssertEqual(TransportDisplay.parseTime("0.05"), 50_000)
        XCTAssertEqual(TransportDisplay.parseTime("0.000001"), 1)
    }

    /// A field that guesses is worse than a field that refuses: the owner has
    /// no score on screen to notice they landed somewhere else.
    func testAnUnreadableTimeIsRefusedRatherThanGuessed() {
        for text in ["", "   ", "abc", "1:2:3:4", "1..2", "-5", "1:", ":30", "1,5", "1e3", "12345"] {
            XCTAssertNil(TransportDisplay.parseTime(text), "“\(text)” should not parse")
        }
    }

    func testAParsedTimeRoundTripsThroughTheReadout() {
        for text in ["0:00.0", "1:03.4", "10:00.0"] {
            let microseconds = TransportDisplay.parseTime(text)
            XCTAssertEqual(
                TransportDisplay.elapsedText(microseconds: microseconds ?? -1),
                text
            )
        }
    }

    // MARK: Parsing a typed beat

    func testATypedBeatIsReadWholeOrFractional() {
        XCTAssertEqual(TransportDisplay.parseBeat("1"), 1)
        XCTAssertEqual(TransportDisplay.parseBeat("3"), 3)
        XCTAssertEqual(try XCTUnwrap(TransportDisplay.parseBeat("2.5")), 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(TransportDisplay.parseBeat(" 4.25 ")), 4.25, accuracy: 0.0001)
    }

    func testABeatBelowOneOrUnreadableIsRefused() {
        for text in ["", "0", "0.5", "-1", "abc", "1.2.3", "one"] {
            XCTAssertNil(TransportDisplay.parseBeat(text), "“\(text)” should not parse")
        }
    }
}
