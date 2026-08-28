import XCTest
@testable import SynthKit

/// The acceptance criteria of PLY001, one test apiece, plus the parsing
/// behaviour they rest on.
///
/// Every assertion runs against a crafted MusicXML fixture from
/// `MusicXMLScoreFixtures` rather than a checked-in binary score, so a failure
/// points at a readable input.
final class ScoreCompilerTests: XCTestCase {
    private let compiler = ScoreCompiler()

    private func compile(_ data: Data, pieceID: String = "piece-1") throws -> CompiledScore {
        try compiler.compile(pieceID: pieceID, musicXML: data)
    }

    /// The played measure numbers, in order — the shape a golden test on
    /// structure should actually assert.
    private func playedMeasureNumbers(_ score: CompiledScore) -> [String] {
        score.playbackMeasures.map { score.sourceMeasures[$0.sourceMeasureIndex].number }
    }

    // MARK: Acceptance — structural expansion

    func testRepeatsVoltasAndDaCapoExpandToTheNotatedPlaybackOrder() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())

        // 1 2 3 [4 ×repeat back to 2] 2 3 [5, second ending] 6 7 8
        // then D.C. back to 1 and stop at the Fine in measure 3.
        XCTAssertEqual(
            playedMeasureNumbers(score),
            ["1", "2", "3", "4", "2", "3", "5", "6", "7", "8", "1", "2", "3"]
        )
        XCTAssertEqual(score.sourceMeasures.count, 8, "the notated score is still eight measures")
    }

    func testTheSecondPassThroughARepeatIsMarkedAsSuch() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        let measureTwo = score.playbackMeasures.filter {
            score.sourceMeasures[$0.sourceMeasureIndex].number == "2"
        }
        XCTAssertEqual(measureTwo.map(\.pass), [1, 2, 3])
    }

    func testAFirstEndingIsSkippedOnTheSecondPassAndNotAtAllOnTheFirst() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        let played = playedMeasureNumbers(score)
        XCTAssertEqual(played.filter { $0 == "4" }.count, 1, "the first ending is played once")
        XCTAssertEqual(played.filter { $0 == "5" }.count, 1, "the second ending is played once")
    }

    func testPlaybackMeasuresAreContiguousOnTheTickTimeline() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        var expectedStart = 0
        for measure in score.playbackMeasures {
            XCTAssertEqual(measure.startTicks, expectedStart)
            expectedStart += measure.durationTicks
        }
        XCTAssertEqual(score.totalTicks, expectedStart)
    }

    func testDalSegnoAlCodaJumpsBackThenOutToTheCoda() throws {
        let score = try compile(MusicXMLScoreFixtures.dalSegnoAlCoda())
        XCTAssertEqual(
            playedMeasureNumbers(score),
            ["1", "2", "3", "4", "5", "6", "2", "3", "4", "7", "8"]
        )
    }

    func testToCodaIsInertUntilAJumpHasHappened() throws {
        let score = try compile(MusicXMLScoreFixtures.dalSegnoAlCoda())
        let played = playedMeasureNumbers(score)
        // Measure 5 comes after the To Coda on the first pass and is skipped
        // on the second: the marking only takes effect after the D.S.
        XCTAssertEqual(played.filter { $0 == "5" }.count, 1)
        XCTAssertEqual(played.firstIndex(of: "7"), 9, "the coda is only reached at the end")
    }

    /// The same forms, written the way an engraver who never adds a `<sound>`
    /// element writes them: as printed words alone.
    func testJumpsWrittenOnlyAsWordsAreStillHonoured() throws {
        let score = try compile(Self.wordsOnlyDaCapoAlFine())
        XCTAssertEqual(playedMeasureNumbers(score), ["1", "2", "3", "4", "1", "2"])
    }

    /// "D.C. al Fine" names where the jump *ends*; the Fine itself is printed
    /// on an earlier bar. Reading the tail of the instruction as a Fine at the
    /// D.C. measure would stop the piece one bar too late.
    func testTheTailOfAJumpInstructionIsNotMistakenForAMarkAtThatMeasure() throws {
        let score = try compile(Self.wordsOnlyDaCapoAlFine())
        // Measure 4 carries "D.C. al Fine". It is played once, on the way to
        // the jump, and the piece stops at the Fine in measure 2.
        XCTAssertEqual(playedMeasureNumbers(score).filter { $0 == "4" }.count, 1)
        XCTAssertEqual(playedMeasureNumbers(score).last, "2")
    }

    /// Four measures: a Fine printed on measure 2 and "D.C. al Fine" on
    /// measure 4, both as words with no `<sound>` element anywhere.
    private static func wordsOnlyDaCapoAlFine() -> Data {
        let measures = (1...4).map { number -> ScoreXML.Measure in
            var items: [ScoreXML.Item] = []
            if number == 1 {
                items.append(.attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))))
            }
            if number == 2 { items.append(.direction(ScoreXML.Direction(words: "Fine"))) }
            if number == 4 { items.append(.direction(ScoreXML.Direction(words: "D.C. al Fine"))) }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole")))
            return ScoreXML.Measure(number: String(number), items: items)
        }
        return ScoreXML.Score(
            parts: [ScoreXML.Part(id: "P1", name: "Keyboard", measures: measures)]
        ).data()
    }

    // MARK: Acceptance — line identity

    func testAFugueYieldsOneLinePerVoice() throws {
        let score = try compile(MusicXMLScoreFixtures.keyboardFugueExposition())

        XCTAssertEqual(score.lines.count, 4, "four fugal voices, not two staves")
        XCTAssertEqual(score.lines.map(\.voice), ["1", "2", "5", "6"])
        XCTAssertEqual(score.lines.map(\.staff), [1, 1, 2, 2])
        XCTAssertEqual(
            score.lines.map(\.name),
            [
                "Piano, staff 1, voice 1",
                "Piano, staff 1, voice 2",
                "Piano, staff 2, voice 5",
                "Piano, staff 2, voice 6"
            ]
        )
    }

    func testLineIdentifiersAreIdenticalAcrossRecompilation() throws {
        let data = MusicXMLScoreFixtures.keyboardFugueExposition()
        let first = try compile(data)
        let second = try compile(data)
        XCTAssertEqual(first.lines.map(\.id), second.lines.map(\.id))
    }

    /// The identity that presets depend on: adding music later in the piece
    /// must not renumber the lines that were already there.
    func testLineIdentifiersDoNotDependOnHowMuchMusicFollows() throws {
        let short = try compile(MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 10))
        let long = try compile(MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 24))
        XCTAssertEqual(short.lines.map(\.id), long.lines.map(\.id))
    }

    func testALineIdentifierIsDerivedOnlyFromPartStaffAndVoice() throws {
        let score = try compile(MusicXMLScoreFixtures.keyboardFugueExposition())
        for line in score.lines {
            XCTAssertEqual(
                line.id,
                ScoreLineID(partID: line.partID, staff: line.staff, voice: line.voice)
            )
        }
    }

    func testEachInstrumentOfAQuartetIsItsOwnLine() throws {
        let score = try compile(MusicXMLScoreFixtures.stringQuartetMovement())
        XCTAssertEqual(score.lines.map(\.name), ["Violin I", "Violin II", "Viola", "Cello"])
        XCTAssertEqual(Set(score.lines.map(\.id)).count, 4)
    }

    // MARK: Acceptance — the honoured-notation report

    func testAnUnsupportedMarkingIsReportedByNameAndLocation() throws {
        let score = try compile(MusicXMLScoreFixtures.unsupportedMarking())

        let entry = try XCTUnwrap(score.report.entries.first { $0.kind == "ornament: schleifer" })
        XCTAssertEqual(entry.category, .notHonored)
        XCTAssertEqual(entry.firstLocation.measureNumber, "2")
        XCTAssertEqual(entry.firstLocation.partName, "Recorder")
        XCTAssertEqual(entry.occurrenceCount, 1)
        XCTAssertEqual(entry.displayText, "ornament: schleifer at Recorder, measure 2")
    }

    func testRepeatedUnsupportedMarkingsAggregateIntoOneEntryWithACount() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatedUnsupportedMarkingAcrossParts())
        let bowings = score.report.entries.filter { $0.kind == "technique: up-bow" }

        XCTAssertEqual(bowings.count, 4, "one entry per part, not one per marking")
        XCTAssertTrue(bowings.allSatisfy { $0.occurrenceCount == 8 })
        XCTAssertEqual(Set(bowings.map(\.firstLocation.partName)).count, 4)
    }

    /// The quartet's slurs are realised now, so the reference set's most
    /// heavily marked score reports nothing at all. That is the point: the
    /// report is a list of what the owner is *missing*.
    func testTheQuartetsSlursAreRealisedAndThereforeUnreported() throws {
        let score = try compile(MusicXMLScoreFixtures.stringQuartetMovement())
        XCTAssertTrue(
            score.report.isEmpty,
            "unexpected report entries: \(score.report.entries.map(\.kind))"
        )
        XCTAssertTrue(
            score.lines.allSatisfy { line in line.notes.contains { $0.slurStartCount > 0 } },
            "every part carries slurs and every part must have captured them"
        )
    }

    func testAnOrdinaryScoreWithNoExoticNotationReportsNothing() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        XCTAssertTrue(
            score.report.isEmpty,
            "unexpected report entries: \(score.report.entries.map(\.kind))"
        )
    }

    func testReportOrderIsCanonicalRatherThanDictionaryOrder() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatedUnsupportedMarkingAcrossParts())
        XCTAssertFalse(score.report.entries.isEmpty, "the ordering claim needs entries to order")
        let keys = score.report.entries.map { "\($0.category.rawValue)|\($0.kind)" }
        XCTAssertEqual(keys, keys.sorted(), "entries must be emitted in canonical order")
    }

    // MARK: Acceptance — determinism

    func testCompilingTheSamePieceTwiceIsByteIdentical() throws {
        let data = MusicXMLScoreFixtures.stringQuartetMovement()
        let first = try compile(data).canonicalData()
        let second = try compile(data).canonicalData()
        XCTAssertEqual(first, second)
    }

    func testDeterminismHoldsForTheDenseOrchestralReference() throws {
        let data = MusicXMLScoreFixtures.orchestralExcerpt()
        let first = try compile(data)
        let second = try compile(data)
        XCTAssertEqual(try first.canonicalData(), try second.canonicalData())
        XCTAssertEqual(first, second)
    }

    func testDeterminismHoldsWhenStructureAndFermatasAreInvolved() throws {
        let repeats = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        let tempo = MusicXMLScoreFixtures.tempoChangesAndFermata()
        XCTAssertEqual(try compile(repeats).canonicalData(), try compile(repeats).canonicalData())
        XCTAssertEqual(try compile(tempo).canonicalData(), try compile(tempo).canonicalData())
    }

    func testTheCompiledModelPinsTheExactBytesItCameFrom() throws {
        let data = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        let score = try compile(data)
        XCTAssertEqual(score.contentSHA256, MusicXMLImporter.sha256Hex(data))
        XCTAssertEqual(score.pieceID, "piece-1")
    }

    // MARK: Failure and edge behaviour

    func testContradictoryNotationStillProducesPlayableMusicAndSaysWhatItDid() throws {
        let score = try compile(MusicXMLScoreFixtures.contradictoryStructure())

        XCTAssertFalse(score.playbackMeasures.isEmpty, "playback must never become impossible")
        XCTAssertEqual(playedMeasureNumbers(score), ["1", "2", "1", "2", "3", "4", "5"])

        let fallbacks = score.report.entries(in: .structuralFallback).map(\.kind)
        XCTAssertTrue(fallbacks.contains("unmatched backward repeat"), "got \(fallbacks)")
        XCTAssertTrue(fallbacks.contains("unclosed forward repeat"), "got \(fallbacks)")
        XCTAssertTrue(fallbacks.contains("dal segno without a segno sign"), "got \(fallbacks)")
    }

    func testAnOrdinaryVoltaDoesNotLookLikeAnUnclosedRepeat() throws {
        let score = try compile(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        XCTAssertFalse(score.report.mentions(kind: "unclosed forward repeat"))
    }

    func testRunawayStructureIsTruncatedAndReportedRatherThanHanging() throws {
        // A backward repeat asking for a thousand passes over three measures:
        // legal MusicXML, and far past anything an owner meant.
        var measures: [ScoreXML.Measure] = []
        for index in 0..<3 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(.attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))))
                items.append(.barline(.forwardRepeat()))
            }
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole")))
            if index == 2 { items.append(.barline(.backwardRepeat(times: 100_000))) }
            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }
        let data = ScoreXML.Score(
            parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]
        ).data()

        let score = try compile(data)
        XCTAssertEqual(score.playbackMeasures.count, 4_000, "expansion stops at the budget")
        XCTAssertTrue(score.report.mentions(kind: "runaway repeat structure"))
    }

    /// Every number in these files comes from outside. A value too large for
    /// the arithmetic downstream must be clipped and reported, never
    /// multiplied into an overflow.
    func testAbsurdNumbersInTheFileAreClippedRatherThanTrappingTheProcess() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(
                        divisions: 4,
                        fifths: 0,
                        time: (4, 4),
                        transposeChromatic: 9_000_000_000_000_000_000
                    )
                ),
                .raw("<note><pitch><step>C</step><alter>1e400</alter><octave>4</octave></pitch>"
                     + "<duration>9000000000000000000</duration><voice>1</voice></note>"),
                .raw("<note><pitch><step>C</step><octave>4000000000</octave></pitch>"
                     + "<duration>4</duration><voice>1</voice></note>")
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )

        XCTAssertTrue(score.report.mentions(kind: "impossible duration"))
        XCTAssertTrue(score.report.mentions(kind: "unreadable pitch"))
        XCTAssertFalse(score.playbackMeasures.isEmpty)
    }

    func testAnAbsurdTimeSignatureIsIgnoredRatherThanOverflowingTheTimeline() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .raw("<attributes><divisions>4</divisions>"
                     + "<time><beats>9000000000000000000</beats><beat-type>4</beat-type></time>"
                     + "</attributes>"),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertNil(score.sourceMeasures[0].timeSignature)
        XCTAssertEqual(score.sourceMeasures[0].durationTicks, 16, "the written content still decides")
    }

    func testAMeasureLongerThanAnyMusicIsClippedAndReported() throws {
        // 2,000 whole notes in one bar, past the thousand-whole-note ceiling.
        var items: [ScoreXML.Item] = [
            .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4)))
        ]
        for _ in 0..<2_000 {
            items.append(.note(ScoreXML.Note(pitch: "C4", duration: 16)))
        }
        let score = try compile(
            ScoreXML.Score(
                parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [ScoreXML.Measure(number: "1", items: items)])]
            ).data()
        )

        XCTAssertTrue(score.report.mentions(kind: "impossible measure length"))
        XCTAssertEqual(score.sourceMeasures[0].durationTicks, score.ticksPerQuarter * 4 * 1024)
    }

    func testAnUnreasonableDivisionsValueIsIgnoredRatherThanDrivingTheGrid() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .raw("<attributes><divisions>4000000000</divisions></attributes>"),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertEqual(score.ticksPerQuarter, 4)
    }

    func testDamagedStoredContentIsRejectedWithAReadableReason() {
        let truncated = Data("<score-partwise><part id=\"P1\">".utf8)
        XCTAssertThrowsError(try compile(truncated)) { error in
            guard case ScoreCompilationError.notWellFormedXML = error else {
                return XCTFail("expected notWellFormedXML, got \(error)")
            }
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?.contains("damaged") == true
            )
        }
    }

    func testAWellFormedNonScoreIsRejectedByItsRootElement() {
        let notAScore = Data(#"<?xml version="1.0"?><opus><score/></opus>"#.utf8)
        XCTAssertThrowsError(try compile(notAScore)) { error in
            XCTAssertEqual(error as? ScoreCompilationError, .notAMusicXMLScore(rootElement: "opus"))
        }
    }

    func testAScoreWithNoPartsIsRejectedRatherThanCompiledEmpty() {
        let empty = Data(#"<score-partwise version="4.0"><part-list/></score-partwise>"#.utf8)
        XCTAssertThrowsError(try compile(empty)) { error in
            XCTAssertEqual(error as? ScoreCompilationError, .noParts)
        }
    }

    // MARK: Note reading

    func testVoicesInOnePartAreSeparatedByBackupRatherThanMerged() throws {
        let score = try compile(MusicXMLScoreFixtures.keyboardFugueExposition())
        let soprano = try XCTUnwrap(score.lines.first { $0.voice == "1" })
        let bass = try XCTUnwrap(score.lines.first { $0.voice == "6" })

        // Every voice covers all ten measures — the resting ones with rests.
        XCTAssertEqual(Set(soprano.notes.map(\.sourceMeasureIndex)).count, 10)
        XCTAssertEqual(Set(bass.notes.map(\.sourceMeasureIndex)).count, 10)
        // And each voice restarts at tick 0 of its measure, which is what the
        // <backup> elements are for.
        XCTAssertEqual(soprano.notes.first?.startTicks, 0)
        XCTAssertEqual(bass.notes.first?.startTicks, 0)
    }

    func testChordMembersShareAnOnsetAndDoNotAdvanceTheMeasure() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole")),
                .note(ScoreXML.Note(pitch: "E4", duration: 16, type: "whole", isChord: true)),
                .note(ScoreXML.Note(pitch: "G4", duration: 16, type: "whole", isChord: true))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )

        let line = try XCTUnwrap(score.lines.first)
        XCTAssertEqual(line.notes.map(\.startTicks), [0, 0, 0])
        XCTAssertEqual(line.notes.map(\.isChordMember), [false, true, true])
        XCTAssertEqual(score.sourceMeasures[0].durationTicks, 16, "a chord is one measure, not three")
    }

    func testATransposingPartIsCompiledAtSoundingPitch() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(
                    ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4), transposeChromatic: -2)
                ),
                .note(ScoreXML.Note(pitch: "D4", duration: 16, type: "whole"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(
                parts: [ScoreXML.Part(id: "P1", name: "Clarinet in B♭", measures: [measure])]
            ).data()
        )

        let pitch = try XCTUnwrap(score.lines.first?.notes.first?.pitch)
        XCTAssertEqual(pitch.midiNoteNumber, 60, "written D4 on a B♭ clarinet sounds C4")
    }

    func testTiesAreRecordedForTheRealisationStageToJoin() throws {
        let measures = [
            ScoreXML.Measure(
                number: "1",
                items: [
                    .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                    .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole", tieStart: true))
                ]
            ),
            ScoreXML.Measure(
                number: "2",
                items: [.note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole", tieStop: true))]
            )
        ]
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: measures)]).data()
        )

        let notes = try XCTUnwrap(score.lines.first?.notes)
        XCTAssertEqual(notes.map(\.tiesForward), [true, false])
        XCTAssertEqual(notes.map(\.tiesBackward), [false, true])
    }

    func testAPickupMeasureIsAsShortAsItIsWritten() throws {
        let score = try compile(MusicXMLScoreFixtures.tempoChangesAndFermata())
        XCTAssertTrue(score.sourceMeasures[0].isPickup)
        XCTAssertEqual(score.sourceMeasures[0].durationTicks, score.ticksPerQuarter)
        XCTAssertEqual(score.sourceMeasures[1].durationTicks, score.ticksPerQuarter * 4)
    }

    func testAVoiceThatOnlySpacesTheStaffIsNotOfferedAsALine() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole", voice: "1")),
                .backup(16),
                .note(ScoreXML.Note(pitch: nil, duration: 16, type: "whole", voice: "2"))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )
        XCTAssertEqual(score.lines.map(\.voice), ["1"])
    }

    func testDifferentDivisionsInDifferentPartsLandOnOneTickGrid() throws {
        func part(id: String, divisions: Int, noteDuration: Int) -> ScoreXML.Part {
            ScoreXML.Part(
                id: id,
                name: "Part \(id)",
                measures: [
                    ScoreXML.Measure(
                        number: "1",
                        items: [
                            .attributes(
                                ScoreXML.Attributes(divisions: divisions, fifths: 0, time: (4, 4))
                            ),
                            .note(ScoreXML.Note(pitch: "C4", duration: noteDuration, type: "whole"))
                        ]
                    )
                ]
            )
        }
        let score = try compile(
            ScoreXML.Score(
                parts: [part(id: "P1", divisions: 4, noteDuration: 16),
                        part(id: "P2", divisions: 6, noteDuration: 24)]
            ).data()
        )

        XCTAssertEqual(score.ticksPerQuarter, 12, "the least common multiple of 4 and 6")
        XCTAssertEqual(score.sourceMeasures[0].durationTicks, 48)
        for line in score.lines {
            XCTAssertEqual(line.notes.first?.durationTicks, 48)
        }
    }

    func testAGraceNoteIsAttachedToItsPrincipalAndACueNoteIsReported() throws {
        let measure = ScoreXML.Measure(
            number: "1",
            items: [
                .attributes(ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4))),
                .note(ScoreXML.graceNote(pitch: "B3", type: "16th", slashed: true)),
                .note(ScoreXML.Note(pitch: "C4", duration: 16, type: "whole")),
                .backup(16),
                .note(ScoreXML.Note(pitch: "E5", duration: 16, voice: "3", extraChildren: ["<cue/>"]))
            ]
        )
        let score = try compile(
            ScoreXML.Score(parts: [ScoreXML.Part(id: "P1", name: "Piano", measures: [measure])]).data()
        )

        // PLY002 sounds grace notes, so a grace note is captured on the note
        // it ornaments rather than reported as lost.
        XCTAssertFalse(score.report.mentions(kind: "grace note"))
        let principal = try XCTUnwrap(score.lines.first?.notes.first)
        XCTAssertEqual(principal.graceNotes.count, 1)
        XCTAssertEqual(principal.graceNotes.first?.pitch.step, "B")
        XCTAssertEqual(principal.graceNotes.first?.isAcciaccatura, true)

        XCTAssertTrue(score.report.mentions(kind: "cue note"))
        XCTAssertEqual(score.lines.count, 1, "neither becomes a line of its own")
    }

    // MARK: Timewise scores

    func testAScoreTimewiseDocumentCompilesLikeItsPartwiseTwin() throws {
        let partwise = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        let timewise = try Self.timewise(fromPartwise: partwise)

        let fromPartwise = try compile(partwise)
        let fromTimewise = try compile(timewise)

        XCTAssertEqual(playedMeasureNumbers(fromPartwise), playedMeasureNumbers(fromTimewise))
        XCTAssertEqual(fromPartwise.lines.map(\.id), fromTimewise.lines.map(\.id))
        XCTAssertEqual(
            fromPartwise.lines.map { $0.notes.map(\.pitch) },
            fromTimewise.lines.map { $0.notes.map(\.pitch) }
        )
    }

    /// Rewrites a partwise fixture as timewise, so both encodings of the same
    /// music can be compared without hand-writing a second fixture.
    private static func timewise(fromPartwise data: Data) throws -> Data {
        let root = try MusicXMLDocument.parse(data)
        let parts = root.childrenNamed("part")
        let measureCount = parts.map { $0.childrenNamed("measure").count }.max() ?? 0

        var xml = #"<?xml version="1.0" encoding="UTF-8"?><score-timewise version="4.0">"#
        if let list = root.child("part-list") {
            xml += Self.serialize(list)
        }
        for index in 0..<measureCount {
            let number = parts.first?.childrenNamed("measure")[index].attribute("number") ?? "\(index + 1)"
            xml += #"<measure number="\#(number)">"#
            for part in parts {
                let measures = part.childrenNamed("measure")
                guard index < measures.count else { continue }
                xml += #"<part id="\#(part.attribute("id") ?? "")">"#
                xml += measures[index].children.map(Self.serialize).joined()
                xml += "</part>"
            }
            xml += "</measure>"
        }
        xml += "</score-timewise>"
        return Data(xml.utf8)
    }

    private static func serialize(_ element: MusicXMLElement) -> String {
        let attributes = element.attributes.keys.sorted()
            .map { #" \#($0)="\#(ScoreXML.escape(element.attributes[$0] ?? ""))""# }
            .joined()
        if element.children.isEmpty {
            return element.text.isEmpty
                ? "<\(element.name)\(attributes)/>"
                : "<\(element.name)\(attributes)>\(ScoreXML.escape(element.text))</\(element.name)>"
        }
        return "<\(element.name)\(attributes)>"
            + element.children.map(Self.serialize).joined()
            + "</\(element.name)>"
    }
}
