import XCTest
@testable import SynthKit

/// EXP002's articulation half: slurred passages render legato and unslurred
/// passages détaché, measurably in durations and overlaps, with a written
/// articulation still winning over both.
///
/// **Always on, and that is the claim these tests exist to pin.** Articulation
/// is score reading, not interpretation: a slur and a staccato dot are printed
/// on the page, so the expression setting does not scale them and its off state
/// does not suppress them. REQ-004's bypass recipe is "written notation plus
/// uniform humanization", and this is the written notation — which is why
/// `testTheReadingIsIdenticalWithExpressionOffAndAtFullAmount` is here rather
/// than in `PerformanceExpressionTests`, and why the bypass digests there still
/// have to hold with every one of these readings active.
///
/// The one behaviour that *changed* on this leaf is the size of the legato
/// overlap, which used to be `ticksPerQuarter / 32` — a fraction of whatever one
/// tick happens to be on the score in front of it.
/// `testTheLegatoOverlapDoesNotDependOnTheEngraversDivisionSetting` is the
/// regression: the same music, written four ways, must sound the same.
final class PerformanceArticulationTests: XCTestCase {
    private let compiler = ScoreCompiler()
    private let realizer = PerformanceRealizer()

    private static let expressionOnly = RealizationSettings(
        humanization: .off, expression: ExpressionSettings(isEnabled: true, amount: 100)
    )

    private func compile(_ data: Data, id: String = "articulation") throws -> CompiledScore {
        try compiler.compile(pieceID: id, musicXML: data)
    }

    /// The events of one playback measure of the first line, in time order.
    private func events(_ timeline: PerformanceTimeline, measure: Int) -> [PerformanceEvent] {
        timeline.lines[0].events.filter { $0.playbackMeasureIndex == measure }
    }

    // MARK: The criterion — legato under a slur, détaché otherwise

    /// Slurred notes still sound when the next one begins; unslurred ones stop
    /// short of it. Measured as the signed distance between one note's release
    /// and the next note's onset, which is what "durations and overlaps" means.
    func testSlurredPassagesRenderLegatoAndUnslurredPassagesRenderDetache() throws {
        let study = try compile(MusicXMLScoreFixtures.articulationAndSlurStudy())
        let timeline = realizer.realize(study, settings: .literal)

        // The fixture's measure 3 is the slurred one; measure 1 is four plain,
        // unmarked quarters.
        func distancesToNextOnset(measure: Int) -> [Int64] {
            let measureEvents = events(timeline, measure: measure)
            return zip(measureEvents, measureEvents.dropFirst()).map {
                $0.endMicroseconds - $1.onsetMicroseconds
            }
        }

        let detached = distancesToNextOnset(measure: 0)
        let legato = distancesToNextOnset(measure: 2)
        XCTAssertEqual(detached.count, 3, "four plain quarters make three gaps")
        XCTAssertEqual(legato.count, 3, "four slurred quarters make three joins")

        for gap in detached {
            XCTAssertLessThan(
                gap, 0,
                "an unslurred note must be released before the next one begins; this one "
                    + "overran by \(gap) µs"
            )
        }
        for overlap in legato {
            XCTAssertGreaterThan(
                overlap, 0,
                "a slurred note must still be sounding when the next begins; this one "
                    + "stopped \(-overlap) µs short"
            )
        }

        // And the overlap is a bounded gesture rather than a held note: at most
        // the stated twenty milliseconds.
        for overlap in legato {
            XCTAssertLessThanOrEqual(
                overlap, PerformanceRealizer.legatoOverlapMicroseconds,
                "the legato overlap exceeded its own bound"
            )
        }
    }

    /// The plain reading is the détaché one, on the tick grid where the
    /// convention is stated, and the slur holds the note all the way to the next
    /// onset rather than merely lengthening it.
    func testTheShapedLengthsAreTheWrittenConventions() throws {
        let study = try compile(MusicXMLScoreFixtures.articulationAndSlurStudy())
        let timeline = realizer.realize(study, settings: .literal)
        let written = MusicXMLScoreFixtures.fineQuarter

        for event in events(timeline, measure: 0) {
            XCTAssertEqual(
                event.durationTicks, written * PerformanceRealizer.detachedPercent / 100,
                "a plain quarter sounds its détaché reading"
            )
        }
        // Under the slur the notated length reaches the next onset exactly — the
        // overlap past it is carried in microseconds, not in ticks, so a piano
        // roll reading `durationTicks` sees the shaped notated length.
        let slurred = events(timeline, measure: 2)
        for event in slurred.dropLast() {
            XCTAssertEqual(
                event.durationTicks, written,
                "a slurred note is held to the next onset on the tick grid"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(slurred.last).durationTicks,
            written * PerformanceRealizer.detachedPercent / 100,
            "the last note of a slur has nothing to run into and is released"
        )
    }

    /// A written articulation wins over the slur: staccato under a slur is
    /// portato, and the note carries no overlap at all.
    func testAWrittenArticulationWinsOverTheSlur() throws {
        let study = try compile(Self.staccatoUnderASlur())
        let timeline = realizer.realize(study, settings: .literal)
        let notes = events(timeline, measure: 0)
        XCTAssertEqual(notes.count, 4)

        let written = MusicXMLScoreFixtures.quarter
        for (index, event) in notes.enumerated() {
            XCTAssertEqual(
                event.durationTicks, written / 2,
                "note \(index) is staccato under a slur, which is portato: half its value"
            )
        }
        for (event, next) in zip(notes, notes.dropFirst()) {
            XCTAssertLessThan(
                event.endMicroseconds, next.onsetMicroseconds,
                "a portato note must not overlap the note after it"
            )
        }
    }

    // MARK: The regression — the overlap is not the engraver's business

    /// The same four slurred quarters, written at four different `<divisions>`
    /// settings, overlap by the same amount of time.
    ///
    /// **This is the defect this leaf fixes.** `ticksPerQuarter` is the least
    /// common multiple of the `<divisions>` values in the file, so a
    /// tick-valued overlap of `ticksPerQuarter / 32` was a thirty-second of a
    /// quarter at 480 divisions, a whole *sixteenth* at 4, and a whole *quarter
    /// note* at 1 — the expression floors to zero and `max(1, …)` promotes it to
    /// one tick of whatever size that score happens to use. Identical music,
    /// four different performances, decided by a number the engraver set for
    /// their own convenience.
    func testTheLegatoOverlapDoesNotDependOnTheEngraversDivisionSetting() throws {
        var overlaps: [Int: Int64] = [:]
        for divisions in [1, 4, 24, 480] {
            let score = try compile(
                Self.slurredQuarters(divisions: divisions), id: "divisions-\(divisions)"
            )
            XCTAssertEqual(
                score.ticksPerQuarter, divisions,
                "the fixture must actually reach the compiler at this division setting"
            )
            let timeline = realizer.realize(score, settings: .literal)
            let notes = events(timeline, measure: 0)
            XCTAssertEqual(notes.count, 4)
            overlaps[divisions] = notes[0].endMicroseconds - notes[1].onsetMicroseconds
        }

        let distinct = Set(overlaps.values)
        XCTAssertEqual(
            distinct.count, 1,
            "the legato overlap still depends on the engraver's division setting: \(overlaps)"
        )
        // And it is the intended gesture rather than a note: a quarter at 120 BPM
        // is half a second, so a division-dependent overlap showed up here as
        // 500 000 µs at one division and 125 000 µs at four.
        XCTAssertEqual(
            distinct.first, PerformanceRealizer.legatoOverlapMicroseconds,
            "a quarter at 120 BPM is long enough for the full overlap"
        )
    }

    /// The shortening half of the same defect (#80). An articulation's reading
    /// used to be `notated * percent / 100` on the tick grid, which floors to
    /// nothing on a score written at one division to the quarter — so a staccato
    /// quarter sounded its full value there, indistinguishable from a tenuto,
    /// and read a different length at every division setting in between.
    func testArticulationShorteningDoesNotDependOnTheEngraversDivisionSetting() throws {
        var readings: [Int: [Int64]] = [:]
        for divisions in [1, 4, 24, 480] {
            let score = try compile(
                Self.articulatedQuarters(divisions: divisions), id: "shortening-\(divisions)"
            )
            XCTAssertEqual(
                score.ticksPerQuarter, divisions,
                "the fixture must actually reach the compiler at this division setting"
            )
            let notes = events(realizer.realize(score, settings: .literal), measure: 0)
            XCTAssertEqual(notes.count, 4)
            readings[divisions] = notes.map(\.durationMicroseconds)
        }

        let distinct = Set(readings.values)
        XCTAssertEqual(
            distinct.count, 1,
            "a note's sounding length still depends on the engraver's division "
                + "setting: \(readings)"
        )
        // A quarter at 120 BPM is half a second: the staccato sounds half of
        // it, the tenuto all of it, and the two plain notes their détaché nine
        // tenths — three readings, distinguishable at every division setting.
        XCTAssertEqual(distinct.first, [250_000, 500_000, 450_000, 450_000])
    }

    /// The bound by the note's own length is the other half: a slurred
    /// thirty-second in a fast figure overlaps proportionally less rather than
    /// being swallowed.
    func testAVeryShortSlurredNoteOverlapsProportionallyLess() throws {
        let score = try compile(Self.slurredThirtySeconds(), id: "short-slur")
        let timeline = realizer.realize(score, settings: .literal)
        let notes = events(timeline, measure: 0)
        XCTAssertGreaterThan(notes.count, 4)

        let first = notes[0]
        let overlap = first.endMicroseconds - notes[1].onsetMicroseconds
        let sounding = notes[1].onsetMicroseconds - first.onsetMicroseconds
        XCTAssertGreaterThan(overlap, 0, "it is still legato")
        XCTAssertLessThan(
            overlap, PerformanceRealizer.legatoOverlapMicroseconds,
            "a thirty-second is shorter than eight times the full overlap, so the bound "
                + "by its own length must have engaged"
        )
        XCTAssertEqual(
            overlap, sounding / PerformanceRealizer.legatoOverlapSpanDivisor,
            "the overlap is an eighth of the note's own sounding span"
        )
    }

    // MARK: Always on

    /// Articulation is not scaled by the expression amount and is not suppressed
    /// by its off state: every sounding length and every overlap is identical at
    /// expression off and at amount 100.
    ///
    /// Loudness is excluded from the comparison on purpose — the phrase arch, the
    /// cadential easing and the line balance all move velocity, and all three are
    /// the setting's business. Length is not.
    func testTheReadingIsIdenticalWithExpressionOffAndAtFullAmount() throws {
        for data in [
            MusicXMLScoreFixtures.articulationAndSlurStudy(),
            MusicXMLScoreFixtures.stringQuartetMovement(),
            MusicXMLScoreFixtures.expressiveKeyboardPiece()
        ] {
            let score = try compile(data)
            let off = realizer.realize(
                score, settings: RealizationSettings(humanization: .off, expression: .off)
            )
            let full = realizer.realize(score, settings: Self.expressionOnly)

            XCTAssertEqual(off.lines.count, full.lines.count)
            for (offLine, fullLine) in zip(off.lines, full.lines) {
                XCTAssertEqual(offLine.events.count, fullLine.events.count)
                for (offEvent, fullEvent) in zip(offLine.events, fullLine.events) {
                    XCTAssertEqual(
                        offEvent.durationTicks, fullEvent.durationTicks,
                        "a shaped notated length moved with the expression amount"
                    )
                    XCTAssertEqual(
                        offEvent.midiNoteNumber, fullEvent.midiNoteNumber,
                        "the expression setting changed which note is played"
                    )
                }
            }

            // The vacuity guard: the fixtures must be shaped *somewhere* at full
            // amount, or the equalities above prove nothing about the separation.
            XCTAssertNotEqual(
                off.lines, full.lines,
                "the fixture realizes identically off and on, so this proves nothing"
            )
        }
    }

    // MARK: Fixtures

    /// Four slurred quarters at a stated `<divisions>` setting, at 120 BPM.
    private static func slurredQuarters(divisions: Int) -> Data {
        let pitches = ["C5", "D5", "E5", "F5"]
        var items: [ScoreXML.Item] = [
            .attributes(
                ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
            ),
            .direction(ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"]))
        ]
        for (index, pitch) in pitches.enumerated() {
            var notations: [String] = []
            if index == 0 { notations.append(ScoreXML.Notation.slurStart()) }
            if index == pitches.count - 1 { notations.append(ScoreXML.Notation.slurStop()) }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: pitch, duration: divisions, type: "quarter", notations: notations
                    )
                )
            )
        }
        return ScoreXML.Score(
            workTitle: "Slurred Quarters",
            parts: [
                ScoreXML.Part(
                    id: "P1", name: "Flute",
                    measures: [ScoreXML.Measure(number: "1", items: items)]
                )
            ]
        ).data()
    }

    /// One measure of unslurred quarters at 120 BPM — staccato, tenuto, then
    /// two plain — written at the given division setting, so the same music
    /// reaches the realizer on four different tick grids.
    private static func articulatedQuarters(divisions: Int) -> Data {
        let notes: [(pitch: String, articulations: [String])] = [
            ("C5", ["staccato"]), ("D5", ["tenuto"]), ("E5", []), ("F5", [])
        ]
        var items: [ScoreXML.Item] = [
            .attributes(
                ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
            ),
            .direction(ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"]))
        ]
        for note in notes {
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: note.pitch,
                        duration: divisions,
                        type: "quarter",
                        notations: note.articulations.isEmpty
                            ? [] : [ScoreXML.Notation.articulations(note.articulations)]
                    )
                )
            )
        }
        return ScoreXML.Score(
            workTitle: "Articulated Quarters",
            parts: [
                ScoreXML.Part(
                    id: "P1", name: "Flute",
                    measures: [ScoreXML.Measure(number: "1", items: items)]
                )
            ]
        ).data()
    }

    /// One measure of slurred thirty-seconds at 120 BPM: each note sounds about
    /// sixteen milliseconds, which is under eight times the full overlap.
    private static func slurredThirtySeconds() -> Data {
        let pitches = ["C5", "D5", "E5", "F5", "G5", "A5", "B5", "C6"]
        let divisions = 8
        var items: [ScoreXML.Item] = [
            .attributes(
                ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4), clefs: [("G", 2)])
            ),
            .direction(ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"]))
        ]
        for index in 0..<32 {
            var notations: [String] = []
            if index == 0 { notations.append(ScoreXML.Notation.slurStart()) }
            if index == 31 { notations.append(ScoreXML.Notation.slurStop()) }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: pitches[index % pitches.count],
                        duration: 1,
                        type: "32nd",
                        notations: notations
                    )
                )
            )
        }
        return ScoreXML.Score(
            workTitle: "Slurred Thirty-Seconds",
            parts: [
                ScoreXML.Part(
                    id: "P1", name: "Piccolo",
                    measures: [ScoreXML.Measure(number: "1", items: items)]
                )
            ]
        ).data()
    }

    /// Four quarters under one slur, every one of them also marked staccato.
    private static func staccatoUnderASlur() -> Data {
        let pitches = ["C5", "D5", "E5", "F5"]
        var items: [ScoreXML.Item] = [
            .attributes(
                ScoreXML.Attributes(
                    divisions: MusicXMLScoreFixtures.divisions,
                    fifths: 0,
                    time: (4, 4),
                    clefs: [("G", 2)]
                )
            ),
            .direction(ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"]))
        ]
        for (index, pitch) in pitches.enumerated() {
            var notations = [ScoreXML.Notation.articulations(["staccato"])]
            if index == 0 { notations.append(ScoreXML.Notation.slurStart()) }
            if index == pitches.count - 1 { notations.append(ScoreXML.Notation.slurStop()) }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: pitch,
                        duration: MusicXMLScoreFixtures.quarter,
                        type: "quarter",
                        notations: notations
                    )
                )
            )
        }
        return ScoreXML.Score(
            workTitle: "Portato",
            parts: [
                ScoreXML.Part(
                    id: "P1", name: "Oboe",
                    measures: [ScoreXML.Measure(number: "1", items: items)]
                )
            ]
        ).data()
    }
}
