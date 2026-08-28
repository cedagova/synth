import XCTest
@testable import SynthKit

/// Issue #15: "Mute/solo/gain/pan applied programmatically per line are audible
/// in rendered output (REQ-008 basis)."
///
/// "Audible" is proved here as a measurement of the rendered buffer, never as a
/// flag read back from the object that set it. A test that sets `isMuted = true`
/// and then asserts `isMuted == true` would pass against an engine that ignores
/// the mixer entirely.
///
/// The engine mixes lines linearly — per-line gain and pan, then one multiply
/// for the master and the declick ramp — so mute and solo can be asserted as
/// *bit* equality against a render of the remaining line alone. Adding `0.0 *
/// x` to a float changes nothing, which is what makes that exactness real
/// rather than lucky.
final class LineMixerRenderTests: XCTestCase {
    /// Upper line is A5 (MIDI 81, 880 Hz), lower is A2 (MIDI 45, 110 Hz).
    private static let upperHertz = AudioRenderFixtures.frequency(ofMIDINote: 81)
    private static let lowerHertz = AudioRenderFixtures.frequency(ofMIDINote: 45)

    private func fixtureTimeline() throws -> PerformanceTimeline {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        XCTAssertEqual(timeline.lines.count, 2, "The mixer fixture must have exactly two lines.")
        return timeline
    }

    private func render(
        _ timeline: PerformanceTimeline,
        configure: @escaping (PlaybackEngine) -> Void = { _ in }
    ) throws -> PlaybackEngine.RenderedAudio {
        try PlaybackEngine.renderTimelineOffline(timeline, configure: configure)
    }

    // MARK: Mute

    /// Muting a line removes exactly that line and leaves the other untouched.
    func testMutingALineRemovesExactlyThatLineFromTheMix() throws {
        let timeline = try fixtureTimeline()

        let full = try render(timeline)
        let upperMuted = try render(timeline) { $0.mixer(forLineAt: 0)?.isMuted = true }

        let upperEnergyFull = AudioRenderFixtures.energy(
            full.left, atHertz: Self.upperHertz, sampleRate: full.sampleRate
        )
        let upperEnergyMuted = AudioRenderFixtures.energy(
            upperMuted.left, atHertz: Self.upperHertz, sampleRate: upperMuted.sampleRate
        )
        let lowerEnergyFull = AudioRenderFixtures.energy(
            full.left, atHertz: Self.lowerHertz, sampleRate: full.sampleRate
        )
        let lowerEnergyMuted = AudioRenderFixtures.energy(
            upperMuted.left, atHertz: Self.lowerHertz, sampleRate: upperMuted.sampleRate
        )

        XCTAssertGreaterThan(upperEnergyFull, 1e-4, "The upper line is not audible in the full mix.")
        XCTAssertLessThan(
            upperEnergyMuted, upperEnergyFull / 1000,
            "Muting the upper line left \(upperEnergyMuted) of energy at \(Self.upperHertz) Hz "
                + "(was \(upperEnergyFull))."
        )
        XCTAssertEqual(
            lowerEnergyMuted, lowerEnergyFull, accuracy: lowerEnergyFull * 0.02,
            "Muting the upper line changed the lower line's energy."
        )
    }

    /// Muting every line produces silence — the engine has no floor of its own.
    func testMutingEveryLineProducesSilence() throws {
        let timeline = try fixtureTimeline()
        let audio = try render(timeline) { engine in
            engine.mixer(forLineAt: 0)?.isMuted = true
            engine.mixer(forLineAt: 1)?.isMuted = true
        }
        XCTAssertEqual(audio.peak(), 0, "Muting every line still produced output.")
    }

    // MARK: Solo

    /// Soloing one line silences the others, and what is left is bit-for-bit
    /// the same as muting each of them individually.
    func testSoloingALineIsExactlyTheSameAsMutingEveryOtherLine() throws {
        let timeline = try fixtureTimeline()

        let soloed = try render(timeline) { $0.mixer(forLineAt: 1)?.isSoloed = true }
        let othersMuted = try render(timeline) { $0.mixer(forLineAt: 0)?.isMuted = true }

        XCTAssertEqual(
            soloed.canonicalData(), othersMuted.canonicalData(),
            "Soloing line 1 did not produce the same audio as muting line 0."
        )

        let upperEnergy = AudioRenderFixtures.energy(
            soloed.left, atHertz: Self.upperHertz, sampleRate: soloed.sampleRate
        )
        let lowerEnergy = AudioRenderFixtures.energy(
            soloed.left, atHertz: Self.lowerHertz, sampleRate: soloed.sampleRate
        )
        XCTAssertGreaterThan(lowerEnergy, 1e-4, "The soloed line is not audible.")
        XCTAssertLessThan(upperEnergy, lowerEnergy / 100, "A non-soloed line is still audible.")
    }

    /// Solo beats mute on the same line: a soloed line that is also muted stays
    /// silent, because mute is the more specific instruction.
    func testMuteWinsOverSoloOnTheSameLine() throws {
        let timeline = try fixtureTimeline()
        let audio = try render(timeline) { engine in
            let line = engine.mixer(forLineAt: 0)
            line?.isSoloed = true
            line?.isMuted = true
        }
        XCTAssertEqual(audio.peak(), 0, "A line that is both soloed and muted still produced output.")
    }

    // MARK: Gain

    /// A gain change moves the rendered level by exactly the decibels asked
    /// for.
    func testGainMovesTheRenderedLevelByTheRequestedDecibels() throws {
        let timeline = try fixtureTimeline()

        // One line only, so the measurement is not diluted by the other.
        func renderUpper(gain: Float) throws -> PlaybackEngine.RenderedAudio {
            try render(timeline) { engine in
                engine.mixer(forLineAt: 1)?.isMuted = true
                engine.mixer(forLineAt: 0)?.gain = gain
            }
        }

        let unity = try renderUpper(gain: 1.0)
        let unityRMS = unity.rms()
        XCTAssertGreaterThan(unityRMS, 1e-4)

        for (gain, expectedDecibels) in [(Float(0.5), -6.0206), (Float(0.25), -12.0412), (Float(2.0), 6.0206)] {
            let changed = try renderUpper(gain: gain)
            let measured = AudioRenderFixtures.decibels(changed.rms() / unityRMS)
            XCTAssertEqual(
                measured, expectedDecibels, accuracy: 0.05,
                "Gain \(gain) moved the level by \(measured) dB, expected \(expectedDecibels) dB."
            )
        }
    }

    /// The decibel convenience and the linear gain agree.
    func testDecibelsAndLinearGainAgree() throws {
        let timeline = try fixtureTimeline()
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)

        let mixer = try XCTUnwrap(engine.mixer(forLineAt: 0))
        mixer.decibels = -6
        XCTAssertEqual(mixer.gain, 0.5011, accuracy: 0.001)
        mixer.gain = 1
        XCTAssertEqual(mixer.decibels, 0, accuracy: 0.001)
    }

    // MARK: Pan

    /// Panning moves energy between the channels, and the equal-power law keeps
    /// the total roughly constant while it does.
    func testPanMovesEnergyBetweenTheChannels() throws {
        let timeline = try fixtureTimeline()

        func renderUpper(pan: Float) throws -> PlaybackEngine.RenderedAudio {
            try render(timeline) { engine in
                engine.mixer(forLineAt: 1)?.isMuted = true
                engine.mixer(forLineAt: 0)?.pan = pan
            }
        }

        let centre = try renderUpper(pan: 0)
        XCTAssertEqual(
            centre.rmsLeft(), centre.rmsRight(), accuracy: centre.rmsLeft() * 0.001,
            "A centred line is not equal in both channels."
        )

        let left = try renderUpper(pan: -1)
        XCTAssertGreaterThan(left.rmsLeft(), 1e-4)
        XCTAssertLessThan(
            left.rmsRight(), left.rmsLeft() / 1000,
            "Hard left still put \(left.rmsRight()) into the right channel."
        )

        let right = try renderUpper(pan: 1)
        XCTAssertGreaterThan(right.rmsRight(), 1e-4)
        XCTAssertLessThan(
            right.rmsLeft(), right.rmsRight() / 1000,
            "Hard right still put \(right.rmsLeft()) into the left channel."
        )

        // Equal power: hard left into one channel carries the same energy the
        // centre position spreads across two.
        let centrePower = centre.rmsLeft() * centre.rmsLeft() + centre.rmsRight() * centre.rmsRight()
        let leftPower = left.rmsLeft() * left.rmsLeft() + left.rmsRight() * left.rmsRight()
        XCTAssertEqual(
            leftPower, centrePower, accuracy: centrePower * 0.02,
            "Panning changed the total power, so the law is not equal-power."
        )
    }

    /// Halfway pan sits between centre and hard left, in the right direction.
    func testPartialPanIsBetweenCentreAndHardLeft() throws {
        let timeline = try fixtureTimeline()

        func balance(pan: Float) throws -> Double {
            let audio = try render(timeline) { engine in
                engine.mixer(forLineAt: 1)?.isMuted = true
                engine.mixer(forLineAt: 0)?.pan = pan
            }
            return audio.rmsLeft() / (audio.rmsLeft() + audio.rmsRight())
        }

        let centre = try balance(pan: 0)
        let halfLeft = try balance(pan: -0.5)
        let hardLeft = try balance(pan: -1)

        XCTAssertEqual(centre, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(halfLeft, centre)
        XCTAssertLessThan(halfLeft, hardLeft)
    }

    // MARK: Linearity

    /// The mix is the sum of its lines.
    ///
    /// Worth asserting on its own: it is the property every claim above leans
    /// on, and it is also what increment 004's mixer UI will assume when it
    /// shows a level per strip.
    func testTheMixIsTheSumOfItsLines() throws {
        let timeline = try fixtureTimeline()

        let both = try render(timeline)
        let upperOnly = try render(timeline) { $0.mixer(forLineAt: 1)?.isMuted = true }
        let lowerOnly = try render(timeline) { $0.mixer(forLineAt: 0)?.isMuted = true }

        XCTAssertEqual(both.frameCount, upperOnly.frameCount)
        XCTAssertEqual(both.frameCount, lowerOnly.frameCount)

        var largestDifference: Float = 0
        for index in 0..<both.frameCount {
            let sum = upperOnly.left[index] + lowerOnly.left[index]
            largestDifference = max(largestDifference, abs(both.left[index] - sum))
        }
        // Tolerance rather than bit equality: `d*(a+b)` and `d*a + d*b` differ
        // in the last bits of a float, and the declick ramp multiplies the
        // summed mix. Anything above this would be a real mixing error.
        XCTAssertLessThan(
            largestDifference, 1e-6,
            "The two-line mix differs from the sum of the lines by \(largestDifference)."
        )
    }

    /// The mixer is addressable by the compiled score's own line identity, not
    /// only by position — which is what increment 004 needs to persist a
    /// setting against a line.
    func testMixerIsAddressableByScoreLineID() throws {
        let timeline = try fixtureTimeline()
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)

        let id = timeline.lines[1].id
        let byID = try XCTUnwrap(engine.mixer(for: id))
        byID.gain = 0.25

        let byIndex = try XCTUnwrap(engine.mixer(forLineAt: 1))
        XCTAssertEqual(byIndex.gain, 0.25, accuracy: 0.0001)
    }
}
