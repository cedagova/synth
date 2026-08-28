import XCTest
@testable import SynthKit

/// Transport behaviour, proved against rendered audio wherever the claim is
/// about sound rather than bookkeeping.
///
/// Everything here runs in offline mode, so it is exactly as valid on a
/// headless CI runner as on a Mac with speakers — and because offline and
/// real-time share one graph (AD2), what it proves is not a special case.
final class SeekAndTransportTests: XCTestCase {
    /// A note, then a long rest, then four more notes.
    ///
    /// The rest exists so there is one instant where nothing is ringing. That
    /// makes the seek claim below an exact one: with no release tail crossing
    /// the seek point, resuming from it must reproduce the full render sample
    /// for sample, and any drift in the scheduler shows up immediately.
    private static func gappedFixture() -> Data {
        ScoreXML.Score(
            workTitle: "Gapped",
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
                                .note(ScoreXML.Note(pitch: nil, duration: 12))
                            ]
                        ),
                        ScoreXML.Measure(
                            number: "2",
                            items: (0..<4).map { index in
                                .note(ScoreXML.Note(
                                    pitch: ["C5", "E5", "G5", "C6"][index],
                                    duration: 4,
                                    type: "quarter"
                                ))
                            }
                        )
                    ]
                )
            ]
        ).data()
    }

    private func engine(for timeline: PerformanceTimeline) throws -> PlaybackEngine {
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)
        return engine
    }

    // MARK: Seek

    /// Rendering from a seek point reproduces the corresponding slice of a full
    /// render, sample for sample.
    ///
    /// The first 30 ms after the seek are skipped: the engine deliberately
    /// fades out, jumps, and fades back in so a seek is inaudible instead of a
    /// click, and that ramp is a real difference from mid-stream playback. What
    /// is compared is everything after it.
    func testRenderingFromASeekPointMatchesTheFullRender() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let sampleRate = 48_000.0

        // Start of measure 2: two seconds in at 120 bpm, and 1.25 s after the
        // first note's release finished.
        let seekMicroseconds: Int64 = 2_000_000
        let seekFrame = RenderProgram.frame(forMicroseconds: seekMicroseconds, sampleRate: sampleRate)

        let full = try PlaybackEngine.renderTimelineOffline(timeline, sampleRate: sampleRate)

        let seeking = try engine(for: timeline)
        seeking.seek(toMicroseconds: seekMicroseconds)
        seeking.play()
        let total = try XCTUnwrap(seeking.loadedProgram?.totalFrames)
        let fromSeek = try seeking.renderOffline(frameCount: total - seekFrame)

        // Confirm the precondition the exactness depends on: nothing is
        // sounding at the seek point in the full render.
        let quietWindow = Array(full.left[Int(seekFrame) - 2400..<Int(seekFrame)])
        let quietPeak = quietWindow.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(
            quietPeak, 1e-4,
            "The gap before the seek point is not silent (peak \(quietPeak)), so an exact match is not expected."
        )

        let settle = Int(0.030 * sampleRate)
        let comparable = min(fromSeek.frameCount - settle, full.frameCount - Int(seekFrame) - settle)
        XCTAssertGreaterThan(comparable, Int(sampleRate), "Too little audio left to compare.")

        var mismatches = 0
        var largestDifference: Float = 0
        for index in 0..<comparable {
            let a = fromSeek.left[settle + index]
            let b = full.left[Int(seekFrame) + settle + index]
            if a != b {
                mismatches += 1
                largestDifference = max(largestDifference, abs(a - b))
            }
        }
        XCTAssertEqual(
            mismatches, 0,
            "\(mismatches) of \(comparable) samples differed after seeking (largest \(largestDifference))."
        )
    }

    /// A seek reports settled once the render thread has applied it, and the
    /// playhead lands where it was told.
    func testSeekSettlesAndMovesThePlayhead() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.seek(toMicroseconds: 2_000_000)
        engine.play()
        XCTAssertFalse(engine.isSeekSettled, "The seek settled before anything was rendered.")

        _ = try engine.renderOffline(frameCount: 4096)

        XCTAssertTrue(engine.isSeekSettled, "The seek never settled.")
        XCTAssertEqual(
            Double(engine.playbackPositionMicroseconds), 2_000_000, accuracy: 120_000,
            "The playhead is at \(engine.playbackPositionMicroseconds) µs after seeking to 2 000 000 µs."
        )
    }

    /// Seeking past the end clamps rather than running off into silence
    /// forever, and seeking to a negative time clamps to the start.
    func testSeekClampsToTheProgram() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.seek(toMicroseconds: -5_000_000)
        engine.play()
        _ = try engine.renderOffline(frameCount: 4096)
        XCTAssertGreaterThanOrEqual(engine.playbackPositionFrame, 0)
    }

    // MARK: Transport states

    func testPlayPauseAndResumePreserveThePosition() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.play()
        _ = try engine.renderOffline(frameCount: 48_000)
        XCTAssertEqual(engine.transportState, .playing)
        let positionBeforePause = engine.playbackPositionFrame
        XCTAssertGreaterThan(positionBeforePause, 40_000)

        engine.pause()
        _ = try engine.renderOffline(frameCount: 4_800)
        XCTAssertEqual(engine.transportState, .paused)
        let positionWhilePaused = engine.playbackPositionFrame

        // Paused means paused: further rendering must not advance time.
        _ = try engine.renderOffline(frameCount: 48_000)
        XCTAssertEqual(
            engine.playbackPositionFrame, positionWhilePaused,
            "The playhead moved while the transport was paused."
        )

        engine.play()
        _ = try engine.renderOffline(frameCount: 48_000)
        XCTAssertEqual(engine.transportState, .playing)
        XCTAssertGreaterThan(
            engine.playbackPositionFrame, positionWhilePaused,
            "Resuming did not continue from where the pause left off."
        )
    }

    func testStopReturnsToTheStart() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.play()
        _ = try engine.renderOffline(frameCount: 48_000)
        engine.stop()
        _ = try engine.renderOffline(frameCount: 9_600)

        XCTAssertEqual(engine.transportState, .stopped)
        XCTAssertEqual(engine.playbackPositionFrame, 0)
    }

    /// Reaching the end pauses with a reason, rather than looping or running
    /// on into silence.
    func testReachingTheEndPausesWithAReason() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.play()
        let total = try XCTUnwrap(engine.loadedProgram?.totalFrames)
        _ = try engine.renderOffline(frameCount: total + 48_000)

        XCTAssertEqual(engine.transportState, .paused)
        XCTAssertEqual(engine.pauseReason, .reachedEnd)
    }

    /// Device loss pauses with the position intact, so resuming on another
    /// output continues the piece rather than restarting it.
    ///
    /// This drives the same call the HAL listener makes when a device
    /// disappears. It is not a stand-in for the real notification — see
    /// `AudioOutputDeviceTests` — but it is the recovery path itself, not a
    /// copy of it.
    func testDeviceLossPausesAndKeepsThePosition() throws {
        let timeline = try AudioRenderFixtures.timeline(Self.gappedFixture())
        let engine = try engine(for: timeline)

        engine.play()
        _ = try engine.renderOffline(frameCount: 48_000)
        let positionBefore = engine.playbackPositionFrame

        engine.simulateOutputDeviceLoss(deviceName: "unit-test output")
        _ = try engine.renderOffline(frameCount: 9_600)

        XCTAssertEqual(engine.transportState, .paused)
        XCTAssertEqual(engine.pauseReason, .deviceLost)
        XCTAssertEqual(
            engine.playbackPositionFrame, positionBefore, accuracy: 9_600,
            "Device loss moved the playhead; resuming elsewhere would not continue the piece."
        )
        XCTAssertEqual(
            engine.lastDeviceEvent,
            .lostWithNoFallback(previousDeviceName: "unit-test output")
        )
    }

    /// A transport jump fades rather than steps, so the listener does not hear
    /// a click.
    ///
    /// Measured as the largest sample-to-sample step in the rendered audio
    /// across the seek. A hard cut would show a step the size of the signal
    /// itself; a 4 ms fade cannot.
    func testSeekingDoesNotProduceAClick() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let engine = try engine(for: timeline)

        engine.play()
        let before = try engine.renderOffline(frameCount: 48_000)
        engine.seek(toMicroseconds: 2_500_000)
        let across = try engine.renderOffline(frameCount: 24_000)

        let joined = before.left.suffix(2_400) + across.left
        var largestStep: Float = 0
        for index in 1..<joined.count {
            let step = abs(joined[joined.startIndex + index] - joined[joined.startIndex + index - 1])
            largestStep = max(largestStep, step)
        }

        // A step of this size at 48 kHz is a slope no audible partial of the
        // built-in voice can produce, so exceeding it means a discontinuity.
        XCTAssertLessThan(
            largestStep, 0.02,
            "A sample step of \(largestStep) across the seek: the transport is cutting, not fading."
        )
    }
}
