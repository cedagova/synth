import XCTest
@testable import SynthKit

/// REQ-014's data: everything the compiler met and did not honour, named and
/// located, aggregated so the list stays readable, and ordered so the same
/// file always produces the same report.
final class NotationReportTests: XCTestCase {
    private let compiler = ScoreCompiler()

    private func compile(_ data: Data) throws -> CompiledScore {
        try compiler.compile(pieceID: "report", musicXML: data)
    }

    /// One measure carrying `notations`, for pinning a single finding.
    private func scoreWithNotation(_ notation: String) throws -> CompiledScore {
        try compile(MusicXMLScoreFixtures.unsupportedMarking(notation))
    }

    // MARK: What gets reported

    func testEachFamilyOfUnhonouredNotationIsNamedSpecifically() throws {
        let cases: [(notation: String, kind: String)] = [
            ("<ornaments><trill-mark/></ornaments>", "ornament: trill-mark"),
            ("<articulations><staccato/></articulations>", "articulation: staccato"),
            ("<technical><up-bow/></technical>", "technique: up-bow"),
            ("<dynamics><sf/></dynamics>", "dynamic: sf"),
            ("<arpeggiate/>", "notation: arpeggiate"),
            ("<glissando type=\"start\"/>", "notation: glissando")
        ]
        for testCase in cases {
            let score = try scoreWithNotation(testCase.notation)
            XCTAssertTrue(
                score.report.mentions(kind: testCase.kind),
                "expected \(testCase.kind), got \(score.report.entries.map(\.kind))"
            )
        }
    }

    func testNotationThatOnlyRendersSomethingAlreadyHonouredIsNotReported() throws {
        // <tied> draws the tie that <tie> already plays; <tuplet> draws a
        // bracket over durations that are already correct in <duration>.
        for notation in ["<tied type=\"start\"/>", "<tuplet type=\"start\"/>"] {
            let score = try scoreWithNotation(notation)
            XCTAssertTrue(
                score.report.isEmpty,
                "\(notation) should be silent, got \(score.report.entries.map(\.kind))"
            )
        }
    }

    func testAnUnrecognisedElementIsReportedRatherThanIgnored() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole")),
                .raw("<future-notation-element/>")
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertTrue(score.report.mentions(kind: "unrecognised element: future-notation-element"))
    }

    func testChordSymbolsAndFiguredBassAreReportedAsUnsounded() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .raw("<harmony><root><root-step>C</root-step></root><kind>major</kind></harmony>"),
                .raw("<figured-bass><figure><figure-number>6</figure-number></figure></figured-bass>"),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Continuo", measures: [measure])]).data()
        )
        XCTAssertTrue(score.report.mentions(kind: "chord symbol"))
        XCTAssertTrue(score.report.mentions(kind: "figured bass"))
    }

    func testAMeasureRepeatShorthandIsReportedBecauseItIsNotExpanded() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(
                        divisions: 4,
                        fifths: 0,
                        time: (4, 4),
                        raw: ["<measure-style><measure-repeat type=\"start\">1</measure-repeat></measure-style>"]
                    )
                ),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertTrue(score.report.mentions(kind: "measure style: measure-repeat"))
    }

    func testLayoutMarkupIsNotTreatedAsUnhonouredNotation() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)])),
                .raw("<print new-system=\"yes\"/>"),
                .direction(ScoreXML.Direction(raw: ["<rehearsal>A</rehearsal>"])),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertTrue(score.report.isEmpty, "got \(score.report.entries.map(\.kind))")
    }

    // MARK: Aggregation and shape

    func testTheCollectorKeepsTheFirstLocationAndCountsTheRest() {
        var collector = NotationReportCollector()
        collector.record(
            .notHonored,
            kind: "articulation: staccato",
            at: ScoreLocation(partID: "P1", partName: "Flute", sourceMeasureIndex: 3, measureNumber: "4")
        )
        collector.record(
            .notHonored,
            kind: "articulation: staccato",
            at: ScoreLocation(partID: "P1", partName: "Flute", sourceMeasureIndex: 9, measureNumber: "10")
        )

        let report = collector.finish()
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].occurrenceCount, 2)
        XCTAssertEqual(report.entries[0].firstLocation.measureNumber, "4")
    }

    func testTheSameKindInDifferentPartsStaysSeparate() {
        var collector = NotationReportCollector()
        for part in ["P1", "P2"] {
            collector.record(
                .notHonored,
                kind: "notation: slur",
                at: ScoreLocation(partID: part, sourceMeasureIndex: 0, measureNumber: "1")
            )
        }
        XCTAssertEqual(collector.finish().entries.count, 2)
    }

    func testAnAbsurdNumberOfDistinctFindingsIsCappedAndCounted() {
        var collector = NotationReportCollector()
        let over = NotationReportCollector.maximumEntryCount + 25
        for index in 0..<over {
            collector.record(.notHonored, kind: "kind \(index)")
        }

        let report = collector.finish()
        XCTAssertEqual(report.entries.count, NotationReportCollector.maximumEntryCount)
        XCTAssertEqual(report.truncatedKindCount, 25)
        XCTAssertFalse(report.isEmpty)
    }

    func testStructuralFallbacksAreSeparableFromUnhonouredNotation() throws {
        let score = try compile(MusicXMLScoreFixtures.contradictoryStructure())
        XCTAssertFalse(score.report.entries(in: .structuralFallback).isEmpty)
        XCTAssertTrue(score.report.entries(in: .notHonored).isEmpty)
    }

    // MARK: Display

    func testAnEntryReadsAsASentenceForThePieceReport() {
        let single = NotationReportEntry(
            category: .notHonored,
            kind: "ornament: mordent",
            firstLocation: ScoreLocation(partID: "P1", partName: "Oboe", measureNumber: "12"),
            occurrenceCount: 1,
            detail: nil
        )
        XCTAssertEqual(single.displayText, "ornament: mordent at Oboe, measure 12")

        let many = NotationReportEntry(
            category: .structuralFallback,
            kind: "unmatched backward repeat",
            firstLocation: ScoreLocation(sourceMeasureIndex: 4),
            occurrenceCount: 3,
            detail: "it repeats from the start of the piece"
        )
        XCTAssertEqual(
            many.displayText,
            "unmatched backward repeat (3 occurrences, first at measure 5) "
                + "— it repeats from the start of the piece"
        )
    }

    func testALocationWithNothingKnownStillReadsSensibly() {
        XCTAssertEqual(ScoreLocation().displayText, "the whole score")
        XCTAssertEqual(ScoreLocation(partID: "P7").displayText, "part P7")
    }
}
