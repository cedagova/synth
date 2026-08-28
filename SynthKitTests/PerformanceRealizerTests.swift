import XCTest
@testable import SynthKit

/// REQ-011: the expressive notation a score carries is audible in the event
/// timeline.
///
/// Every test here runs with humanization **off**. That is not a convenience:
/// these are golden assertions about what the notation means, and mixing the
/// interpretation stage into them would make each one a test of two things and
/// a proof of neither. Humanization has its own suite.
final class PerformanceRealizerTests: XCTestCase {
    private let compiler = ScoreCompiler()
    private let realizer = PerformanceRealizer()

    private func realize(
        _ data: Data,
        settings: RealizationSettings = .literal,
        pieceID: String = "piece"
    ) throws -> PerformanceTimeline {
        realizer.realize(
            try compiler.compile(pieceID: pieceID, musicXML: data),
            settings: settings
        )
    }

    /// The events of one measure of the study fixtures, in time order.
    private func events(
        _ timeline: PerformanceTimeline,
        measure: Int,
        line: Int = 0
    ) -> [PerformanceEvent] {
        timeline.lines[line].events.filter { $0.sourceMeasureIndex == measure }
    }

    // MARK: Acceptance — ornaments realise as their conventional figures

    /// The headline criterion: "a notated trill is audibly realized as
    /// alternating notes, not a single held note."
    func testANotatedTrillAlternatesBetweenThePrincipalAndTheNoteAbove() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        let trill = events(timeline, measure: 0).filter { $0.origin == .ornament }

        XCTAssertGreaterThanOrEqual(trill.count, 5, "a trill is several notes, not one")
        XCTAssertTrue(
            trill.count.isMultiple(of: 2) == false,
            "an odd count is what makes the figure begin and end on the principal"
        )
        XCTAssertEqual(
            trill.map(\.midiNoteNumber),
            (0..<trill.count).map { $0.isMultiple(of: 2) ? 72 : 74 },
            "C5 and D5 alternating, starting and ending on C5"
        )

        // The alternation has to be in time as well as in pitch: onsets strictly
        // increase and the figure covers exactly the note it ornaments.
        let onsets = trill.map(\.onsetTicks)
        XCTAssertEqual(onsets, onsets.sorted())
        XCTAssertEqual(Set(onsets).count, onsets.count, "no two trill notes share an onset")
        XCTAssertEqual(onsets.first, 0)

        let plain = events(timeline, measure: 0).filter { $0.origin == .notated }
        XCTAssertEqual(plain.count, 1, "only the second half note is left unornamented")
    }

    func testAMordentIsPrincipalNoteBelowPrincipal() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        let figure = events(timeline, measure: 1).filter { $0.origin == .ornament }
        XCTAssertEqual(figure.map(\.midiNoteNumber), [72, 71, 72], "C5 B4 C5")
    }

    func testAnInvertedMordentUsesTheNoteAbove() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        let figure = events(timeline, measure: 2).filter { $0.origin == .ornament }
        XCTAssertEqual(figure.map(\.midiNoteNumber), [72, 74, 72], "C5 D5 C5")
    }

    func testATurnIsAbovePrincipalBelowPrincipal() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        let figure = events(timeline, measure: 3).filter { $0.origin == .ornament }
        XCTAssertEqual(figure.map(\.midiNoteNumber), [74, 72, 71, 72], "D5 C5 B4 C5")
    }

    func testAnInvertedTurnMirrorsTheTurn() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        let figure = events(timeline, measure: 4).filter { $0.origin == .ornament }
        XCTAssertEqual(figure.map(\.midiNoteNumber), [71, 72, 74, 72], "B4 C5 D5 C5")
    }

    /// Every figure occupies exactly its principal note's time. A figure that
    /// overran would collide with the next note; one that fell short would
    /// leave a hole the score does not have.
    func testEveryOrnamentFigureFillsExactlyTheNoteItOrnaments() throws {
        let timeline = try realize(MusicXMLScoreFixtures.ornamentStudy())
        // The half note sounds 90% of its written value when nothing shortens
        // it, and the figure inherits exactly that.
        let expected = MusicXMLScoreFixtures.fineHalf * PerformanceRealizer.detachedPercent / 100

        for measure in 0..<5 {
            let figure = events(timeline, measure: measure).filter { $0.origin == .ornament }
            let start = try XCTUnwrap(figure.first).onsetTicks
            var cursor = start
            for step in figure {
                XCTAssertEqual(step.onsetTicks, cursor, "measure \(measure) has a gap or overlap")
                cursor = step.endTicks
            }
            XCTAssertEqual(cursor - start, expected, "measure \(measure)")
        }
    }

    /// A trill's auxiliary note is the next note of the scale, not a tone
    /// above. In E flat major the note above D is E flat.
    func testTheAuxiliaryNoteFollowsTheKeySignature() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(divisions: 24, fifths: -3, time: (4, 4), clefs: [("G", 2)])
                ),
                .note(
                    ScoreXML.Note(
                        pitch: "D5",
                        duration: 96,
                        type: "whole",
                        notations: [ScoreXML.Notation.ornament("inverted-mordent")]
                    )
                )
            ]
        )
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Flute", measures: [measure])]).data()
        )
        XCTAssertEqual(
            timeline.lines[0].events.map(\.midiNoteNumber),
            [74, 75, 74],
            "D5, E flat 5, D5 — three flats in the key make the upper note E flat, not E"
        )
    }

    /// A printed accidental over the sign alters the auxiliary note, which is
    /// what engravers write it for: the letter stays the diatonic neighbour
    /// and the accidental changes its pitch.
    func testAPrintedAccidentalOverTheSignWinsOverTheKey() throws {
        func figure(_ accidental: String?) throws -> [Int] {
            let measure = ScoreXML.Measure(
                number: "1",
                items: [
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                        )
                    ),
                    .note(
                        ScoreXML.Note(
                            pitch: "C5",
                            duration: 96,
                            type: "whole",
                            notations: [
                                ScoreXML.Notation.ornament(
                                    "inverted-mordent", accidental: accidental
                                )
                            ]
                        )
                    )
                ]
            )
            return try realize(
                ScoreXML.Score(
                    parts: [ScoreXML.Part(id: "P1", name: "Flute", measures: [measure])]
                ).data()
            ).lines[0].events.map(\.midiNoteNumber)
        }

        XCTAssertEqual(try figure(nil), [72, 74, 72], "in C major the note above C5 is D5")
        XCTAssertEqual(try figure("flat"), [72, 73, 72], "a printed flat makes it D flat 5")
        XCTAssertEqual(try figure("sharp"), [72, 75, 72], "a printed sharp makes it D sharp 5")
    }

    /// A note too short to hold its figure is sounded plain and said so,
    /// rather than turned into four one-tick events nobody can hear.
    func testAnOrnamentTooShortToRealiseIsReportedAndSoundedPlain() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(divisions: 1, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                ),
                .note(
                    ScoreXML.Note(
                        pitch: "C5",
                        duration: 1,
                        type: "quarter",
                        notations: [ScoreXML.Notation.ornament("turn")]
                    )
                )
            ]
        )
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Flute", measures: [measure])]).data()
        )
        XCTAssertEqual(timeline.lines[0].events.map(\.origin), [.notated])
        XCTAssertTrue(
            timeline.report.mentions(kind: "ornament: turn"),
            "got \(timeline.report.entries.map(\.kind))"
        )
    }

    // MARK: Acceptance — dynamics

    /// "A crescendo produces monotonically evolving loudness parameters across
    /// its span."
    func testACrescendoRaisesTheLoudnessParameterNoteByNote() throws {
        let timeline = try realize(MusicXMLScoreFixtures.hairpinSpan())
        let inSpan = timeline.lines[0].events.filter { $0.sourceMeasureIndex < 2 }
        XCTAssertEqual(inSpan.count, 16, "sixteen eighth notes lie under the hairpin")

        let velocities = inSpan.map(\.velocity)
        XCTAssertEqual(velocities, velocities.sorted(), "loudness never steps backwards")
        for (index, pair) in zip(velocities, velocities.dropFirst()).enumerated() {
            XCTAssertGreaterThan(pair.1, pair.0, "note \(index + 1) is not louder than note \(index)")
        }
        XCTAssertEqual(velocities.first, ScoreDynamic.p.sustainedLevel, "it starts at the printed p")
        XCTAssertEqual(
            timeline.lines[0].events.filter { $0.sourceMeasureIndex == 2 }.map(\.velocity),
            Array(repeating: ScoreDynamic.f.sustainedLevel ?? 0, count: 8),
            "and arrives at the printed f, then holds it"
        )
    }

    func testADiminuendoLowersItByTheSameRule() throws {
        let timeline = try realize(MusicXMLScoreFixtures.hairpinSpan(diminuendo: true))
        let inSpan = timeline.lines[0].events.filter { $0.sourceMeasureIndex < 2 }
        let velocities = inSpan.map(\.velocity)

        XCTAssertEqual(velocities, velocities.sorted(by: >), "loudness never steps forwards")
        XCTAssertEqual(velocities.first, ScoreDynamic.f.sustainedLevel)
        XCTAssertLessThan(try XCTUnwrap(velocities.last), try XCTUnwrap(velocities.first))
    }

    func testAScoreWithNoDynamicsPlaysAtTheDefaultLevel() throws {
        let timeline = try realize(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        XCTAssertTrue(
            timeline.lines[0].events.allSatisfy { $0.velocity == PerformanceRealizer.defaultVelocity },
            "an unmarked score is played mezzo-forte throughout"
        )
    }

    /// Overlapping hairpins contradict each other. The documented conservative
    /// rule applies and the owner is told, per the issue's failure behaviour.
    func testOverlappingHairpinsResolveConservativelyAndAreReported() throws {
        let measures = (0..<4).map { index -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(.dynamic("p")))
                items.append(.direction(.wedge("crescendo")))
            }
            if index == 1 { items.append(.direction(.wedge("crescendo"))) }
            if index == 3 { items.append(.direction(.wedge("stop"))) }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 96, type: "whole")))
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Horn", measures: measures)]).data()
        )

        XCTAssertTrue(
            timeline.report.mentions(kind: "overlapping hairpins"),
            "got \(timeline.report.entries.map(\.kind))"
        )
        let velocities = timeline.lines[0].events.map(\.velocity)
        XCTAssertEqual(velocities, velocities.sorted(), "the result is still a rising line")
    }

    func testAnAccentDynamicColoursOneNoteWithoutChangingTheLevel() throws {
        let measures = (0..<3).map { index -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(.dynamic("p")))
            }
            if index == 1 { items.append(.direction(.dynamic("sf"))) }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 96, type: "whole")))
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Horn", measures: measures)]).data()
        )

        let quiet = ScoreDynamic.p.sustainedLevel ?? 0
        XCTAssertEqual(
            timeline.lines[0].events.map(\.velocity),
            [quiet, quiet + ScoreDynamic.sf.momentaryBoost, quiet],
            "the sforzando is one loud note, and the piano resumes after it"
        )
    }

    // MARK: Acceptance — articulations and slurs

    func testStaccatoShortensAndAccentStrengthensAgainstThePlainReading() throws {
        let timeline = try realize(MusicXMLScoreFixtures.articulationAndSlurStudy())

        let plain = try XCTUnwrap(events(timeline, measure: 0).first)
        let staccato = try XCTUnwrap(events(timeline, measure: 1).first)
        let accented = try XCTUnwrap(events(timeline, measure: 3).first)
        let tenuto = try XCTUnwrap(events(timeline, measure: 4).first)

        // Measured on the tick grid against the written quarter, because that
        // is what the convention is stated in: half its value for a staccato,
        // all of it for a tenuto, a small gap for a plain note.
        let written = MusicXMLScoreFixtures.fineQuarter
        XCTAssertEqual(plain.durationTicks, written * PerformanceRealizer.detachedPercent / 100)
        XCTAssertEqual(staccato.durationTicks, written / 2, "a staccato quarter is half its value")
        XCTAssertEqual(tenuto.durationTicks, written, "a tenuto note is held its full value")
        XCTAssertEqual(accented.durationTicks, plain.durationTicks, "an accent is not a length")

        XCTAssertLessThan(staccato.durationMicroseconds, plain.durationMicroseconds)
        XCTAssertGreaterThan(tenuto.durationMicroseconds, plain.durationMicroseconds)

        XCTAssertEqual(staccato.velocity, plain.velocity, "staccato is a length, not a loudness")
        XCTAssertGreaterThan(accented.velocity, plain.velocity)
    }

    /// Legato is an overlap the engine can bind, not merely a longer note.
    func testSlurredNotesOverlapTheNoteTheyRunInto() throws {
        let timeline = try realize(MusicXMLScoreFixtures.articulationAndSlurStudy())
        let slurred = events(timeline, measure: 2)
        XCTAssertEqual(slurred.count, 4)

        for (note, next) in zip(slurred, slurred.dropFirst()) {
            XCTAssertGreaterThan(
                note.endMicroseconds,
                next.onsetMicroseconds,
                "each slurred note must still be sounding when the next begins"
            )
        }
        XCTAssertLessThan(
            try XCTUnwrap(slurred.last).durationMicroseconds,
            try XCTUnwrap(slurred.first).durationMicroseconds,
            "the last note of the slur has nothing to run into and is released"
        )
    }

    /// Staccato under a slur is portato: the shortening wins, because that is
    /// what the combination means.
    func testAShorteningArticulationWinsOverASlur() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                ),
                .note(
                    ScoreXML.Note(
                        pitch: "C4",
                        duration: 24,
                        type: "quarter",
                        notations: [
                            ScoreXML.Notation.slurStart(),
                            ScoreXML.Notation.articulations(["staccato"])
                        ]
                    )
                ),
                .note(
                    ScoreXML.Note(
                        pitch: "D4",
                        duration: 24,
                        type: "quarter",
                        notations: [ScoreXML.Notation.slurStop()]
                    )
                ),
                .note(ScoreXML.Note(pitch: "E4", duration: 48, type: "half"))
            ]
        )
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Oboe", measures: [measure])]).data()
        )
        let first = try XCTUnwrap(timeline.lines[0].events.first)
        let second = timeline.lines[0].events[1]
        XCTAssertLessThan(
            first.endMicroseconds,
            second.onsetMicroseconds,
            "the staccato note is released before the next, slur or no slur"
        )
    }

    // MARK: Acceptance — pedal

    func testPedalMarkingsBecomeSpansOnEveryLineOfTheirStaff() throws {
        let timeline = try realize(MusicXMLScoreFixtures.pedalStudy())
        let spans = timeline.lines[0].pedalSpans

        XCTAssertEqual(
            spans.map { [$0.startTicks, $0.endTicks] },
            [[0, 96], [96, 192]],
            "down, changed at the second measure, released at the third"
        )
        XCTAssertTrue(spans.allSatisfy { $0.endMicroseconds > $0.startMicroseconds })
        XCTAssertFalse(
            spans.contains { $0.contains(microseconds: spans[1].endMicroseconds) },
            "nothing is pedalled after the release"
        )
    }

    func testAPedalThatIsNeverReleasedIsHeldToTheEndAndReported() throws {
        let measures = (0..<2).map { index -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(.pedal("start")))
            }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 96, type: "whole")))
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]).data()
        )
        XCTAssertEqual(timeline.lines[0].pedalSpans.map(\.endTicks), [timeline.totalTicks])
        XCTAssertTrue(timeline.report.mentions(kind: "pedal never released"))
    }

    // MARK: Acceptance — grace notes

    func testAnAcciaccaturaIsCrushedAgainstTheBeatAndTheAppoggiaturaLeansOnIt() throws {
        let timeline = try realize(MusicXMLScoreFixtures.graceNoteStudy())

        let crushed = events(timeline, measure: 0)
        XCTAssertEqual(crushed.map(\.origin), [.grace, .notated, .notated])
        XCTAssertEqual(crushed[0].midiNoteNumber, 71, "the printed B4")
        XCTAssertEqual(crushed[0].onsetTicks, 0, "it starts on the beat")
        XCTAssertEqual(crushed[1].onsetTicks, 3, "and takes a thirty-second note from the principal")

        let leaning = events(timeline, measure: 1)
        XCTAssertEqual(leaning.map(\.origin), [.grace, .notated, .notated])
        XCTAssertEqual(
            leaning[1].onsetTicks - leaning[0].onsetTicks,
            MusicXMLScoreFixtures.fineQuarter,
            "an appoggiatura printed as a quarter takes a quarter of the principal"
        )
        XCTAssertLessThan(
            leaning[0].velocity,
            leaning[1].velocity,
            "the grace note leans on the principal rather than replacing it"
        )
    }

    func testATwoNoteGraceGroupIsPlayedInOrderBeforeItsPrincipal() throws {
        let timeline = try realize(MusicXMLScoreFixtures.graceNoteStudy())
        let group = events(timeline, measure: 2)
        XCTAssertEqual(group.map(\.origin), [.grace, .grace, .notated, .notated])
        XCTAssertEqual(group.map(\.midiNoteNumber), [69, 71, 72, 67], "A4 B4 then C5, then G4")
        XCTAssertLessThan(group[0].onsetTicks, group[1].onsetTicks)
        XCTAssertLessThan(group[1].onsetTicks, group[2].onsetTicks)
    }

    // MARK: Ties

    func testATiedPairSoundsOnceForItsCombinedLength() throws {
        let measures = (0..<2).map { index -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(ScoreXML.Direction(sound: ["tempo": "60"])))
            }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: "C4",
                        duration: 96,
                        type: "whole",
                        tieStart: index == 0,
                        tieStop: index == 1
                    )
                )
            )
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Cello", measures: measures)]).data()
        )

        XCTAssertEqual(timeline.lines[0].events.count, 1, "one attack, not two")
        let note = try XCTUnwrap(timeline.lines[0].events.first)
        XCTAssertEqual(note.onsetTicks, 0)
        XCTAssertEqual(
            note.durationTicks,
            192 * PerformanceRealizer.detachedPercent / 100,
            "the chain is shaped once, over its combined written length"
        )
        XCTAssertEqual(
            note.durationMicroseconds,
            7_166_667,
            "one hundred and seventy-two ticks at sixty to the quarter"
        )
    }

    // MARK: The expressive reference piece

    /// The increment's expressive reference piece at full density. This is the
    /// test that would notice a rule that works on a two-note fixture and
    /// falls apart on real music.
    func testTheExpressiveReferencePieceRealisesEveryFamilyAtOnce() throws {
        let score = try compiler.compile(
            pieceID: "reference",
            musicXML: MusicXMLScoreFixtures.expressiveKeyboardPiece()
        )
        let timeline = realizer.realize(score, settings: .literal)

        XCTAssertTrue(
            score.report.isEmpty,
            "every marking in it is realised: \(score.report.entries.map(\.kind))"
        )
        XCTAssertTrue(
            timeline.report.isEmpty,
            "and every one of them realises: \(timeline.report.entries.map(\.kind))"
        )
        XCTAssertEqual(timeline.lines.count, 3, "two right-hand voices and one left hand")

        let melody = try XCTUnwrap(timeline.lines.first)
        XCTAssertTrue(melody.events.contains { $0.origin == .ornament }, "ornaments realised")
        XCTAssertTrue(melody.events.contains { $0.origin == .grace }, "grace notes realised")
        XCTAssertGreaterThan(
            Set(melody.events.map(\.velocity)).count,
            1,
            "the hairpins actually move the loudness"
        )

        // The pedal is written under the bass staff and must reach only it.
        XCTAssertTrue(timeline.lines[0].pedalSpans.isEmpty)
        XCTAssertFalse(try XCTUnwrap(timeline.lines.last).pedalSpans.isEmpty)

        // The inner voice is tied in pairs, so it attacks half as often as it
        // has written notes.
        XCTAssertEqual(timeline.lines[1].events.count, 8, "sixteen whole notes tied in pairs")

        XCTAssertTrue(
            timeline.lines.allSatisfy { line in
                zip(line.events, line.events.dropFirst()).allSatisfy {
                    $0.onsetMicroseconds <= $1.onsetMicroseconds
                }
            },
            "every line is delivered in time order"
        )
    }

    /// Repeats replay the expression too: a dynamic inside a repeated section
    /// applies on every pass, because that is what the printed page says.
    func testExpressionInsideARepeatAppliesOnEveryPass() throws {
        let measures = (0..<3).map { index -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(divisions: 24, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                    )
                )
                items.append(.direction(.dynamic("f")))
                items.append(.barline(.forwardRepeat()))
            }
            if index == 1 { items.append(.direction(.dynamic("pp"))) }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 96, type: "whole")))
            if index == 1 { items.append(.barline(.backwardRepeat())) }
            return ScoreXML.Measure(number: String(index + 1), items: items)
        }
        let timeline = try realize(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Horn", measures: measures)]).data()
        )

        XCTAssertEqual(
            timeline.lines[0].events.map(\.velocity),
            [
                ScoreDynamic.f.sustainedLevel, ScoreDynamic.pp.sustainedLevel,
                ScoreDynamic.f.sustainedLevel, ScoreDynamic.pp.sustainedLevel,
                ScoreDynamic.pp.sustainedLevel
            ].compactMap { $0 },
            "the forte returns when the repeat returns to it"
        )
    }

    // MARK: Contract shape

    func testTheTimelineCarriesTheIdentitiesAndProvenanceItsConsumersNeed() throws {
        let score = try compiler.compile(
            pieceID: "piece-7",
            musicXML: MusicXMLScoreFixtures.expressiveKeyboardPiece()
        )
        let timeline = realizer.realize(score, settings: .literal)

        XCTAssertEqual(timeline.pieceID, "piece-7")
        XCTAssertEqual(timeline.contentSHA256, score.contentSHA256)
        XCTAssertEqual(timeline.ticksPerQuarter, score.ticksPerQuarter)
        XCTAssertEqual(timeline.totalTicks, score.totalTicks)
        XCTAssertEqual(timeline.totalMicroseconds, score.totalMicroseconds)
        XCTAssertEqual(timeline.lines.map(\.id), score.lines.map(\.id), "line identity is preserved")
        XCTAssertEqual(timeline.lines.map(\.name), score.lines.map(\.name))
        XCTAssertNotNil(timeline.line(withID: score.lines[0].id))
        XCTAssertTrue(
            timeline.lines.allSatisfy { line in
                line.events.allSatisfy { (1...127).contains($0.velocity) }
            },
            "velocity stays inside the MIDI range whatever the notation asks for"
        )
        XCTAssertTrue(
            timeline.lines.allSatisfy { line in
                line.events.allSatisfy { (0...127).contains($0.midiNoteNumber) }
            }
        )
    }

}
