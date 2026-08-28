import AVFoundation
import XCTest
@testable import SynthKit

/// Issue #15: "The orchestral reference piece plays start-to-finish
/// dropout-free on target hardware with the default voice", and issue #17's
/// re-measurement of the same budget through the synthesizer.
///
/// This is the one claim offline rendering cannot make. An offline render has
/// no deadline to miss, so it proves the engine is *correct* and says nothing
/// about whether it is *fast enough*. These tests run the live graph against
/// real hardware and read back the engine's own overload counters.
///
/// Two tiers, because a start-to-finish orchestral run takes as long as the
/// piece does:
///
/// - the short smoke runs by default wherever there is an output device, and
///   catches a live graph that does not start, glitches immediately, or
///   overloads at the very first tutti;
/// - the full start-to-finish guardrail is opt-in through
///   `SYNTH_REALTIME_GUARDRAIL=1`, because a minute of real time does not
///   belong in every `xcodebuild test`.
///
/// The overload-*ratio* bounds live in the tier that runs on target hardware.
/// See `testLivePlaybackThroughASynthPatchStartsCleanly` for why a Debug build
/// on a shared virtual machine cannot support one for the synthesizer.
///
/// Everything here skips with a reason on a headless runner rather than
/// pretending to pass.
final class RealtimePlaybackTests: XCTestCase {
    /// Set `SYNTH_REALTIME_GUARDRAIL=1` to run the full-length checks.
    private var fullGuardrailEnabled: Bool {
        ProcessInfo.processInfo.environment["SYNTH_REALTIME_GUARDRAIL"] == "1"
    }

    private func requireOutputDevice() throws {
        try XCTSkipIf(
            !AudioRenderFixtures.hasOutputDevice,
            "No audio output device on this machine (expected on a headless CI runner)."
        )
    }

    /// Block until the render thread has actually picked up the play command.
    ///
    /// `play()` only stores a command; the transport does not report `.playing`
    /// until the next render block reads it. A "while playing" loop entered
    /// before that sees `.stopped` and exits immediately, which looks exactly
    /// like a piece that finished in no time at all.
    @discardableResult
    private func waitUntilPlaying(_ engine: PlaybackEngine, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.transportState == .playing { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Plays `timeline` in real time for `seconds` and reports what happened.
    private func playLive(
        _ timeline: PerformanceTimeline,
        seconds: Double
    ) throws -> (statistics: PlaybackEngine.RenderStatistics,
                 elapsed: Double,
                 advanced: Int64,
                 state: PlaybackEngine.TransportState,
                 reason: PlaybackEngine.PauseReason) {
        let engine = PlaybackEngine()
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()
        _ = waitUntilPlaying(engine)

        let started = Date()
        // Poll rather than one long sleep, so a pause is noticed near when it
        // happens instead of only at the end.
        var observedPause: PlaybackEngine.PauseReason = .none
        while Date().timeIntervalSince(started) < seconds {
            Thread.sleep(forTimeInterval: 0.05)
            if engine.transportState != .playing, engine.pauseReason != .none {
                observedPause = engine.pauseReason
                break
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        let statistics = engine.statistics
        let advanced = engine.playbackPositionMicroseconds
        let state = engine.transportState
        let reason = observedPause != .none ? observedPause : engine.pauseReason

        engine.stop()
        engine.stopEngine()
        return (statistics, elapsed, advanced, state, reason)
    }

    // MARK: Short smoke (runs wherever there is a device)

    /// The live graph starts, produces audio, and advances the playhead in
    /// step with the wall clock.
    func testLivePlaybackAdvancesInRealTime() throws {
        try requireOutputDevice()

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            settings: .standard
        )
        let result = try playLive(timeline, seconds: 3.0)

        XCTAssertEqual(result.state, .playing, "Live playback stopped early (\(result.reason)).")
        XCTAssertGreaterThan(result.statistics.renderedBlocks, 0, "The render callback never ran.")

        // The playhead should track the wall clock within a buffer or two.
        let advancedSeconds = Double(result.advanced) / 1_000_000
        XCTAssertEqual(
            advancedSeconds, result.elapsed, accuracy: 0.25,
            "The playhead advanced \(advancedSeconds) s over \(result.elapsed) s of wall clock."
        )
        XCTAssertEqual(result.statistics.overloadPauses, 0, "The engine gave up under load.")
        XCTAssertLessThan(
            result.statistics.overloadRatio, 0.02,
            "\(result.statistics.overloadBlocks) of \(result.statistics.renderedBlocks) blocks missed "
                + "85% of their deadline."
        )
    }

    /// The expressive reference stresses a different part of the scheduler than
    /// the orchestral one: ornaments, grace notes and pedal spans rather than
    /// raw part count. PLY002 asked for both to be used.
    func testLivePlaybackOfTheExpressiveReference() throws {
        try requireOutputDevice()

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            settings: .standard
        )
        let result = try playLive(timeline, seconds: 3.0)

        XCTAssertEqual(result.state, .playing, "Expressive playback stopped early (\(result.reason)).")
        XCTAssertEqual(result.statistics.overloadPauses, 0)
        XCTAssertLessThan(result.statistics.overloadRatio, 0.02)
    }

    /// Output must have headroom: the default voice is scaled so a full tutti
    /// does not clip, and this is where that claim is checked rather than
    /// assumed.
    func testLiveOutputDoesNotClip() throws {
        try requireOutputDevice()

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            settings: .standard
        )
        let result = try playLive(timeline, seconds: 3.0)
        XCTAssertGreaterThan(result.statistics.peakLevel, 0, "No audio was produced.")
        XCTAssertLessThan(
            result.statistics.peakLevel, 1.0,
            "Peak reached \(result.statistics.peakLevel); the orchestral reference clips."
        )
    }

    // MARK: Full guardrail (opt-in)

    /// **The dropout guardrail.** The orchestral reference, start to finish, in
    /// real time, with the default voice.
    ///
    /// Opt in with `SYNTH_REALTIME_GUARDRAIL=1`. Reported as counts rather than
    /// a bare pass: the number of blocks that missed their deadline, and the
    /// wall clock against the timeline's own duration.
    func testOrchestralReferencePlaysStartToFinishWithoutDropouts() throws {
        try requireOutputDevice()
        try XCTSkipIf(
            !fullGuardrailEnabled,
            "Set SYNTH_REALTIME_GUARDRAIL=1 to run the full-length real-time guardrail."
        )

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            settings: .standard
        )
        let expectedSeconds = Double(timeline.totalMicroseconds) / 1_000_000

        let engine = PlaybackEngine()
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()
        XCTAssertTrue(waitUntilPlaying(engine), "Playback never started.")

        let started = Date()
        while engine.transportState == .playing,
              Date().timeIntervalSince(started) < expectedSeconds + 15 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let statistics = engine.statistics
        let reason = engine.pauseReason
        engine.stopEngine()

        print("""
            Dropout guardrail — orchestral reference
              lines:            \(timeline.lines.count)
              events:           \(timeline.eventCount)
              timeline length:  \(String(format: "%.1f", expectedSeconds)) s
              wall clock:       \(String(format: "%.1f", elapsed)) s
              rendered blocks:  \(statistics.renderedBlocks)
              overload blocks:  \(statistics.overloadBlocks) \
            (\(String(format: "%.4f", statistics.overloadRatio * 100))%)
              overload pauses:  \(statistics.overloadPauses)
              peak level:       \(String(format: "%.3f", statistics.peakLevel))
              ended because:    \(reason)
            """)

        XCTAssertEqual(reason, .reachedEnd, "Playback did not run to the end; it stopped for \(reason).")
        XCTAssertEqual(statistics.overloadPauses, 0, "The engine degraded to a pause under load.")
        XCTAssertLessThan(
            statistics.overloadRatio, 0.001,
            "\(statistics.overloadBlocks) of \(statistics.renderedBlocks) blocks missed their deadline."
        )
        XCTAssertEqual(
            elapsed, expectedSeconds, accuracy: expectedSeconds * 0.05 + 3,
            "Playback took \(elapsed) s for a \(expectedSeconds) s piece."
        )
    }

    /// The same guardrail for the expressive reference.
    func testExpressiveReferencePlaysStartToFinishWithoutDropouts() throws {
        try requireOutputDevice()
        try XCTSkipIf(
            !fullGuardrailEnabled,
            "Set SYNTH_REALTIME_GUARDRAIL=1 to run the full-length real-time guardrail."
        )

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            settings: .standard
        )
        let expectedSeconds = Double(timeline.totalMicroseconds) / 1_000_000

        let engine = PlaybackEngine()
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()
        XCTAssertTrue(waitUntilPlaying(engine), "Playback never started.")

        let started = Date()
        while engine.transportState == .playing,
              Date().timeIntervalSince(started) < expectedSeconds + 15 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let statistics = engine.statistics
        let reason = engine.pauseReason
        engine.stopEngine()

        print("""
            Dropout guardrail — expressive reference
              timeline length:  \(String(format: "%.1f", expectedSeconds)) s
              wall clock:       \(String(format: "%.1f", elapsed)) s
              overload blocks:  \(statistics.overloadBlocks) of \(statistics.renderedBlocks)
              overload pauses:  \(statistics.overloadPauses)
              peak level:       \(String(format: "%.3f", statistics.peakLevel))
            """)

        XCTAssertEqual(reason, .reachedEnd)
        XCTAssertEqual(statistics.overloadPauses, 0)
        XCTAssertLessThan(statistics.overloadRatio, 0.001)
    }

    /// **The REQ-013 budget, re-measured for the synthesizer.**
    ///
    /// Increment 002 established that the orchestral reference plays
    /// dropout-free with the built-in default voice. A full synthesis voice is
    /// far heavier — three oscillators, a four-pole filter, six live modulation
    /// routes and four effects per line instead of three sine partials — so
    /// SYN001 re-opens the question rather than inheriting the answer.
    ///
    /// Reported as counts, not as a bare pass, so the margin against the
    /// increment-002 baseline is visible rather than implied.
    func testOrchestralReferencePlaysWithoutDropoutsThroughSynthPatches() throws {
        try requireOutputDevice()
        try XCTSkipIf(
            !fullGuardrailEnabled,
            "Set SYNTH_REALTIME_GUARDRAIL=1 to run the full-length real-time guardrail."
        )

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            settings: .standard
        )
        let expectedSeconds = Double(timeline.totalMicroseconds) / 1_000_000

        let engine = PlaybackEngine(
            voiceProvider: SynthPatchVoiceProvider(
                patch: SynthEngineIntegrationTests.demandingPatch()))
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()
        XCTAssertTrue(waitUntilPlaying(engine), "Playback never started.")

        let started = Date()
        while engine.transportState == .playing,
              Date().timeIntervalSince(started) < expectedSeconds + 15 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let statistics = engine.statistics
        let reason = engine.pauseReason
        engine.stopEngine()

        print("""
            Dropout guardrail \u{2014} orchestral reference through synth patches
              lines:            \(timeline.lines.count)
              events:           \(timeline.eventCount)
              timeline length:  \(String(format: "%.1f", expectedSeconds)) s
              wall clock:       \(String(format: "%.1f", elapsed)) s
              rendered blocks:  \(statistics.renderedBlocks)
              overload blocks:  \(statistics.overloadBlocks) \
            (\(String(format: "%.4f", statistics.overloadRatio * 100))%)
              overload pauses:  \(statistics.overloadPauses)
              peak level:       \(String(format: "%.3f", statistics.peakLevel))
              ended because:    \(reason)
            """)

        XCTAssertEqual(reason, .reachedEnd, "Playback did not run to the end; it stopped for \(reason).")
        XCTAssertEqual(statistics.overloadPauses, 0, "The engine degraded to a pause under load.")
        XCTAssertLessThan(
            statistics.overloadRatio, 0.001,
            "\(statistics.overloadBlocks) of \(statistics.renderedBlocks) blocks missed their deadline."
        )
        XCTAssertLessThan(
            statistics.peakLevel, 1.0,
            "The orchestral reference clips at \(statistics.peakLevel) through synth patches."
        )
        XCTAssertEqual(
            elapsed, expectedSeconds, accuracy: expectedSeconds * 0.05 + 3,
            "Playback took \(elapsed) s for a \(expectedSeconds) s piece."
        )
    }

    /// The short live smoke, through the heaviest patch, so a machine with a
    /// device catches a synthesizer that cannot start or that gives up under
    /// load — without waiting for the opt-in guardrail.
    ///
    /// **This deliberately makes no throughput claim, and the reason is worth
    /// stating.** The required check builds `-configuration Debug`, where the
    /// C render core is unoptimised: rendering the orchestral reference
    /// through this patch runs at 2.4× real time in Debug against 26× in
    /// Release on the same machine. On top of that, the runner is a shared
    /// virtual machine with no real audio hardware and no scheduling
    /// guarantees. An overload *ratio* measured there would be a statement
    /// about the runner, and its first act was to fail at 3.46% while the same
    /// build on target hardware missed no deadline at all across the full
    /// 53-second piece.
    ///
    /// So the throughput claim is made where it means something — the opt-in
    /// guardrail above, on target hardware — and what is asserted here is what
    /// this machine can actually support: the graph starts, keeps playing, and
    /// never degrades to the engine's own overload pause.
    func testLivePlaybackThroughASynthPatchStartsCleanly() throws {
        try requireOutputDevice()

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            settings: .standard
        )
        let engine = PlaybackEngine(
            voiceProvider: SynthPatchVoiceProvider(
                patch: SynthEngineIntegrationTests.demandingPatch()))
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()
        XCTAssertTrue(waitUntilPlaying(engine), "Playback never started.")

        Thread.sleep(forTimeInterval: 3)
        let statistics = engine.statistics
        let state = engine.transportState
        let reason = engine.pauseReason
        // Read before stopping: stop rewinds the playhead.
        let advanced = engine.playbackPositionMicroseconds
        engine.stopEngine()

        XCTAssertEqual(state, .playing, "Playback stopped within three seconds (\(reason)).")
        XCTAssertEqual(
            statistics.overloadPauses, 0,
            "The engine gave up under load: \(statistics.overloadBlocks) of "
                + "\(statistics.renderedBlocks) blocks missed their deadline."
        )
        XCTAssertGreaterThan(statistics.renderedBlocks, 10, "The graph produced almost nothing.")
        XCTAssertGreaterThan(
            advanced, 1_000_000,
            "Three seconds of wall clock advanced the playhead by only \(advanced) µs."
        )
    }
}
