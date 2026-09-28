import XCTest
@testable import SynthKit

/// Rehearsal marks (#93, plan decisions 11–13): compiled into the model as
/// navigation text only, found at their first performance, and usable as loop
/// bounds — without changing a single thing that sounds.
final class RehearsalMarkTests: XCTestCase {
    // MARK: The fixture

    /// Two parts, six measures, measures 3–4 repeated, so the played order is
    /// 1 2 3 4 3 4 5 6 (playback indices 0…7).
    ///
    /// The marks exercise every rule at once:
    /// - `A` at measure 1 and again at measure 6 — same text, two places;
    /// - a whitespace-only mark at measure 2 — ignored;
    /// - `B` at measure 3, printed mid-measure, in both parts — one mark,
    ///   inside the repeat;
    /// - `C` at measure 5, in both parts — one mark;
    /// - `Coda  section` with a line break — whitespace collapsed.
    static func markedScore(withMarks: Bool = true) -> Data {
        func mark(_ text: String) -> ScoreXML.Item {
            .direction(ScoreXML.Direction(raw: ["<rehearsal>\(text)</rehearsal>"]))
        }
        func part(_ id: String, name: String, pitch: String, printsMarks: [Int: [String]]) -> ScoreXML.Part {
            let measures = (1...6).map { number -> ScoreXML.Measure in
                var items: [ScoreXML.Item] = []
                if number == 1 {
                    items.append(.attributes(
                        ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    ))
                }
                if number == 3 { items.append(.barline(.forwardRepeat())) }
                let marks = withMarks ? (printsMarks[number] ?? []) : []
                if number == 3 {
                    // Mid-measure: after the first half note.
                    items.append(.note(ScoreXML.Note(pitch: pitch, duration: 8, type: "half")))
                    items.append(contentsOf: marks.map(mark))
                    items.append(.note(ScoreXML.Note(pitch: pitch, duration: 8, type: "half")))
                } else {
                    items.append(contentsOf: marks.map(mark))
                    items.append(.note(ScoreXML.Note(pitch: pitch, duration: 16, type: "whole")))
                }
                if number == 4 { items.append(.barline(.backwardRepeat())) }
                return ScoreXML.Measure(number: String(number), items: items)
            }
            return ScoreXML.Part(id: id, name: name, measures: measures)
        }
        return ScoreXML.Score(parts: [
            part("P1", name: "Violin", pitch: "E5", printsMarks: [
                1: ["A"], 2: ["   "], 3: ["B"], 5: ["C", "Coda\n   section"], 6: ["A"]
            ]),
            part("P2", name: "Cello", pitch: "C3", printsMarks: [3: ["B"], 5: ["C"]])
        ]).data()
    }

    private func compile(_ data: Data) throws -> CompiledScore {
        try ScoreCompiler().compile(pieceID: "marks", musicXML: data)
    }

    private func markedNavigator() throws -> PlaybackNavigator {
        PlaybackNavigator(score: try compile(Self.markedScore()))
    }

    // MARK: Compilation

    func testMarksAreCompiledInScoreOrderOncePerMeasureAndText() throws {
        let score = try compile(Self.markedScore())
        XCTAssertEqual(
            score.rehearsalMarks,
            [
                RehearsalMark(text: "A", sourceMeasureIndex: 0),
                RehearsalMark(text: "B", sourceMeasureIndex: 2),
                RehearsalMark(text: "C", sourceMeasureIndex: 4),
                RehearsalMark(text: "Coda section", sourceMeasureIndex: 4),
                RehearsalMark(text: "A", sourceMeasureIndex: 5)
            ]
        )
    }

    func testAScoreWithoutMarksHasNone() throws {
        let score = try compile(Self.markedScore(withMarks: false))
        XCTAssertEqual(score.rehearsalMarks, [])
        XCTAssertEqual(PlaybackNavigator(score: score).rehearsalMarkTargets, [])
    }

    func testMarksArePartOfTheCanonicalBytesOnlyWhenThereAreSome() throws {
        let marked = String(decoding: try compile(Self.markedScore()).canonicalData(), as: UTF8.self)
        let plain = String(
            decoding: try compile(Self.markedScore(withMarks: false)).canonicalData(),
            as: UTF8.self
        )
        XCTAssertTrue(marked.contains("\"rehearsalMarks\""))
        XCTAssertFalse(plain.contains("rehearsalMarks"))
    }

    func testMarksRoundTripThroughCoding() throws {
        let score = try compile(Self.markedScore())
        let decoded = try JSONDecoder().decode(CompiledScore.self, from: try score.canonicalData())
        XCTAssertEqual(decoded, score)
    }

    func testMarksChangeNothingElseTheCompilerProduces() throws {
        let marked = try compile(Self.markedScore())
        let plain = try compile(Self.markedScore(withMarks: false))
        XCTAssertEqual(marked.lines, plain.lines)
        XCTAssertEqual(marked.sourceMeasures, plain.sourceMeasures)
        XCTAssertEqual(marked.playbackMeasures, plain.playbackMeasures)
        XCTAssertEqual(marked.tempoMap, plain.tempoMap)
        XCTAssertEqual(marked.expressionEvents, plain.expressionEvents)
        XCTAssertEqual(marked.report, plain.report)
        XCTAssertTrue(marked.report.isEmpty, "got \(marked.report.entries.map(\.kind))")
    }

    func testTempoScalingKeepsTheMarks() throws {
        let score = try compile(Self.markedScore())
        XCTAssertEqual(score.scalingTempo(toPercent: 50).rehearsalMarks, score.rehearsalMarks)
    }

    // MARK: Going to a mark

    func testTargetsListEveryMarkWithItsMeasureNumber() throws {
        let targets = try markedNavigator().rehearsalMarkTargets
        XCTAssertEqual(
            targets.map(\.menuTitle),
            ["A (measure 1)", "B (measure 3)", "C (measure 5)", "Coda section (measure 5)", "A (measure 6)"]
        )
        XCTAssertEqual(targets.map(\.id), [0, 1, 2, 3, 4])
    }

    func testAMarkInsideARepeatGoesToItsFirstPerformance() throws {
        let navigator = try markedNavigator()
        XCTAssertEqual(
            navigator.score.playbackMeasures.map { navigator.score.sourceMeasures[$0.sourceMeasureIndex].number },
            ["1", "2", "3", "4", "3", "4", "5", "6"]
        )
        let targets = navigator.rehearsalMarkTargets
        XCTAssertEqual(targets.map(\.playbackMeasureIndex), [0, 2, 6, 6, 7])

        let b = targets[1]
        XCTAssertEqual(
            navigator.microseconds(forRehearsalMark: b.mark),
            navigator.microseconds(forMeasureNumber: "3"),
            "A mark seeks exactly where Go to Measure would"
        )
        XCTAssertEqual(
            navigator.position(atMicroseconds: try XCTUnwrap(navigator.microseconds(forRehearsalMark: b.mark)))?
                .playbackMeasureIndex,
            2
        )
    }

    // MARK: Marks as loop bounds

    func testTheMeasureBeforeEachMarkIsWhereALoopToItEnds() throws {
        let targets = try markedNavigator().rehearsalMarkTargets
        XCTAssertEqual(targets.map(\.measureNumberBefore), [nil, "2", "4", "4", "5"])
    }

    func testLoopingFromOneMarkToTheNextLoopsTheSectionBetween() throws {
        let navigator = try markedNavigator()
        let targets = navigator.rehearsalMarkTargets
        let (a, b, c) = (targets[0], targets[1], targets[2])

        let sectionA = try XCTUnwrap(
            navigator.loopRange(fromMeasureNumber: a.measureNumber, toMeasureNumber: try XCTUnwrap(b.measureNumberBefore))
        )
        XCTAssertEqual(sectionA.startPlaybackMeasureIndex, 0)
        XCTAssertEqual(sectionA.endPlaybackMeasureIndex, 1)
        XCTAssertEqual(
            sectionA.endMicroseconds,
            navigator.microseconds(forRehearsalMark: b.mark),
            "The loop wraps exactly where B begins"
        )

        // B to C crosses the repeat: the heard-pass rule takes B's first pass.
        let sectionB = try XCTUnwrap(
            navigator.loopRange(fromMeasureNumber: b.measureNumber, toMeasureNumber: try XCTUnwrap(c.measureNumberBefore))
        )
        XCTAssertEqual(sectionB.startPlaybackMeasureIndex, 2)
        XCTAssertEqual(sectionB.endPlaybackMeasureIndex, 3)

        // The last section runs to the end of the piece.
        let last = try XCTUnwrap(
            navigator.loopRange(
                fromMeasureNumber: targets[4].measureNumber,
                toMeasureNumber: try XCTUnwrap(navigator.lastMeasureNumber)
            )
        )
        XCTAssertEqual(last.startPlaybackMeasureIndex, 7)
        XCTAssertEqual(last.endMicroseconds, navigator.totalMicroseconds)
    }
}
