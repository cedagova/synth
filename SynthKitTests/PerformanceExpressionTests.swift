import XCTest
@testable import SynthKit

/// REQ-003's realizer half and REQ-004's expression term: phrase-shaped
/// dynamics and cadence breathing when the setting is on, and provably nothing
/// at all when it is off.
///
/// The groups here are the acceptance clauses, and each fails for its own
/// reason:
///
/// - **the bypass** fails when a code path leaks, so it is checked against the
///   realization from *before* this setting existed rather than against a
///   tolerance;
/// - **shaped dynamics** fail when the controls are decorative, so they are
///   checked with humanization switched off, where the written dynamic is the
///   only other thing that could be moving the velocity;
/// - **bounds** fail invisibly — a breath that reorders two notes is perfectly
///   deterministic and passes every byte-identity proof while playing a
///   different pitch sequence; and
/// - **the transport's promise** fails when shaping reaches `onsetTicks`, which
///   no audible check would notice.
final class PerformanceExpressionTests: XCTestCase {
    private let compiler = ScoreCompiler()
    private let realizer = PerformanceRealizer()

    private static let expressionOnly = RealizationSettings(
        humanization: .off, expression: ExpressionSettings(isEnabled: true, amount: 100)
    )

    private func compile(
        _ data: Data, id: String = "expression"
    ) throws -> CompiledScore {
        try compiler.compile(pieceID: id, musicXML: data)
    }

    /// SHA-256 of a timeline's *events*, with the settings record left out.
    ///
    /// The whole-timeline digest in `PerformanceTimelinePurityTests` moves the
    /// moment a settings field is added, which is exactly the wrong property
    /// for the bypass claim: what has to be unchanged is the music, not the
    /// record of which dials produced it.
    private func eventDigest(_ timeline: PerformanceTimeline) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MusicXMLImporter.sha256Hex(try encoder.encode(timeline.lines))
    }

    // MARK: REQ-004 — the bypass renders what it always rendered

    /// The three reference fixtures, at both bypass settings, with the digest each
    /// one must produce.
    ///
    /// **This is REQ-004's expression term, stated as strongly as it can be
    /// stated.** Not "no phrase dynamics are detectable" and not "the character
    /// is restored", but: with expression off, the realizer emits an exact,
    /// pinned byte stream. A leak anywhere on the phrasing or balance path — a
    /// shape applied at amount zero, a breath clamped to a small number instead
    /// of skipped, a balance term that survived the guard, a seed that moved
    /// because a settings field was added — moves one of these.
    ///
    /// **Two of the six are still the pre-feature bytes, and that is load-bearing
    /// rather than an accident.** The fugue fixture carries no slur anywhere in
    /// it, so EXP002's legato change cannot reach it; its two rows are the ones
    /// recorded on `eb7d0d3`, the collector base, before EXP001 added a line of
    /// realization code. They still hold, which is the historical half of the
    /// claim: the expression bypass has never moved.
    ///
    /// The other four moved **once**, on EXP002, for one deliberate reason: the
    /// legato overlap stopped being `ticksPerQuarter / 32` — a fraction of
    /// whatever one tick happens to be on the score in front of it — and became a
    /// bounded number of microseconds
    /// (`PerformanceRealizer.legatoOverlapMicroseconds`). Articulation is written
    /// notation and therefore always on, in the bypass state as much as anywhere
    /// else, so correcting it necessarily moves the bypass bytes of any fixture
    /// that contains a slur. The values below were recorded from two agreeing runs
    /// in separate processes. What did *not* move is the music:
    /// `testExpressionOffStillPlaysThePreFeatureNotesTimesAndLoudness` holds all
    /// six fixtures against digests taken on `e6c1697` over every event field
    /// except the lengths, so the claim "only sounding lengths changed" is
    /// measured rather than asserted.
    ///
    /// **Moved once more on #80, all six rows.** The articulation shortening —
    /// staccato, marcato, and every plain note's détaché — stopped being read
    /// on the tick grid alone and gained a microsecond residual
    /// (`RealizedNote.articulationShorteningMicroseconds`), so every fixture's
    /// unmarked notes changed length by the fraction the grid had floored.
    /// Articulation is written notation and always on, so the bypass bytes
    /// move with it; `preFeatureShapeDigests` below did not move, which is the
    /// measured claim that nothing but sounding lengths changed. Refrozen from
    /// two agreeing runs in separate processes.
    private static let bypassEventDigests: [String: (Data, RealizationSettings)] = [
        // Recorded before the expression setting existed; moved on #80 only.
        "d6c62e6bd0d33a034ae5ffb9d5b9b3c0d28cce6089e39cf2ea95ed8887a47340": (
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 4), .literal
        ),
        "ed9c2af27e0d363e23f6c388fbd6d26b323bae835d65ca7713ad04a49c814e7f": (
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 4),
            .humanizedWithoutExpression
        ),
        // Moved on EXP002 for the legato overlap, and on #80. Slurred fixtures.
        "b48e638818c90f7e45b8e9af8f7b764b2f1f6cd62c2b13f804956438233a8253": (
            MusicXMLScoreFixtures.expressiveKeyboardPiece(), .literal
        ),
        "f82c77c1065e5c0a1fa4c0a7451b64382747675be08e235a87fa907f5b4f3483": (
            MusicXMLScoreFixtures.expressiveKeyboardPiece(), .humanizedWithoutExpression
        ),
        "7a0c4dc5da1e34e6e18ebdda9358ca4c7fc70ac0b1e1659cb08b0fa32540751d": (
            MusicXMLScoreFixtures.stringQuartetMovement(), .literal
        ),
        "a69623798a9c51980d08e0289dca860c20bc7391461a8e3ccb8dc0d96ae62492": (
            MusicXMLScoreFixtures.stringQuartetMovement(), .humanizedWithoutExpression
        )
    ]

    /// The same six fixtures and settings, digested over every event field
    /// *except* the two length fields — recorded on `e6c1697`, the collector base
    /// this leaf branched from, from two agreeing runs in separate processes.
    ///
    /// **The provenance the table above has to give up, recovered.** A full-byte
    /// digest cannot survive a deliberate correction to an always-on notation
    /// reading, but the interesting claim can: with expression off, EXP002 plays
    /// the same notes, at the same times, at the same loudness, in the same
    /// measures as the base did. Only how long each note sounds changed, and only
    /// under a slur. If the articulation fix had touched a velocity, a
    /// micro-timing offset, an ornament expansion or a measure index, one of these
    /// would move — and no refreeze of the table above would hide it.
    private static let preFeatureShapeDigests: [(String, Data, RealizationSettings)] = [
        (
            "9cf3b923b8ba80062e3e427ec1afae2887c81416388cd129c51bd269382d57d3",
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 4), .literal
        ),
        (
            "708c354d3f968536c8f30fd3e9da2e3efaf60567d3421b9e9719992a6c9b1107",
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 4),
            .humanizedWithoutExpression
        ),
        (
            "3c6190db332c9fb2f56b26c33ee9534200c19b19f374ca4ca56437d45a33f7ea",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(), .literal
        ),
        (
            "7876ebfda1003c7b51836adb1c6a5bea316019603a10953119e4401ceecf7021",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(), .humanizedWithoutExpression
        ),
        (
            "d00d027223215bc7cf32ae7a2b502ecb817e7ba1a84b68222086c4a821577841",
            MusicXMLScoreFixtures.stringQuartetMovement(), .literal
        ),
        (
            "b823ad1d4e38f10870733dae12987782d72dab6127383ddb02b1ede59c1b4b48",
            MusicXMLScoreFixtures.stringQuartetMovement(), .humanizedWithoutExpression
        )
    ]

    /// SHA-256 of a timeline's events with both length fields left out: the
    /// notes, where they sound, how loud, and which measure they belong to.
    private func shapeDigest(_ timeline: PerformanceTimeline) -> String {
        var text = ""
        for line in timeline.lines {
            text += line.id.rawValue + "|"
            for event in line.events {
                text += "\(event.onsetMicroseconds),\(event.midiNoteNumber),"
                    + "\(event.velocity),\(event.origin.rawValue),\(event.onsetTicks),"
                    + "\(event.playbackMeasureIndex),\(event.sourceMeasureIndex);"
            }
            text += "\n"
        }
        return MusicXMLImporter.sha256Hex(Data(text.utf8))
    }

    func testExpressionOffRendersTheExactPinnedBypassTimeline() throws {
        for (expected, testCase) in Self.bypassEventDigests {
            let score = try compile(testCase.0, id: "frozen")
            let digest = try eventDigest(realizer.realize(score, settings: testCase.1))
            XCTAssertEqual(
                digest, expected,
                "with expression off the realizer no longer produces the pinned bypass "
                    + "timeline, so REQ-004's bypass recipe is broken for the expression term"
            )
        }
    }

    func testExpressionOffStillPlaysThePreFeatureNotesTimesAndLoudness() throws {
        for (expected, data, settings) in Self.preFeatureShapeDigests {
            let score = try compile(data, id: "frozen")
            let digest = shapeDigest(realizer.realize(score, settings: settings))
            XCTAssertEqual(
                digest, expected,
                "with expression off the realizer plays different notes, times or "
                    + "loudnesses from the collector base; EXP002 was only allowed to change "
                    + "how long a slurred note sounds"
            )
        }
    }

    /// Amount zero is the same music as off, so the owner can turn the dial all
    /// the way down without a surprise at the bottom — the
    /// `HumanizationSettings` precedent, and for the same reason.
    func testAmountZeroPlaysTheSameMusicAsExpressionOff() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let off = realizer.realize(score, settings: .humanizedWithoutExpression)
        let zero = realizer.realize(
            score,
            settings: RealizationSettings(expression: ExpressionSettings(isEnabled: true, amount: 0))
        )
        XCTAssertEqual(off.lines, zero.lines)
        XCTAssertNotEqual(off.settings, zero.settings, "the dial is in a different place")
    }

    /// The other half of the bypass claim: the fixtures must actually be shaped
    /// when the setting is on, or every assertion above is vacuous.
    func testTheReferenceFixturesAreGenuinelyShapedWhenExpressionIsOn() throws {
        for data in [
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            MusicXMLScoreFixtures.stringQuartetMovement(),
            MusicXMLScoreFixtures.keyboardFugueExposition()
        ] {
            let score = try compile(data)
            let off = realizer.realize(score, settings: .humanizedWithoutExpression)
            let on = realizer.realize(score, settings: .standard)
            XCTAssertNotEqual(
                off.lines, on.lines,
                "the fixture realizes identically with expression on and off, so the bypass "
                    + "tests above prove nothing"
            )
        }
    }

    // MARK: REQ-003 — dynamics vary over phrases and cadences

    /// The criterion, on a line whose notation says one dynamic and nothing
    /// else: the phrase rises and then eases into its ending.
    ///
    /// Humanization is off, so the written `mp` is the only other thing that
    /// could move a velocity — which is what makes "beyond written dynamics" a
    /// measurement rather than an impression.
    func testDynamicsRiseThroughAPhraseAndEaseIntoItsEnding() throws {
        let score = try compile(Self.phraseStudy())
        let shaped = realizer.realize(score, settings: Self.expressionOnly)
        let literal = realizer.realize(score, settings: .literal)

        let written = Set(literal.lines[0].events.map(\.velocity))
        XCTAssertEqual(
            written.count, 1,
            "the fixture is supposed to write one unchanging dynamic, so that any variation "
                + "under expression is the expression's own"
        )

        // Three notes then a rest, measure after measure: every measure is one
        // phrase, and the rest is what ends it.
        let events = shaped.lines[0].events
        XCTAssertEqual(events.count, 24, "eight measures of three sounding notes")

        for measure in 0..<8 {
            let phrase = Array(events[(measure * 3)..<(measure * 3 + 3)])
            XCTAssertLessThan(
                phrase[0].velocity, phrase[1].velocity,
                "measure \(measure + 1) does not lean into its phrase"
            )
            XCTAssertLessThan(
                phrase[2].velocity, phrase[1].velocity,
                "measure \(measure + 1) does not ease out of its phrase"
            )
        }
    }

    /// Cadential easing is separable from the arch: the firmer the ending, the
    /// further the last note drops below the phrase's peak.
    func testAFirmerEndingEasesOffFurther() {
        let phrase = Realization.Phrase(
            startTicks: 0, endTicks: 96, lastOnsetTicks: 72, endStrength: 3, onsetCount: 4
        )
        let weak = Realization.Phrase(
            startTicks: 0, endTicks: 96, lastOnsetTicks: 72, endStrength: 1, onsetCount: 4
        )
        let firm = Realization.cadentialEasing(
            atTicks: 95, phrase: phrase, tailTicks: 48, magnitude: 10
        )
        let gentle = Realization.cadentialEasing(
            atTicks: 95, phrase: weak, tailTicks: 48, magnitude: 10
        )
        XCTAssertGreaterThan(firm, gentle, "a firm ending should ease off further")
        XCTAssertEqual(
            Realization.cadentialEasing(atTicks: 0, phrase: phrase, tailTicks: 48, magnitude: 10),
            0,
            "and nothing should be easing off at the start of the phrase"
        )
    }

    /// The arch peaks past the middle, which is what separates it from
    /// humanization's symmetrical gesture shape.
    func testThePhraseArchPeaksPastTheMiddle() {
        let phrase = Realization.Phrase(
            startTicks: 0, endTicks: 800, lastOnsetTicks: 700, endStrength: 2, onsetCount: 8
        )
        let amplitude = 14
        let values = stride(from: 0, through: 800, by: 50).map {
            Realization.phraseArch(atTicks: $0, phrase: phrase, amplitude: amplitude)
        }
        let peak = values.enumerated().max { $0.element < $1.element }!
        XCTAssertEqual(values.first, -amplitude / 2, "the arch starts at its trough")
        XCTAssertEqual(values.last, -amplitude / 2, "and returns to it")
        XCTAssertGreaterThan(
            peak.offset * 50, 400, "the peak should fall after the middle of the phrase"
        )
        XCTAssertEqual(peak.element, amplitude - amplitude / 2, "and reach the full amplitude")
    }

    // MARK: REQ-003 — cadences and phrase ends breathe

    /// The breath, measured exactly: with humanization off, the only reason an
    /// event can sound later than its notated tick is the phrase breath.
    func testEachPhraseAfterTheFirstStartsLate() throws {
        let score = try compile(Self.phraseStudy())
        let shaped = realizer.realize(score, settings: Self.expressionOnly)
        let map = score.tempoMap

        var late = 0
        for (index, event) in shaped.lines[0].events.enumerated() {
            let notated = map.microseconds(atPlaybackTicks: event.onsetTicks)
            let lateness = event.onsetMicroseconds - notated
            if index % 3 == 0, index > 0 {
                XCTAssertEqual(
                    lateness,
                    Int64(Realization.maximumBreathMicroseconds),
                    "the first note of phrase \(index / 3 + 1) did not take its full breath"
                )
                late += 1
            } else {
                XCTAssertEqual(
                    lateness, 0,
                    "note \(index) is not at a phrase start and must sound where it is written"
                )
            }
        }
        XCTAssertEqual(late, 7, "seven of the eight phrases follow another one")
    }

    /// And the phrase's last note is released early, so the silence is a lift
    /// rather than a delay bolted on to the next note.
    func testThePhraseFinalNoteIsReleasedEarly() throws {
        let score = try compile(Self.phraseStudy())
        let shaped = realizer.realize(score, settings: Self.expressionOnly)
        let plain = realizer.realize(score, settings: .literal)

        // The last note of each of the seven phrases that have another phrase
        // after them.
        for index in stride(from: 2, to: 21, by: 3) {
            XCTAssertLessThan(
                shaped.lines[0].events[index].durationMicroseconds,
                plain.lines[0].events[index].durationMicroseconds,
                "the last note of phrase \(index / 3 + 1) was not lifted"
            )
        }
        // A note that is not ending a phrase keeps its full shaped length.
        XCTAssertEqual(
            shaped.lines[0].events[1].durationMicroseconds,
            plain.lines[0].events[1].durationMicroseconds
        )
        // And the very last note rings its full length: there is nothing after
        // it to breathe into, and clipping a final note is not phrasing.
        XCTAssertEqual(
            shaped.lines[0].events[23].durationMicroseconds,
            plain.lines[0].events[23].durationMicroseconds,
            "the final note of the line was clipped"
        )
    }

    /// The lift is bounded by the note's own length, so it can shorten a note
    /// but never silence it or reach the note after it.
    func testTheLiftIsBoundedByTheNotesOwnLength() throws {
        for data in [
            Self.phraseStudy(),
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes()
        ] {
            let score = try compile(data)
            let plain = realizer.realize(score, settings: .literal)
            let shaped = realizer.realize(score, settings: Self.expressionOnly)

            for (plainLine, shapedLine) in zip(plain.lines, shaped.lines) {
                for (left, right) in zip(plainLine.events, shapedLine.events) {
                    XCTAssertGreaterThan(right.durationMicroseconds, 0, "a note was silenced")
                    XCTAssertLessThanOrEqual(
                        right.durationMicroseconds, left.durationMicroseconds,
                        "a breath lengthened a note instead of lifting it"
                    )
                    XCTAssertGreaterThanOrEqual(
                        right.durationMicroseconds * Int64(Realization.breathLiftDivisor),
                        left.durationMicroseconds * Int64(Realization.breathLiftDivisor - 1),
                        "a note was lifted by more than a quarter of its length"
                    )
                }
            }
        }
    }

    /// **The defect no audible check would catch.** A breath that pushed one
    /// note past its neighbour would make the engine play a different pitch
    /// sequence from the one this stage realized — while staying perfectly
    /// deterministic.
    ///
    /// Pressed at the worst setting on the densest fixtures: both dials at 100,
    /// so the breath and the jitter are asking for the same room at once.
    func testABreathNeverMovesANotePastItsNeighbour() throws {
        let settings = RealizationSettings(
            humanization: HumanizationSettings(isEnabled: true, intensity: 100),
            expression: ExpressionSettings(isEnabled: true, amount: 100)
        )
        for (id, data) in [
            ("fast", MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes()),
            ("faster", MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes(beatsPerMinute: 360)),
            ("keyboard", MusicXMLScoreFixtures.expressiveKeyboardPiece()),
            ("quartet", MusicXMLScoreFixtures.stringQuartetMovement())
        ] {
            let score = try compile(data, id: id)
            let literal = realizer.realize(score, settings: .literal)
            let played = realizer.realize(score, settings: settings)

            for (plainLine, playedLine) in zip(literal.lines, played.lines) {
                XCTAssertEqual(
                    playedLine.events.map(\.midiNoteNumber),
                    plainLine.events.map(\.midiNoteNumber),
                    "\(id): the notated pitch sequence came out in a different order"
                )
                XCTAssertEqual(
                    playedLine.events.map(\.onsetTicks),
                    plainLine.events.map(\.onsetTicks),
                    "\(id): two events swapped places"
                )
            }
        }
    }

    // MARK: The transport's promise

    /// Breathing is bounded local *timing*, and the issue's constraint is that
    /// it never breaks the measure alignment the transport readout promises.
    ///
    /// That holds structurally rather than numerically: the readout and score
    /// following read `onsetTicks`, `playbackMeasureIndex` and
    /// `sourceMeasureIndex`, and expression writes none of them. Checked on
    /// every event of every line at the strongest setting.
    func testShapingNeverMovesANoteOffTheMeasureTheScoreWroteItIn() throws {
        for data in [
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            MusicXMLScoreFixtures.stringQuartetMovement(),
            MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        ] {
            let score = try compile(data)
            let off = realizer.realize(score, settings: .humanizedWithoutExpression)
            let on = realizer.realize(
                score,
                settings: RealizationSettings(
                    expression: ExpressionSettings(isEnabled: true, amount: 100)
                )
            )
            for (offLine, onLine) in zip(off.lines, on.lines) {
                XCTAssertEqual(
                    onLine.events.map { [$0.onsetTicks, $0.playbackMeasureIndex, $0.sourceMeasureIndex] },
                    offLine.events.map { [$0.onsetTicks, $0.playbackMeasureIndex, $0.sourceMeasureIndex] },
                    "expression moved a note onto a different notated position"
                )
            }
        }
    }

    // MARK: The amount scales the effect

    func testAHigherAmountShapesFurther() throws {
        let score = try compile(Self.phraseStudy())
        let plain = realizer.realize(score, settings: .literal)

        var previousSpread = -1
        var previousBreath: Int64 = -1
        for amount in [10, 25, 50, 100] {
            let shaped = realizer.realize(
                score,
                settings: RealizationSettings(
                    humanization: .off,
                    expression: ExpressionSettings(isEnabled: true, amount: amount)
                )
            )
            let velocities = shaped.lines[0].events.map(\.velocity)
            let spread = (velocities.max() ?? 0) - (velocities.min() ?? 0)
            let breath = shaped.lines[0].events[3].onsetMicroseconds
                - plain.lines[0].events[3].onsetMicroseconds

            XCTAssertGreaterThan(spread, previousSpread, "amount \(amount) shaped no further")
            XCTAssertGreaterThan(breath, previousBreath, "amount \(amount) breathed no longer")
            previousSpread = spread
            previousBreath = breath
        }
    }

    // MARK: Determinism (REQ-003's "two renders byte-identical")

    func testTwoRealisationsWithExpressionOnAreByteIdentical() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        for amount in [1, 50, 100] {
            let settings = RealizationSettings(
                expression: ExpressionSettings(isEnabled: true, amount: amount)
            )
            let first = try realizer.realize(score, settings: settings).canonicalData()
            let second = try realizer.realize(score, settings: settings).canonicalData()
            XCTAssertEqual(first, second, "amount \(amount) realized differently twice")
        }
    }

    func testConcurrentRealisationsWithExpressionOnAgree() async throws {
        let score = try compile(MusicXMLScoreFixtures.stringQuartetMovement())
        let expected = try realizer.realize(score, settings: .standard).canonicalData()

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask { [realizer] in
                    try? realizer.realize(score, settings: .standard).canonicalData()
                }
            }
            var out: [Data?] = []
            for await result in group { out.append(result) }
            return out
        }
        for result in results { XCTAssertEqual(result, expected) }
    }

    // MARK: Failure and edge behaviour

    /// The issue's edge clause: a degenerate line passes through untouched.
    func testAOneNoteLineIsRealisedIdenticallyOnAndOff() throws {
        let score = try compile(MusicXMLFixtures.score())
        XCTAssertEqual(score.lines[0].notes.filter { !$0.isRest }.count, 1, "one note, as intended")

        let off = realizer.realize(score, settings: .humanizedWithoutExpression)
        let on = realizer.realize(
            score,
            settings: RealizationSettings(
                expression: ExpressionSettings(isEnabled: true, amount: 100)
            )
        )
        XCTAssertEqual(off.lines, on.lines, "a single-note line has no phrase to shape")
    }

    /// The issue's other edge clause: a score with neither slurs nor rests
    /// still gets bounded phrasing, because the phrase is broken at a bar line
    /// once it has run its length.
    func testAScoreWithNoSlursOrRestsStillGetsBoundedPhrasing() throws {
        let score = try compile(Self.unmarkedScale())
        XCTAssertTrue(
            score.lines[0].notes.allSatisfy {
                !$0.isRest && $0.slurStartCount == 0 && $0.slurStopCount == 0
            },
            "the fixture is supposed to carry no slurs and no rests"
        )

        let plain = realizer.realize(score, settings: .literal)
        let shaped = realizer.realize(score, settings: Self.expressionOnly)

        XCTAssertEqual(Set(plain.lines[0].events.map(\.velocity)).count, 1, "nothing is written")
        XCTAssertGreaterThan(
            Set(shaped.lines[0].events.map(\.velocity)).count, 3,
            "an unmarked line got no phrasing at all"
        )
        let breaths = zip(plain.lines[0].events, shaped.lines[0].events)
            .filter { $0.1.onsetMicroseconds > $0.0.onsetMicroseconds }
        XCTAssertGreaterThan(breaths.count, 0, "and no breath either")
        XCTAssertLessThan(
            breaths.count, shaped.lines[0].events.count / 4,
            "every few notes is not phrasing, it is a stutter"
        )
    }

    // MARK: Settings

    func testTheDefaultIsExpressionOnAsD653Requires() {
        XCTAssertTrue(ExpressionSettings.standard.isEnabled)
        XCTAssertGreaterThan(ExpressionSettings.standard.amount, 0)
        XCTAssertFalse(ExpressionSettings.standard.isNeutral)
        XCTAssertTrue(RealizationSettings.standard.expression.isEnabled)
        XCTAssertTrue(ExpressionSettings.off.isNeutral)
        XCTAssertTrue(ExpressionSettings(isEnabled: true, amount: 0).isNeutral)
    }

    func testTheAmountIsClampedToItsRange() throws {
        XCTAssertEqual(ExpressionSettings(isEnabled: true, amount: 900).amount, 100)
        XCTAssertEqual(ExpressionSettings(isEnabled: true, amount: -40).amount, 0)
        // Through the decoder too, so a stored document cannot smuggle one past.
        let data = Data(#"{"isEnabled":true,"amount":4000}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ExpressionSettings.self, from: data).amount, 100
        )
    }

    /// The expression setting must not move the humanization noise: that is
    /// what lets the bypass be bit-identical rather than merely similar.
    func testTheExpressionSettingDoesNotReseedTheHumanisation() {
        let off = SeededJitter.seedHex(
            pieceID: "p", contentSHA256: "c", settings: .humanizedWithoutExpression
        )
        let on = SeededJitter.seedHex(pieceID: "p", contentSHA256: "c", settings: .standard)
        XCTAssertEqual(off, on, "turning expression on re-rolled the humanization")
    }

    // MARK: Fixtures

    /// Eight measures of three quarter notes and a quarter rest, one `mp`, no
    /// slurs and no hairpins.
    ///
    /// Deliberately the plainest score that still has phrases: every measure is
    /// one phrase because a written silence ends it, and the written dynamic
    /// never changes — so every velocity difference and every late onset in
    /// the realization is the expression stage's and nothing else's.
    static func phraseStudy() -> Data {
        let pitches = ["C5", "D5", "E5", "F5", "G5", "A5", "B5", "C6"]
        var measures: [ScoreXML.Measure] = []
        for index in 0..<8 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: MusicXMLScoreFixtures.divisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
                        )
                    )
                )
                items.append(
                    .direction(
                        ScoreXML.Direction(metronome: ("quarter", 120), sound: ["tempo": "120"])
                    )
                )
                items.append(.direction(.dynamic("mp")))
            }
            for beat in 0..<3 {
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: pitches[(index + beat) % pitches.count],
                            duration: MusicXMLScoreFixtures.quarter,
                            type: "quarter"
                        )
                    )
                )
            }
            items.append(
                .note(
                    ScoreXML.Note(
                        pitch: nil, duration: MusicXMLScoreFixtures.quarter, type: "quarter"
                    )
                )
            )
            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }
        return ScoreXML.Score(
            workTitle: "Phrase Study",
            parts: [ScoreXML.Part(id: "P1", name: "Flute", measures: measures)]
        ).data()
    }

    /// Twelve measures of unbroken, unslurred, evenly-valued eighth notes with
    /// one dynamic: no rest, no slur and no agogic arrival anywhere in it.
    static func unmarkedScale() -> Data {
        let pitches = ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5"]
        var measures: [ScoreXML.Measure] = []
        for index in 0..<12 {
            var items: [ScoreXML.Item] = []
            if index == 0 {
                items.append(
                    .attributes(
                        ScoreXML.Attributes(
                            divisions: MusicXMLScoreFixtures.divisions,
                            fifths: 0,
                            time: (4, 4),
                            clefs: [("G", 2)]
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
            for step in 0..<8 {
                items.append(
                    .note(
                        ScoreXML.Note(
                            pitch: pitches[(index * 8 + step) % pitches.count],
                            duration: MusicXMLScoreFixtures.eighth,
                            type: "eighth"
                        )
                    )
                )
            }
            measures.append(ScoreXML.Measure(number: String(index + 1), items: items))
        }
        return ScoreXML.Score(
            workTitle: "Unmarked Scale",
            parts: [ScoreXML.Part(id: "P1", name: "Viola", measures: measures)]
        ).data()
    }
}
