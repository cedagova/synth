import XCTest
@testable import SynthKit

/// EXP002's balance half: per passage, the musically leading line reads slightly
/// above the accompaniment, and when the texture does not say which line leads,
/// nothing moves.
///
/// **Two layers, deliberately, because the claim has two halves.** The headline
/// is end-to-end on `melodyOverAccompaniment`, a fixture built so the only thing
/// that can separate the two lines' velocities is the balance — which makes
/// "reads above the accompaniment" an exact number rather than a trend. The
/// fallback cases are asserted on `Realization.leadingLine` directly, because
/// "nothing happened" is the claim and reading it off realized velocities would
/// only ever be evidence that nothing *detectable* happened.
///
/// The fallbacks are the expensive failures. Ducking three lines to push forward
/// a part that was never the melody is audible and wrong; leaving a passage
/// alone is inaudible and right. Each test here names the texture it protects.
final class PerformanceBalanceTests: XCTestCase {
    private let compiler = ScoreCompiler()
    private let realizer = PerformanceRealizer()

    private static func expression(amount: Int) -> RealizationSettings {
        RealizationSettings(
            humanization: .off, expression: ExpressionSettings(isEnabled: true, amount: amount)
        )
    }

    private func compile(_ data: Data, id: String = "balance") throws -> CompiledScore {
        try compiler.compile(pieceID: id, musicXML: data)
    }

    /// The balance one realization would apply, per line, without realizing.
    private func balance(
        _ data: Data,
        amount: Int = 100,
        id: String = "balance"
    ) throws -> (score: CompiledScore, balances: [Realization.PassageBalance]) {
        let score = try compile(data, id: id)
        let realization = Realization(score: score, settings: Self.expression(amount: amount))
        let streams = score.lines.map { realization.buildStream($0) }
        return (score, realization.passageBalance(streams: streams))
    }

    // MARK: The criterion — the leading line reads above the accompaniment

    /// At every tick where both lines attack, the melody's realized velocity is
    /// exactly the balance above the accompaniment's — and with expression off
    /// the two are exactly equal.
    ///
    /// The fixture writes one dynamic in both parts, no slur, no articulation and
    /// no rest, and both lines therefore phrase identically: the arch and the
    /// cadential easing are the same number at the same tick for both of them.
    /// So the difference at a shared tick *is* the balance, with nothing to
    /// subtract and no tolerance to argue about.
    func testTheLeadingLineReadsAboveTheAccompanimentAtEverySharedAttack() throws {
        let score = try compile(MusicXMLScoreFixtures.melodyOverAccompaniment())
        XCTAssertEqual(score.lines.count, 2, "one melody, one accompaniment")

        let flat = realizer.realize(
            score, settings: RealizationSettings(humanization: .off, expression: .off)
        )
        let shaped = realizer.realize(score, settings: Self.expression(amount: 100))

        let expected = Realization.maximumBalanceLift + Realization.maximumBalanceDuck
        var compared = 0

        for (state, separation) in [(flat, 0), (shaped, expected)] {
            let melody = Dictionary(
                uniqueKeysWithValues: state.lines[0].events.map { ($0.onsetTicks, $0.velocity) }
            )
            var seen = 0
            for event in state.lines[1].events {
                guard let lead = melody[event.onsetTicks] else { continue }
                XCTAssertEqual(
                    lead - event.velocity, separation,
                    "at tick \(event.onsetTicks) the melody reads \(lead) against the "
                        + "accompaniment's \(event.velocity); expected a separation of "
                        + "\(separation)"
                )
                seen += 1
            }
            XCTAssertGreaterThan(seen, 20, "the fixture must share plenty of attacks")
            compared = seen
        }
        XCTAssertGreaterThan(compared, 20)
    }

    /// The separation rides the expression amount, and is gone at the bottom of
    /// the dial as well as at the switch.
    func testTheBalanceRidesTheExpressionAmount() throws {
        let score = try compile(MusicXMLScoreFixtures.melodyOverAccompaniment())

        func separation(amount: Int) -> Int {
            let state = realizer.realize(score, settings: Self.expression(amount: amount))
            let melody = Dictionary(
                uniqueKeysWithValues: state.lines[0].events.map { ($0.onsetTicks, $0.velocity) }
            )
            for event in state.lines[1].events {
                if let lead = melody[event.onsetTicks] { return lead - event.velocity }
            }
            return 0
        }

        let full = separation(amount: 100)
        let half = separation(amount: 50)
        let zero = separation(amount: 0)

        XCTAssertEqual(
            full, Realization.maximumBalanceLift + Realization.maximumBalanceDuck
        )
        XCTAssertEqual(half, full / 2, "half the amount is half the separation")
        XCTAssertEqual(zero, 0, "amount zero is the same music as off")
        XCTAssertGreaterThan(half, 0, "the default amount must be audible, not a rounding error")
    }

    /// The balance is bounded well inside the notation: the whole separation is
    /// smaller than one printed dynamic step, so a balanced `mp` never reads as
    /// an `mf`, and smaller than the phrase arch it sits inside.
    ///
    /// Measured against the `mp`→`mf` rung rather than the smallest gap anywhere
    /// on the ladder, because the top of the ladder compresses — `fff` to `ffff`
    /// is four velocities and `fffff` to `ffffff` is one, which is the ceiling of
    /// the scale rather than a step a player hears.
    func testTheBalanceStaysInsideWhatTheEngraverWrote() throws {
        let moderatelyLoud = try XCTUnwrap(ScoreDynamic.mf.sustainedLevel)
        let moderatelySoft = try XCTUnwrap(ScoreDynamic.mp.sustainedLevel)
        let step = moderatelyLoud - moderatelySoft
        let separation = Realization.maximumBalanceLift + Realization.maximumBalanceDuck

        XCTAssertLessThan(
            separation, step,
            "the full separation must stay inside the dynamic the engraver wrote"
        )
        XCTAssertLessThan(
            separation, Realization.maximumPhraseAmplitudeExpressive,
            "the balance must read as shading under the phrase, not as a second shape"
        )
        XCTAssertEqual(
            Realization.maximumBalanceLift, Realization.maximumBalanceDuck,
            "lift and duck are the same size so balancing does not change the level"
        )
    }

    // MARK: REQ-004 — off means nothing at all

    /// With expression off there is no balance term: not a small one, not a
    /// clamped one. The code path is skipped.
    func testThereIsNoBalanceTermWithExpressionOff() throws {
        for data in [
            MusicXMLScoreFixtures.melodyOverAccompaniment(),
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            MusicXMLScoreFixtures.stringQuartetMovement()
        ] {
            let score = try compile(data)
            for settings in [RealizationSettings.literal, .humanizedWithoutExpression] {
                let realization = Realization(score: score, settings: settings)
                let streams = score.lines.map { realization.buildStream($0) }
                for (index, balance) in realization.passageBalance(streams: streams).enumerated() {
                    XCTAssertTrue(
                        balance.isNeutral,
                        "line \(index) carries a balance term with expression off"
                    )
                    XCTAssertEqual(balance.delta(atTicks: 0), 0)
                }
            }
        }
    }

    // MARK: The fallbacks — ambiguity balances neutrally

    /// A homophonic texture balances neutrally: when every line attacks on the
    /// same ticks there is no melody and accompaniment to separate.
    ///
    /// `stringQuartetMovement` is four parts in strict rhythmic unison, with the
    /// first violin a clear fifth above the second — every register cue this
    /// reading has says "balance it", and the rhythm is what says not to.
    func testAHomophonicTextureBalancesNeutrally() throws {
        let (score, balances) = try balance(MusicXMLScoreFixtures.stringQuartetMovement())
        XCTAssertEqual(score.lines.count, 4)
        for (index, balance) in balances.enumerated() {
            XCTAssertTrue(
                balance.isNeutral,
                "line \(index) of a homophonic quartet was balanced"
            )
        }

        // The register cue really is present, so the neutral result above is the
        // rhythm rule firing rather than a texture that was never a candidate.
        let realization = Realization(score: score, settings: Self.expression(amount: 100))
        let streams = score.lines.map { realization.buildStream($0) }
        let voices = streams.map {
            realization.passageVoices($0, passageStartTicks: realization.balancePassageStartTicks())
        }
        let medians = voices.map { $0[0].medianMIDINote }
        XCTAssertGreaterThanOrEqual(
            medians[0] - medians[1], Realization.clearLeadSemitones,
            "the first violin must genuinely sit clear of the second in the first passage"
        )
    }

    /// A line doubled at the octave balances neutrally, for the same reason: the
    /// two move together.
    func testAUnisonDoublingBalancesNeutrally() throws {
        let (score, balances) = try balance(Self.octaveDoubling(), id: "unison")
        XCTAssertEqual(score.lines.count, 2)
        for (index, balance) in balances.enumerated() {
            XCTAssertTrue(balance.isNeutral, "line \(index) of an octave doubling was balanced")
        }
    }

    /// Two lines weaving inside the same third are a duet, not a melody and an
    /// accompaniment: no line is clearly on top, so nothing moves.
    func testTwoLinesInTheSameRegisterBalanceNeutrally() throws {
        let (score, balances) = try balance(Self.twoLinesInOneRegister(), id: "ambiguous")
        XCTAssertEqual(score.lines.count, 2)
        for (index, balance) in balances.enumerated() {
            XCTAssertTrue(
                balance.isNeutral,
                "line \(index) was balanced although neither line is clearly on top"
            )
        }
    }

    /// A high repeated ostinato is not a melody. The register cue is emphatic and
    /// the rhythm is its own; the melodic-activity cue is what refuses.
    func testAHighOstinatoIsNotMistakenForTheMelody() throws {
        let (score, balances) = try balance(Self.ostinatoOverAMovingLine(), id: "ostinato")
        XCTAssertEqual(score.lines.count, 2)
        for (index, balance) in balances.enumerated() {
            XCTAssertTrue(
                balance.isNeutral,
                "line \(index) was balanced although the top line never moves"
            )
        }
    }

    /// A single line has nothing to balance against, and neither does a passage
    /// where only one line is playing.
    func testASingleLineIsNeverBalanced() throws {
        let (score, balances) = try balance(MusicXMLScoreFixtures.ornamentStudy(), id: "single")
        XCTAssertEqual(score.lines.count, 1)
        XCTAssertTrue(try XCTUnwrap(balances.first).isNeutral)

        // And inside a multi-line score: the fugue's first two measures have only
        // the subject sounding, so those passages stay neutral whatever the rest
        // of the piece does.
        let fugue = try balance(MusicXMLScoreFixtures.keyboardFugueExposition(), id: "fugue")
        for (index, balance) in fugue.balances.enumerated() {
            XCTAssertEqual(
                balance.delta(atTicks: 0), 0,
                "line \(index) was balanced in a passage where one voice is playing alone"
            )
        }
    }

    /// The vacuity guard for every fallback above: the same machinery, on a
    /// texture that does say which line leads, is *not* neutral.
    func testTheFallbacksAreNotSimplyABalanceThatNeverFires() throws {
        let (_, balances) = try balance(MusicXMLScoreFixtures.melodyOverAccompaniment())
        XCTAssertFalse(
            try XCTUnwrap(balances.first).isNeutral,
            "the melody line is not balanced even on a fixture built for it, so every "
                + "neutral assertion above proves nothing"
        )

        let keyboard = try balance(MusicXMLScoreFixtures.expressiveKeyboardPiece(), id: "keyboard")
        XCTAssertFalse(
            try XCTUnwrap(keyboard.balances.first).isNeutral,
            "the reference keyboard piece's melody line is not balanced either"
        )
    }

    // MARK: Per passage, not per piece

    /// The balance follows the melody when it changes line, which is the whole
    /// reason this lives in the timeline rather than on a mixer strip (P65-2).
    func testTheBalanceFollowsTheMelodyWhenItMovesBetweenLines() throws {
        let (score, balances) = try balance(Self.melodyHandedOver(), id: "handover")
        XCTAssertEqual(score.lines.count, 3, "flute, violin, cello")

        let starts = balances[0].passageStartTicks
        XCTAssertGreaterThanOrEqual(starts.count, 4, "at least four passages to compare")

        let first = starts[0]
        let last = starts[starts.count - 1]

        XCTAssertGreaterThan(
            balances[0].delta(atTicks: first), 0,
            "the flute leads while it has the tune"
        )
        XCTAssertLessThan(balances[1].delta(atTicks: first), 0, "the violin accompanies it")
        XCTAssertLessThan(balances[2].delta(atTicks: first), 0, "so does the cello")

        XCTAssertGreaterThan(
            balances[1].delta(atTicks: last), 0,
            "the violin leads once the tune is handed to it"
        )
        XCTAssertLessThan(balances[2].delta(atTicks: last), 0, "the cello still accompanies")
        XCTAssertEqual(
            balances[0].delta(atTicks: last), 0,
            "a line that is not playing is neither lifted nor set back"
        )
    }

    /// Passages are measured in playback measures, so a repeat brings its own
    /// passages back rather than drifting off a fixed tick stride.
    func testPassagesAreMeasuredInPlaybackMeasures() throws {
        let score = try compile(MusicXMLScoreFixtures.melodyOverAccompaniment(measureCount: 8))
        let realization = Realization(score: score, settings: Self.expression(amount: 100))
        let starts = realization.balancePassageStartTicks()

        XCTAssertEqual(
            starts.count,
            (score.playbackMeasures.count + Realization.balancePassageMeasures - 1)
                / Realization.balancePassageMeasures
        )
        for (index, start) in starts.enumerated() {
            XCTAssertEqual(
                start,
                score.playbackMeasures[index * Realization.balancePassageMeasures].startTicks,
                "passage \(index) does not begin on a measure line"
            )
        }
        XCTAssertEqual(
            Realization.passageIndex(ofTicks: -1, in: starts), 0,
            "a tick before the first passage belongs to it"
        )
        XCTAssertEqual(
            Realization.passageIndex(ofTicks: Int.max, in: starts), starts.count - 1,
            "a tick past the end belongs to the last passage"
        )
    }

    // MARK: Fixtures

    /// Two parts playing the same rhythm, the upper doubling the lower an octave
    /// up.
    private static func octaveDoubling() -> Data {
        Self.twoParts(
            upper: (["C5", "D5", "E5", "F5"], 4, ("G", 2)),
            lower: (["C4", "D4", "E4", "F4"], 4, ("F", 4)),
            title: "Octave Doubling"
        )
    }

    /// Two parts weaving inside the same third, in different rhythms.
    private static func twoLinesInOneRegister() -> Data {
        Self.twoParts(
            upper: (["E4", "F4", "G4", "F4"], 4, ("G", 2)),
            lower: (["D4", "E4", "F4", "G4", "F4", "E4", "D4", "E4"], 8, ("G", 2)),
            title: "Duet in One Register"
        )
    }

    /// A high repeated note over a moving lower line.
    private static func ostinatoOverAMovingLine() -> Data {
        Self.twoParts(
            upper: (["C6"], 4, ("G", 2)),
            lower: (["C3", "E3", "G3", "B3", "C4", "B3", "G3", "E3"], 8, ("F", 4)),
            title: "Ostinato"
        )
    }

    /// Three parts over eight measures: the flute has the tune and then falls
    /// silent, the violin takes it over, and the cello accompanies throughout.
    ///
    /// A handover the ear would actually follow, which is what this reading can
    /// claim: the leading line is the top *sounding* line in both halves. A tune
    /// handed down into the bass is deliberately not followed — register is the
    /// cue, and the honest answer when the top of the texture is an accompaniment
    /// figure is to leave the passage alone, which
    /// `testAHighOstinatoIsNotMistakenForTheMelody` pins.
    private static func melodyHandedOver() -> Data {
        let upperTune = ["C6", "D6", "E6", "F6", "E6", "D6", "C6", "B5"]
        let middleTune = ["C5", "D5", "E5", "F5", "E5", "D5", "C5", "B4"]

        enum Role { case tune, accompany, silent }

        func measures(
            clef: (String, Int),
            tune: [String],
            accompaniment: String,
            role: (Int) -> Role
        ) -> [ScoreXML.Measure] {
            var out: [ScoreXML.Measure] = []
            for measureIndex in 0..<8 {
                var items: [ScoreXML.Item] = []
                if measureIndex == 0 {
                    items.append(
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: MusicXMLScoreFixtures.divisions,
                                fifths: 0,
                                time: (4, 4),
                                clefs: [clef]
                            )
                        )
                    )
                    items.append(
                        .direction(
                            ScoreXML.Direction(metronome: ("quarter", 96), sound: ["tempo": "96"])
                        )
                    )
                    items.append(.direction(.dynamic("mf")))
                }
                switch role(measureIndex) {
                case .tune:
                    for beat in 0..<4 {
                        items.append(
                            .note(
                                ScoreXML.Note(
                                    pitch: tune[(measureIndex * 4 + beat) % tune.count],
                                    duration: MusicXMLScoreFixtures.quarter,
                                    type: "quarter"
                                )
                            )
                        )
                    }
                case .accompany:
                    for _ in 0..<8 {
                        items.append(
                            .note(
                                ScoreXML.Note(
                                    pitch: accompaniment,
                                    duration: MusicXMLScoreFixtures.eighth,
                                    type: "eighth"
                                )
                            )
                        )
                    }
                case .silent:
                    items.append(
                        .note(
                            ScoreXML.Note(
                                pitch: nil,
                                duration: MusicXMLScoreFixtures.whole,
                                type: "whole"
                            )
                        )
                    )
                }
                out.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
            }
            return out
        }

        return ScoreXML.Score(
            workTitle: "Handover",
            composer: "Fixture",
            parts: [
                ScoreXML.Part(
                    id: "P1", name: "Flute",
                    measures: measures(
                        clef: ("G", 2), tune: upperTune, accompaniment: "G5",
                        role: { $0 < 4 ? .tune : .silent }
                    )
                ),
                ScoreXML.Part(
                    id: "P2", name: "Violin",
                    measures: measures(
                        clef: ("G", 2), tune: middleTune, accompaniment: "G4",
                        role: { $0 < 4 ? .accompany : .tune }
                    )
                ),
                ScoreXML.Part(
                    id: "P3", name: "Cello",
                    measures: measures(
                        clef: ("F", 4), tune: [], accompaniment: "C3",
                        role: { _ in .accompany }
                    )
                )
            ]
        ).data()
    }

    /// Two parts of evenly-valued notes with one dynamic each and nothing else.
    private static func twoParts(
        upper: ([String], Int, (String, Int)),
        lower: ([String], Int, (String, Int)),
        title: String,
        measureCount: Int = 8
    ) -> Data {
        func part(
            id: String,
            name: String,
            pitches: [String],
            notesPerMeasure: Int,
            clef: (String, Int)
        ) -> ScoreXML.Part {
            let value = MusicXMLScoreFixtures.whole / notesPerMeasure
            var measures: [ScoreXML.Measure] = []
            for measureIndex in 0..<measureCount {
                var items: [ScoreXML.Item] = []
                if measureIndex == 0 {
                    items.append(
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: MusicXMLScoreFixtures.divisions,
                                fifths: 0,
                                time: (4, 4),
                                clefs: [clef]
                            )
                        )
                    )
                    items.append(
                        .direction(
                            ScoreXML.Direction(metronome: ("quarter", 96), sound: ["tempo": "96"])
                        )
                    )
                    items.append(.direction(.dynamic("mf")))
                }
                for position in 0..<notesPerMeasure {
                    items.append(
                        .note(
                            ScoreXML.Note(
                                pitch: pitches[
                                    (measureIndex * notesPerMeasure + position) % pitches.count
                                ],
                                duration: value,
                                type: notesPerMeasure == 4 ? "quarter" : "eighth"
                            )
                        )
                    )
                }
                measures.append(ScoreXML.Measure(number: String(measureIndex + 1), items: items))
            }
            return ScoreXML.Part(id: id, name: name, measures: measures)
        }

        return ScoreXML.Score(
            workTitle: title,
            composer: "Fixture",
            parts: [
                part(
                    id: "P1", name: "Upper",
                    pitches: upper.0, notesPerMeasure: upper.1, clef: upper.2
                ),
                part(
                    id: "P2", name: "Lower",
                    pitches: lower.0, notesPerMeasure: lower.1, clef: lower.2
                )
            ]
        ).data()
    }
}
