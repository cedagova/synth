import Foundation
import XCTest
@testable import SynthKit

/// #92's measured switch: how long the music is interrupted, and how big a
/// step it takes, when Compare swaps one preset's performance for another's
/// mid-note.
///
/// **A measurement first and an assertion second.** The issue asks for the gap
/// and the peak discontinuity to be *recorded*, and says what to do if the
/// fade approach turns out clearly audible: write the number down and stop.
/// So every figure is printed (search the test log for `SWITCH-GAP`) and
/// attached, and the assertions are bounds the switch must stay inside rather
/// than the number itself.
///
/// **What the numbers say.** The fade removes the click: the old program is
/// no longer cut off mid-waveform. It does not remove the gap, and cannot: a
/// rebuilt program relocates exactly as a seek does, which silences every
/// voice and resumes each line at its *next onset* — a note already sounding
/// at the switch is not restarted. So the music is interrupted from the switch
/// to the next note, which is the same thing a seek mid-note already does.
/// Closing that would mean re-striking held notes or keeping two programs
/// resident, which is the engine work the issue puts out of scope.
///
/// Everything runs through `PlaybackEngine.switchFaded`, the call Compare
/// makes in both directions, on an offline engine so the rendered samples are
/// the samples a listener would hear.
final class PresetSwitchDeclickTests: XCTestCase {
    private static let sampleRate: Double = 48_000

    /// About 1.05 s: 50 ms into the third quarter note (onsets every 0.5 s), so
    /// the switch lands mid-waveform at full level rather than on an onset or
    /// in a release. The odd 37 frames matter: at exactly 1.05 s both of the
    /// fixture's pitches (A5 and A2) happen to be crossing zero, and a cut there
    /// would not click whether it was faded or not.
    private static let beforeFrames: Int64 = 50_437
    private static let afterFrames: Int64 = 48_000

    /// An RMS below this over one millisecond counts as silence: -60 dBFS.
    private static let silence = 0.001

    private struct Measurement {
        /// Where the switch happened, and the next note onset after it.
        let switchMicroseconds: Int64
        let nextOnsetMicroseconds: Int64
        /// How long the output stayed below -60 dBFS after the switch.
        let interruptionMilliseconds: Double
        /// The largest sample-to-sample step across the join itself.
        let joinStep: Float
        /// The largest step anywhere in the steady music either side of it.
        let musicalStep: Float
        /// Wall-clock time the switch call took. In real time the graph is
        /// stopped for this long, inside the interruption.
        let rebuildMilliseconds: Double

        var interruptionPastNextOnsetMilliseconds: Double {
            interruptionMilliseconds - Double(nextOnsetMicroseconds - switchMicroseconds) / 1_000
        }
    }

    func testTheFadedSwitchDoesNotClickAndResumesAtTheNextNote() throws {
        let faded = try measureSwitch(faded: true)
        let abrupt = try measureSwitch(faded: false)

        let report = String(
            format: "SWITCH-GAP switch at %.3f s, next onset %.3f s | faded: interruption "
                + "%.1f ms (%.1f ms past the next onset), join step %.4f vs music's own %.4f "
                + "(ratio %.2f), switch call %.1f ms | abrupt rebuild (pre-#92): interruption "
                + "%.1f ms, join step %.4f (ratio %.2f)",
            Double(faded.switchMicroseconds) / 1_000_000,
            Double(faded.nextOnsetMicroseconds) / 1_000_000,
            faded.interruptionMilliseconds, faded.interruptionPastNextOnsetMilliseconds,
            faded.joinStep, faded.musicalStep,
            faded.joinStep / max(faded.musicalStep, .leastNonzeroMagnitude),
            faded.rebuildMilliseconds,
            abrupt.interruptionMilliseconds, abrupt.joinStep,
            abrupt.joinStep / max(abrupt.musicalStep, .leastNonzeroMagnitude)
        )
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Compare switch gap"
        attachment.lifetime = .keepAlways
        add(attachment)

        // No step bigger than the music itself takes — that is what "no click"
        // means for a signal that is already moving.
        XCTAssertLessThanOrEqual(
            faded.joinStep, faded.musicalStep,
            "The faded switch steps further than the music ever does: it clicks."
        )
        // And well below the cut the switch made before the fade: the same
        // instant, rebuilt under the running transport.
        XCTAssertLessThan(
            faded.joinStep, abrupt.joinStep / 2,
            "The fade did not take the step out of the switch."
        )
        // Sound comes back with the next note and not later: the fade, the
        // rebuild and the master's lookahead add no more than a few ms to what
        // a seek to the same place costs.
        XCTAssertLessThan(
            faded.interruptionPastNextOnsetMilliseconds, 10,
            "The switch kept the music silent past the next note."
        )
        // The switch call itself, which in real time is time the graph is
        // stopped. Generous for a loaded CI runner; the figure is in the log.
        XCTAssertLessThan(faded.rebuildMilliseconds, 250)
    }

    // MARK: Driving it

    /// Render a stretch of the two-line fixture on the plain voice, switch to a
    /// bright saw with a hard-left mix — sounds and mix, as a preset switch
    /// changes both — and render on, then measure the join.
    private func measureSwitch(faded: Bool) throws -> Measurement {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let engine = PlaybackEngine(voices: .uniform(SynthPatchVoiceProvider()))
        try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
        try engine.load(timeline: timeline)
        engine.play()

        let before = try engine.renderOffline(frameCount: Self.beforeFrames)
        XCTAssertEqual(engine.transportState, .playing)
        let position = engine.playbackPositionMicroseconds
        let nextOnset = try XCTUnwrap(
            timeline.lines.flatMap(\.events).map(\.onsetMicroseconds).filter { $0 > position }.min()
        )

        let bright = LineVoiceAssignment.uniform(SynthPatchVoiceProvider(patch: brightPatch()))
        let applyReference = {
            try engine.setVoices(bright)
            for index in 0..<(engine.loadedProgram?.lineCount ?? 0) {
                engine.mixer(forLineAt: index)?.pan = -1
            }
        }

        let started = Date()
        var fade: PlaybackEngine.RenderedAudio?
        if faded {
            fade = try engine.switchFaded(
                resumingAtMicroseconds: position, producedMaster: .off, applyReference
            )
        } else {
            // What a preset switch did before #92: rebuild under the running
            // transport, which cuts the old program off wherever it was.
            try applyReference()
        }
        let rebuild = Date().timeIntervalSince(started) * 1_000

        let after = try engine.renderOffline(frameCount: Self.afterFrames)
        XCTAssertEqual(engine.transportState, .playing, "The switch did not resume playing.")
        XCTAssertEqual(engine.pauseReason, .none)

        // Both channels, since the reference is panned hard left.
        let fadeMono = mono(fade)
        let joined = mono(before) + fadeMono + mono(after)
        let switchAt = before.frameCount
        // The join: the last sample before the switch through the first two
        // milliseconds of the arriving program.
        let joinEnd = switchAt + fadeMono.count + Int(Self.sampleRate / 500)
        let steadyFrom = Int(Self.sampleRate / 10)

        return Measurement(
            switchMicroseconds: position,
            nextOnsetMicroseconds: nextOnset,
            interruptionMilliseconds: interruption(joined, from: switchAt),
            joinStep: largestStep(joined, in: switchAt..<joinEnd),
            // The steady music either side, clear of the first onset and of the
            // join — both sounds, since a saw steps further than the plain voice.
            musicalStep: max(
                largestStep(joined, in: steadyFrom..<(switchAt - Int(Self.sampleRate / 100))),
                largestStep(joined, in: (joinEnd + Int(Self.sampleRate / 2))..<joined.count)
            ),
            rebuildMilliseconds: rebuild
        )
    }

    private func mono(_ audio: PlaybackEngine.RenderedAudio?) -> [Float] {
        guard let audio else { return [] }
        return zip(audio.left, audio.right).map { ($0 + $1) / 2 }
    }

    /// Milliseconds from the first silent millisecond at or after `start` (within
    /// 20 ms of it) to the first audible one after that; zero if the output
    /// never went silent.
    private func interruption(_ samples: [Float], from start: Int) -> Double {
        let block = Int(Self.sampleRate / 1_000)
        func isSilent(_ index: Int) -> Bool {
            let slice = samples[index..<min(samples.count, index + block)]
            let power = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)
            return power.squareRoot() < Self.silence
        }
        var index = start
        while index < start + block * 20, !isSilent(index) { index += 1 }
        guard index < start + block * 20 else { return 0 }
        let silentFrom = index
        while index + block <= samples.count, isSilent(index) { index += 1 }
        return Double(index - silentFrom) / Self.sampleRate * 1_000
    }

    private func largestStep(_ samples: [Float], in range: Range<Int>) -> Float {
        var largest: Float = 0
        for index in range where index > 0 && index < samples.count {
            largest = max(largest, abs(samples[index] - samples[index - 1]))
        }
        return largest
    }

    private func brightPatch() -> SynthPatch {
        SynthPatch(
            identifier: "declick.bright",
            name: "Declick Bright",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.9),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4, cutoffHertz: 16_000),
            outputLevel: 0.25
        )
    }
}
