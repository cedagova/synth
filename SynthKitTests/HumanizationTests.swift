import XCTest
@testable import SynthKit

/// REQ-012: humanization is on by default, controllable, and deterministic.
///
/// The acceptance criterion has three clauses and each gets its own group
/// here, because they fail for different reasons: "off is literal" fails when
/// a code path leaks; "twice is identical" fails when something unsorted or
/// process-seeded reaches the output; "intensity changes it" fails when the
/// controls are decorative.
final class HumanizationTests: XCTestCase {
    private let compiler = ScoreCompiler()
    private let realizer = PerformanceRealizer()

    private func score(_ data: Data = MusicXMLScoreFixtures.expressiveKeyboardPiece()) throws
        -> CompiledScore
    {
        try compiler.compile(pieceID: "humanization", musicXML: data)
    }

    // MARK: Off is strictly literal

    /// "Toggling humanization off produces a strictly literal rendering."
    ///
    /// Literal is checked against the tempo map rather than against a
    /// tolerance: every event must sound at exactly the time its notated tick
    /// converts to. A threshold would pass a build whose humanization was
    /// merely small.
    func testHumanizationOffPlacesEveryNoteExactlyWhereTheScorePutsIt() throws {
        let score = try score()
        let timeline = realizer.realize(score, settings: .literal)

        XCTAssertGreaterThan(timeline.eventCount, 100, "the claim needs notes to be about")
        for line in timeline.lines {
            for event in line.events {
                XCTAssertEqual(
                    event.onsetMicroseconds,
                    score.tempoMap.microseconds(atPlaybackTicks: event.onsetTicks),
                    "\(line.name) at tick \(event.onsetTicks) is not where the score puts it"
                )
            }
        }
    }

    /// Two notes written at one moment must sound at one moment when
    /// humanization is off — the property a chord depends on.
    func testHumanizationOffLeavesSimultaneousNotesSimultaneous() throws {
        let timeline = realizer.realize(try score(), settings: .literal)
        var timesByTick: [Int: Set<Int64>] = [:]
        for line in timeline.lines {
            for event in line.events {
                timesByTick[event.onsetTicks, default: []].insert(event.onsetMicroseconds)
            }
        }
        XCTAssertTrue(
            timesByTick.values.allSatisfy { $0.count == 1 },
            "one notated tick must map to one sounding time"
        )
    }

    /// Intensity zero plays exactly what off plays, so the owner can turn the
    /// dial all the way down without a surprise at the bottom.
    ///
    /// The *music* is compared, not the whole value: the timeline also records
    /// which settings produced it, and those genuinely differ — the dial is
    /// still on.
    func testIntensityZeroPlaysTheSameMusicAsHumanizationOff() throws {
        let score = try score()
        let off = realizer.realize(score, settings: .literal)
        let zero = realizer.realize(
            score,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 0)
            )
        )
        XCTAssertEqual(off.lines, zero.lines)
        XCTAssertNotEqual(off.settings, zero.settings, "the dial is in a different place")
    }

    // MARK: Twice is identical

    /// "Playing the same configuration twice sounds identical."
    func testTwoRealisationsOfOneConfigurationAreByteIdentical() throws {
        let score = try score()
        for settings in Self.settingsMatrix {
            let first = try realizer.realize(score, settings: settings).canonicalData()
            let second = try PerformanceRealizer().realize(score, settings: settings).canonicalData()
            XCTAssertEqual(first, second, "\(settings)")
        }
    }

    /// Realizing other pieces in between must not disturb the answer. This is
    /// what catches a realizer that accumulated state between calls.
    func testInterleavedRealisationsNeverDrift() throws {
        let reference = try score()
        let other = try score(MusicXMLScoreFixtures.ornamentStudy())
        let baseline = try realizer.realize(reference).canonicalData()

        for _ in 0..<8 {
            _ = realizer.realize(other)
            _ = realizer.realize(other, settings: .literal)
            XCTAssertEqual(try realizer.realize(reference).canonicalData(), baseline)
        }
    }

    /// Realizing from several tasks at once must agree. `PerformanceRealizer`
    /// is `Sendable` and holds nothing; this is what that claim means.
    func testConcurrentRealisationsAgree() async throws {
        let score = try score(MusicXMLScoreFixtures.orchestralExcerpt(partCount: 6, measureCount: 8))
        let expected = try PerformanceRealizer().realize(score).canonicalData()

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? PerformanceRealizer().realize(score).canonicalData() }
            }
            var collected: [Data?] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        for result in results { XCTAssertEqual(result, expected) }
    }

    /// Nothing later in a piece may reach back and change how its opening is
    /// realized.
    ///
    /// Checked literally, because a longer file is a different file: its bytes
    /// differ, so its humanization seed differs by design and its notes are
    /// *meant* to be interpreted differently. What must not differ is the
    /// reading of the notation itself. That the seeded variation is likewise
    /// per-note rather than positional is proved directly in
    /// `PerformanceTimelinePurityTests`.
    func testNothingLaterInAPieceChangesHowItsOpeningIsRealised() throws {
        let full = realizer.realize(try score(), settings: .literal)
        let longer = realizer.realize(
            try compiler.compile(
                pieceID: "humanization",
                musicXML: MusicXMLScoreFixtures.expressiveKeyboardPiece(measureCount: 24)
            ),
            settings: .literal
        )

        XCTAssertEqual(full.lines.map(\.id), longer.lines.map(\.id))
        for (line, extended) in zip(full.lines, longer.lines) {
            let opening = line.events.filter { $0.sourceMeasureIndex < 8 }
            let extendedOpening = extended.events.filter { $0.sourceMeasureIndex < 8 }
            XCTAssertFalse(opening.isEmpty)
            XCTAssertEqual(opening, extendedOpening, "\(line.name)")
        }
    }

    // MARK: Intensity changes it, deterministically

    /// "Changing intensity changes the timeline deterministically."
    func testEachIntensityGivesItsOwnTimelineAndAlwaysTheSameOne() throws {
        let score = try score()
        var seen: [Int: Data] = [:]

        for intensity in [10, 25, 40, 70, 100] {
            let settings = RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: intensity)
            )
            let bytes = try realizer.realize(score, settings: settings).canonicalData()
            XCTAssertEqual(
                bytes,
                try realizer.realize(score, settings: settings).canonicalData(),
                "intensity \(intensity) is not reproducible"
            )
            for (other, otherBytes) in seen {
                XCTAssertNotEqual(bytes, otherBytes, "intensity \(intensity) equals \(other)")
            }
            seen[intensity] = bytes
        }
    }

    /// More intensity means more departure from the literal reading — the
    /// control has to mean what it says.
    func testMoreIntensityMovesTheMusicFurtherFromTheLiteralReading() throws {
        let score = try score()
        let literal = realizer.realize(score, settings: .literal)

        var previous = 0
        for intensity in [20, 50, 100] {
            let timeline = realizer.realize(
                score,
                settings: RealizationSettings(
                    humanization: HumanizationSettings(isEnabled: true, intensity: intensity)
                )
            )
            let drift = Self.totalTimingDrift(from: literal, to: timeline)
            XCTAssertGreaterThan(
                drift,
                previous,
                "intensity \(intensity) does not depart further than the step below it"
            )
            previous = drift
        }
    }

    /// The variation stays inside a musical bound. Humanization that could
    /// move a note by a beat would not be humanization.
    func testEvenFullIntensityStaysWithinItsStatedBound() throws {
        let score = try score()
        let literal = realizer.realize(score, settings: .literal)
        let humanized = realizer.realize(
            score,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        )

        for (plain, played) in zip(literal.lines, humanized.lines) {
            XCTAssertEqual(plain.events.count, played.events.count, "no note is added or lost")
            let byTick = Dictionary(
                grouping: played.events,
                by: { [$0.onsetTicks, $0.midiNoteNumber] }
            )
            for event in plain.events {
                guard let match = byTick[[event.onsetTicks, event.midiNoteNumber]]?.first
                else { continue }
                XCTAssertLessThanOrEqual(
                    abs(match.onsetMicroseconds - event.onsetMicroseconds),
                    Int64(Realization.maximumTimingOffsetMicroseconds),
                    "a note moved further than the stated bound"
                )
            }
        }
    }

    // MARK: Humanization must never reorder the music

    /// The defect this guards against is invisible to every other test here: a
    /// timing offset larger than the space between two notes swaps them, so the
    /// engine plays a *different pitch sequence* than the one realization
    /// produced — while the timeline stays perfectly deterministic and every
    /// byte-identity proof keeps passing.
    ///
    /// A trill's notes sit a thirty-second apart and a crushed grace group can
    /// collapse to a tick or two, so this presses on the two worst cases at the
    /// worst setting.
    func testTheNotatedPitchOrderSurvivesEveryIntensity() throws {
        let data = MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes()
        let compiled = try compiler.compile(pieceID: "ordering", musicXML: data)
        let literalOrder = realizer.realize(compiled, settings: .literal)
            .lines[0].events.map(\.midiNoteNumber)

        XCTAssertGreaterThan(literalOrder.count, 60, "the fixture has to be dense to mean anything")

        for intensity in [1, 20, 40, 70, 100] {
            let played = realizer.realize(
                compiled,
                settings: RealizationSettings(
                    humanization: HumanizationSettings(isEnabled: true, intensity: intensity)
                )
            )
            XCTAssertEqual(
                played.lines[0].events.map(\.midiNoteNumber),
                literalOrder,
                "intensity \(intensity) reordered the notated pitch sequence"
            )
        }
    }

    /// The same claim at a tempo quick enough that a thirty-second note is
    /// shorter than the humanization range even at moderate settings.
    func testOrderSurvivesEvenWhenTheFiguresAreShorterThanTheJitterRange() throws {
        for tempo in [200, 280, 360] {
            let compiled = try compiler.compile(
                pieceID: "ordering-\(tempo)",
                musicXML: MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes(beatsPerMinute: tempo)
            )
            let literal = realizer.realize(compiled, settings: .literal).lines[0]
            let played = realizer.realize(
                compiled,
                settings: RealizationSettings(
                    humanization: HumanizationSettings(isEnabled: true, intensity: 100)
                )
            ).lines[0]

            XCTAssertEqual(
                played.events.map(\.midiNoteNumber),
                literal.events.map(\.midiNoteNumber),
                "at \(tempo) BPM the figure came out in a different order"
            )
            // And the onsets themselves stay in the notated order, not merely
            // the pitches: two events that swapped and happened to have the
            // same pitch would slip past a pitch-only check.
            XCTAssertEqual(
                played.events.map(\.onsetTicks),
                literal.events.map(\.onsetTicks),
                "at \(tempo) BPM the events came out at different notated positions"
            )
        }
    }

    /// A grace note must still arrive before the note it decorates. An
    /// acciaccatura that sounds after its principal is not an acciaccatura.
    func testAGraceNoteNeverOvertakesItsPrincipal() throws {
        let compiled = try compiler.compile(
            pieceID: "grace-order",
            musicXML: MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes()
        )
        let played = realizer.realize(
            compiled,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        ).lines[0]

        var graceGroups = 0
        for (index, event) in played.events.enumerated() where event.origin == .grace {
            guard let principal = played.events[index...].first(where: { $0.origin == .notated })
            else { continue }
            graceGroups += 1
            XCTAssertLessThan(
                event.onsetMicroseconds,
                principal.onsetMicroseconds,
                "a grace note overtook the note it leans on"
            )
        }
        XCTAssertGreaterThanOrEqual(graceGroups, 12, "the fixture carries grace notes to check")
    }

    /// The room bound is a bound, not a silencer: notes with space around them
    /// must still move by the full amount the dial asks for.
    func testTheRoomBoundStillLeavesRoomToHumanise() throws {
        let compiled = try compiler.compile(
            pieceID: "room",
            musicXML: MusicXMLScoreFixtures.expressiveKeyboardPiece()
        )
        let literal = realizer.realize(compiled, settings: .literal)
        let played = realizer.realize(
            compiled,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        )

        var moved = 0
        var largest: Int64 = 0
        for (plain, humanized) in zip(literal.lines, played.lines) {
            for (left, right) in zip(plain.events, humanized.events) {
                let shift = abs(right.onsetMicroseconds - left.onsetMicroseconds)
                if shift > 0 { moved += 1 }
                largest = max(largest, shift)
            }
        }
        XCTAssertGreaterThan(moved, literal.eventCount / 2, "most notes should still be moving")
        XCTAssertGreaterThan(largest, 5_000, "and the movement should still be audible")
    }

    /// Phrase shaping is the deliberate half of humanization: a slurred phrase
    /// should swell toward its middle rather than merely wobble.
    func testASlurredPhraseSwellsTowardItsMiddle() throws {
        let score = try compiler.compile(
            pieceID: "phrase",
            musicXML: MusicXMLScoreFixtures.articulationAndSlurStudy()
        )
        let shaped = Realization(
            score: score,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        )
        let span = Realization.SlurSpan(startTicks: 0, endTicks: 96)
        let amplitude = Realization.maximumPhraseAmplitude

        let edge = shaped.phraseShape(
            atTicks: 0, playbackMeasureIndex: 0, slurs: [span], amplitude: amplitude
        )
        let middle = shaped.phraseShape(
            atTicks: 48, playbackMeasureIndex: 0, slurs: [span], amplitude: amplitude
        )
        let far = shaped.phraseShape(
            atTicks: 90, playbackMeasureIndex: 0, slurs: [span], amplitude: amplitude
        )

        XCTAssertEqual(edge, -amplitude / 2, "the arch starts at its trough")
        XCTAssertEqual(middle, amplitude - amplitude / 2, "and peaks in the middle")
        XCTAssertLessThan(far, middle, "then eases out again")
    }

    // MARK: Settings

    func testTheDefaultIsHumanizationOnAsREQ012Requires() {
        XCTAssertTrue(HumanizationSettings.standard.isEnabled)
        XCTAssertGreaterThan(HumanizationSettings.standard.intensity, 0)
        XCTAssertTrue(RealizationSettings.standard.humanization.isEnabled)
        XCTAssertFalse(RealizationSettings.literal.humanization.isEnabled)
    }

    func testIntensityIsClampedToItsRange() {
        XCTAssertEqual(HumanizationSettings(isEnabled: true, intensity: -40).intensity, 0)
        XCTAssertEqual(HumanizationSettings(isEnabled: true, intensity: 4_000).intensity, 100)
    }

    /// The preset takes part in the seed, so increment 004 changing a preset
    /// re-interprets the piece instead of leaving a stale performance behind.
    func testTheActivePresetIsPartOfWhatTheInterpretationDependsOn() throws {
        let score = try score()
        let first = realizer.realize(
            score,
            settings: RealizationSettings(presetIdentifier: "preset-a")
        )
        let second = realizer.realize(
            score,
            settings: RealizationSettings(presetIdentifier: "preset-b")
        )

        XCTAssertNotEqual(first.seed, second.seed)
        XCTAssertNotEqual(try first.canonicalData(), try second.canonicalData())
    }

    /// Two different pieces must not be given the same performance noise, and
    /// nor must one piece whose file was edited.
    func testTheSeedFollowsThePieceAndItsBytes() throws {
        let data = MusicXMLScoreFixtures.expressiveKeyboardPiece()
        let asA = realizer.realize(try compiler.compile(pieceID: "a", musicXML: data))
        let asB = realizer.realize(try compiler.compile(pieceID: "b", musicXML: data))
        let edited = realizer.realize(
            try compiler.compile(
                pieceID: "a",
                musicXML: MusicXMLScoreFixtures.expressiveKeyboardPiece(measureCount: 17)
            )
        )

        XCTAssertNotEqual(asA.seed, asB.seed)
        XCTAssertNotEqual(asA.seed, edited.seed)
    }

    // MARK: Helpers

    private static let settingsMatrix: [RealizationSettings] = [
        .literal,
        .standard,
        RealizationSettings(humanization: HumanizationSettings(isEnabled: true, intensity: 1)),
        RealizationSettings(humanization: HumanizationSettings(isEnabled: true, intensity: 100)),
        RealizationSettings(
            presetIdentifier: "preset-1",
            humanization: HumanizationSettings(isEnabled: true, intensity: 55)
        )
    ]

    /// How far, in total microseconds, one timeline's notes sit from another's.
    private static func totalTimingDrift(
        from literal: PerformanceTimeline,
        to humanized: PerformanceTimeline
    ) -> Int {
        var total = 0
        for (plain, played) in zip(literal.lines, humanized.lines) {
            for (left, right) in zip(plain.events.map(\.onsetMicroseconds).sorted(),
                                     played.events.map(\.onsetMicroseconds).sorted()) {
                total += Int(abs(left - right))
            }
        }
        return total
    }
}
