import XCTest
@testable import SynthKit

/// Issue #15: "Offline-render tests produce deterministic buffers for a fixture
/// timeline (engine correctness without a device)."
///
/// Offline manual rendering is the primary proof for this leaf, and not only
/// because CI is headless. It runs the *same* graph real-time playback uses
/// (AD2), so what these tests measure is the engine, not a simulation of it —
/// and because the output is a buffer rather than a sound, every claim here is
/// a number instead of an adjective.
final class OfflineRenderTests: XCTestCase {
    // MARK: Determinism

    /// The headline: two renders of one timeline are byte-identical.
    ///
    /// Byte equality rather than a tolerance, because this is the property
    /// increment 006 inherits — REQ-026 checks an export against live playback,
    /// and a tolerance there would not be an equality claim at all.
    func testTwoRendersOfOneTimelineAreByteIdentical() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let first = try PlaybackEngine.renderTimelineOffline(timeline)
        let second = try PlaybackEngine.renderTimelineOffline(timeline)

        XCTAssertGreaterThan(first.frameCount, 0, "The render produced no frames at all.")
        XCTAssertEqual(
            first.canonicalData(), second.canonicalData(),
            "Two offline renders of the same timeline differed; the render path is not deterministic."
        )
    }

    /// A render that produced silence would pass the determinism test above
    /// perfectly, so prove the buffer actually contains the piece.
    func testTheRenderContainsAudioRatherThanSilence() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let audio = try PlaybackEngine.renderTimelineOffline(timeline)

        XCTAssertGreaterThan(audio.rms(), 0.001, "The render is effectively silent.")
        XCTAssertLessThan(audio.peak(), 1.0, "The render clips; the voice has no headroom.")
    }

    /// The sub-block scheduler splits every buffer at note boundaries, so the
    /// output must not depend on how the host happened to chop up time.
    ///
    /// This is the test that would catch a scheduler that rounded an event onto
    /// a buffer edge — the classic way playback becomes subtly, unrepeatably
    /// wrong.
    func testTheRenderIsIndependentOfTheHostBufferSize() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        func render(blockFrames: Int64) throws -> PlaybackEngine.RenderedAudio {
            let engine = PlaybackEngine()
            try engine.setRenderMode(.offline(sampleRate: 48_000))
            try engine.load(timeline: timeline)
            engine.play()

            let total = try XCTUnwrap(engine.loadedProgram?.totalFrames)
            var left: [Float] = []
            var right: [Float] = []
            var remaining = total
            while remaining > 0 {
                let chunk = try engine.renderOffline(frameCount: min(blockFrames, remaining))
                left.append(contentsOf: chunk.left)
                right.append(contentsOf: chunk.right)
                remaining -= Int64(chunk.frameCount)
                if chunk.frameCount == 0 { break }
            }
            return PlaybackEngine.RenderedAudio(sampleRate: 48_000, left: left, right: right)
        }

        let small = try render(blockFrames: 64)
        let large = try render(blockFrames: 4096)

        XCTAssertEqual(small.frameCount, large.frameCount)
        XCTAssertEqual(
            small.canonicalData(), large.canonicalData(),
            "Rendering in 64-frame blocks differed from 4096-frame blocks; scheduling depends on buffer size."
        )
    }

    // MARK: The rendered signal matches the timeline

    /// Every note the timeline schedules is audible, at the microsecond the
    /// timeline put it at.
    ///
    /// This is what makes the rest of the suite mean something: without it,
    /// "deterministic" only says the engine repeats itself, not that it plays
    /// the right piece.
    func testDetectedOnsetsMatchTheTimelineOnsets() throws {
        // One line only, so onset detection is unambiguous.
        let musicXML = ScoreXML.Score(
            workTitle: "Onsets",
            composer: "Fixture",
            parts: [
                ScoreXML.Part(
                    id: "P1",
                    name: "Line",
                    measures: [
                        ScoreXML.Measure(
                            number: "1",
                            items: [
                                .attributes(ScoreXML.Attributes(
                                    divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                                )),
                                .direction(ScoreXML.Direction(words: "Moderato", sound: ["tempo": "120"])),
                                .note(ScoreXML.Note(pitch: "A4", duration: 4, type: "quarter")),
                                .note(ScoreXML.Note(pitch: "C5", duration: 4, type: "quarter")),
                                .note(ScoreXML.Note(pitch: "E5", duration: 4, type: "quarter")),
                                .note(ScoreXML.Note(pitch: "A5", duration: 4, type: "quarter"))
                            ]
                        )
                    ]
                )
            ]
        ).data()

        let timeline = try AudioRenderFixtures.timeline(musicXML)
        let audio = try PlaybackEngine.renderTimelineOffline(timeline)

        let expected = timeline.lines[0].events.map(\.onsetMicroseconds).sorted()
        let detected = AudioRenderFixtures.detectedOnsetsMicroseconds(audio)

        XCTAssertEqual(
            detected.count, expected.count,
            "Expected \(expected.count) onsets in the rendered audio, found \(detected.count)."
        )

        // 15 ms tolerance: the flux detector resolves to its 128-frame hop
        // (2.7 ms) and reports where the voice's 8 ms attack began to rise, so
        // a few milliseconds of lag is the method working, not the engine
        // drifting. It is still an order of magnitude tighter than the ~90 ms
        // humanized offsets the test below has to be able to see.
        for (index, expectedOnset) in expected.enumerated() where index < detected.count {
            XCTAssertEqual(
                Double(detected[index]), Double(expectedOnset), accuracy: 15_000,
                "Note \(index) sounded at \(detected[index]) µs but the timeline scheduled it at \(expectedOnset) µs."
            )
        }
    }

    /// **The engine schedules humanized microseconds, not tempo-map ticks.**
    ///
    /// PLY002 flagged this as the single way this leaf can silently break its
    /// contract: `PerformanceEvent.onsetTicks` is the *notated* position, kept
    /// unmoved so the transport can highlight the right note, while
    /// `onsetMicroseconds` is where the note actually sounds. An engine that
    /// re-derived time from ticks through the tempo map would discard every
    /// humanized offset, and a test that only checked pitches and note counts
    /// would stay green.
    ///
    /// So this renders the same score twice, humanization off and on, and
    /// requires the audio to differ. If the two ever converge, the engine has
    /// started reading the wrong field.
    func testHumanizedOnsetsAreRenderedNotTempoMapOnsets() throws {
        let musicXML = MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 6)

        let literal = try AudioRenderFixtures.timeline(musicXML, settings: .literal)
        let humanized = try AudioRenderFixtures.timeline(
            musicXML,
            settings: RealizationSettings(humanization: HumanizationSettings(isEnabled: true, intensity: 100))
        )

        // Precondition: the two timelines really do differ, or this test would
        // be proving nothing about the engine.
        let literalOnsets = literal.lines.flatMap { $0.events.map(\.onsetMicroseconds) }
        let humanizedOnsets = humanized.lines.flatMap { $0.events.map(\.onsetMicroseconds) }
        XCTAssertNotEqual(
            literalOnsets, humanizedOnsets,
            "The fixture produced identical timelines, so this test cannot detect the bug it exists for."
        )

        let literalAudio = try PlaybackEngine.renderTimelineOffline(literal)
        let humanizedAudio = try PlaybackEngine.renderTimelineOffline(humanized)

        XCTAssertNotEqual(
            literalAudio.canonicalData(), humanizedAudio.canonicalData(),
            "Humanized and literal timelines rendered to identical audio. The engine is deriving time from "
                + "onsetTicks through the tempo map instead of scheduling onsetMicroseconds."
        )

        // Stronger than "they differ": the humanized render's onsets must track
        // the humanized timeline, not the literal one.
        let detected = AudioRenderFixtures.detectedOnsetsMicroseconds(humanizedAudio)
        let expectedHumanized = humanized.lines[0].events.map(\.onsetMicroseconds).sorted()
        let expectedLiteral = literal.lines[0].events.map(\.onsetMicroseconds).sorted()

        func totalDeviation(_ reference: [Int64]) -> Double {
            var total = 0.0
            for onset in detected {
                let nearest = reference.min { abs($0 - onset) < abs($1 - onset) }
                total += Double(abs((nearest ?? 0) - onset))
            }
            return total / Double(max(1, detected.count))
        }

        XCTAssertLessThan(
            totalDeviation(expectedHumanized), totalDeviation(expectedLiteral),
            "The rendered onsets sit closer to the literal timeline than the humanized one."
        )
    }

    /// A sustain span has to reach the voice, or every pedalled piece plays dry.
    func testTheSustainPedalLengthensWhatIsHeard() throws {
        let timeline = try AudioRenderFixtures.timeline(MusicXMLScoreFixtures.pedalStudy())
        XCTAssertFalse(
            timeline.lines.flatMap(\.pedalSpans).isEmpty,
            "The pedal fixture produced no spans, so this test cannot see the pedal."
        )

        let withPedal = try PlaybackEngine.renderTimelineOffline(timeline)

        // Same timeline with the spans stripped: the only difference is the pedal.
        let dryLines = timeline.lines.map {
            PerformanceLine(id: $0.id, name: $0.name, events: $0.events, pedalSpans: [])
        }
        let dryTimeline = PerformanceTimeline(
            pieceID: timeline.pieceID,
            contentSHA256: timeline.contentSHA256,
            ticksPerQuarter: timeline.ticksPerQuarter,
            settings: timeline.settings,
            seed: timeline.seed,
            totalMicroseconds: timeline.totalMicroseconds,
            totalTicks: timeline.totalTicks,
            lines: dryLines,
            report: timeline.report
        )
        let withoutPedal = try PlaybackEngine.renderTimelineOffline(dryTimeline)

        XCTAssertGreaterThan(
            withPedal.rms(), withoutPedal.rms(),
            "Removing every sustain span did not reduce the energy in the render, so the pedal is not reaching the voice."
        )
    }

    // MARK: Program construction

    /// Microseconds convert to frames the same way everywhere, at both rates
    /// the app can plausibly run at.
    func testMicrosecondToFrameConversionRoundTrips() {
        for sampleRate in [44_100.0, 48_000.0] {
            for microseconds: Int64 in [0, 1_000, 500_000, 53_300_000] {
                let frame = RenderProgram.frame(forMicroseconds: microseconds, sampleRate: sampleRate)
                let back = RenderProgram.microseconds(forFrame: frame, sampleRate: sampleRate)
                XCTAssertEqual(
                    Double(back), Double(microseconds), accuracy: 30,
                    "Round trip at \(sampleRate) Hz lost \(abs(back - microseconds)) µs."
                )
            }
        }
    }

    /// The program keeps the compiled score's line order and identity, so a
    /// mixer strip in increment 004 lands on the line it names.
    func testProgramPreservesLineIdentityAndOrder() throws {
        let timeline = try AudioRenderFixtures.timeline(MusicXMLScoreFixtures.stringQuartetMovement())
        let program = try RenderProgram(timeline: timeline, sampleRate: 48_000)

        XCTAssertEqual(program.lineCount, timeline.lines.count)
        XCTAssertEqual(program.lineIDs, timeline.lines.map(\.id))
        for (index, line) in timeline.lines.enumerated() {
            XCTAssertEqual(program.index(of: line.id), index)
        }
    }

    /// The rendered program runs past the last note so a release tail is not
    /// chopped off mid-decay.
    func testProgramLeavesRoomForTheReleaseTail() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let program = try RenderProgram(timeline: timeline, sampleRate: 48_000)

        let timelineFrames = RenderProgram.frame(
            forMicroseconds: timeline.totalMicroseconds, sampleRate: 48_000
        )
        XCTAssertGreaterThan(program.totalFrames, timelineFrames)
    }
}
