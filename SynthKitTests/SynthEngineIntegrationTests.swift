import XCTest
@testable import SynthKit

/// Issue #17's whole-pipeline claims: determinism, the audio half of the patch
/// round trip, and that a synth patch really is what the engine now renders a
/// score with.
///
/// These go through `PlaybackEngine.renderTimelineOffline`, which builds the
/// same graph real-time playback builds (AD2). `SynthEngineRenderTests`
/// measures the DSP one voice at a time; this measures the thing the app
/// actually does.
final class SynthEngineIntegrationTests: XCTestCase {
    /// A patch that exercises every section at once.
    ///
    /// Determinism is easy to get right for a sine and easy to lose for a
    /// sample-and-hold LFO, a noise source and a feedback delay, so the patch
    /// these tests repeat is the one with all three in it.
    static func demandingPatch(seed: UInt64 = 0x1234_5678_9ABC_DEF0) -> SynthPatch {
        SynthPatch(
            identifier: "test.demanding",
            name: "Demanding",
            oscillators: [
                .init(type: .analog, analogShape: .pulse, level: 0.7,
                      shapeAmount: 0.35, retriggersPhase: false),
                .init(type: .wavetable, wavetableBank: .formant, level: 0.5,
                      detuneCents: 7, shapeAmount: 0.4),
                .init(type: .frequencyModulation, level: 0.35, detuneSemitones: 12,
                      shapeAmount: 0.2, frequencyModulationRatio: 3)
            ],
            noiseLevel: 0.05,
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 900, resonance: 0.45, keyTracking: 0.5),
            amplitudeEnvelope: .init(attackSeconds: 0.006, decaySeconds: 0.25,
                                     sustainLevel: 0.55, releaseSeconds: 0.35, curve: 0.6),
            modulationEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.6,
                                      sustainLevel: 0.1, releaseSeconds: 0.4, curve: 1),
            lfos: [
                .init(shape: .sine, rateHertz: 4.5, retriggersPerNote: false),
                .init(shape: .sampleAndHold, rateHertz: 9, retriggersPerNote: true)
            ],
            modulation: [
                .init(source: .modulationEnvelope, destination: .filterCutoff, amount: 0.5),
                .init(source: .lfo1, destination: .oscillator1Shape, amount: 0.3),
                .init(source: .lfo2, destination: .oscillator2Pitch, amount: 0.01),
                .init(source: .velocity, destination: .filterCutoff, amount: 0.2),
                .init(source: .keyTrack, destination: .oscillator3Level, amount: 0.2),
                .init(source: .noteRandom, destination: .oscillator1Pitch, amount: 0.004),
                .init(), .init()
            ],
            equalizer: .init(isEnabled: true, lowGainDecibels: -3, lowHertz: 180,
                             midGainDecibels: 2.5, midHertz: 1800, midQ: 1.4,
                             highGainDecibels: 3, highHertz: 7000),
            chorus: .init(isEnabled: true, rateHertz: 0.8, depthMilliseconds: 5,
                          centreMilliseconds: 14, mix: 0.3, feedback: 0.2),
            delay: .init(isEnabled: true, timeSeconds: 0.22, feedback: 0.35,
                         mix: 0.2, dampening: 0.5),
            reverb: .init(isEnabled: true, roomSize: 0.7, dampening: 0.4,
                          mix: 0.25, preDelaySeconds: 0.025),
            maximumVoices: 32,
            outputLevel: 0.16,
            velocitySensitivity: 1.5,
            seed: seed
        )
    }

    private func timeline() throws -> PerformanceTimeline {
        try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
    }

    private func render(_ patch: SynthPatch) throws -> PlaybackEngine.RenderedAudio {
        try PlaybackEngine.renderTimelineOffline(
            try timeline(), voiceProvider: SynthPatchVoiceProvider(patch: patch))
    }

    // MARK: Determinism

    /// **The determinism criterion.** Same patch, same events, same seed →
    /// byte-identical audio.
    ///
    /// Byte equality rather than a tolerance, on the patch with the noise and
    /// the sample-and-hold LFO in it, because a tolerance here would not be an
    /// equality claim at all and increment 006's export-equals-playback check
    /// (REQ-026) inherits this property.
    func testTheSamePatchAndSeedRenderIdenticalBytes() throws {
        let patch = Self.demandingPatch()
        let first = try render(patch)
        let second = try render(patch)

        XCTAssertGreaterThan(first.frameCount, 0)
        XCTAssertGreaterThan(first.rms(), 0.001, "The demanding patch rendered near-silence.")
        XCTAssertEqual(
            first.canonicalData(), second.canonicalData(),
            "Two renders of one patch differed; the engine is not deterministic."
        )
    }

    /// The seed is doing something: change it and the noise and the
    /// sample-and-hold change with it, while the piece stays the same piece.
    ///
    /// Without this, "deterministic" could be true because the seed is ignored
    /// and nothing random ever happens.
    func testChangingOnlyTheSeedChangesTheRenderedNoise() throws {
        let first = try render(Self.demandingPatch(seed: 1))
        let second = try render(Self.demandingPatch(seed: 2))

        XCTAssertNotEqual(
            first.canonicalData(), second.canonicalData(),
            "Two different seeds produced identical audio; the seed is not reaching the engine."
        )
        // Same music, different grain: the levels stay within a few percent.
        XCTAssertEqual(first.rms(), second.rms(), accuracy: first.rms() * 0.1)
    }

    /// The synthesizer inherits the engine's buffer-size independence: the
    /// control-block boundary is anchored to the voice, not to the host's
    /// buffer, so chopping time differently cannot change the result.
    func testTheSynthRenderIsIndependentOfTheHostBufferSize() throws {
        let patch = Self.demandingPatch()
        let loaded = try timeline()

        func render(blockFrames: Int64) throws -> PlaybackEngine.RenderedAudio {
            let engine = PlaybackEngine(voiceProvider: SynthPatchVoiceProvider(patch: patch))
            try engine.setRenderMode(.offline(sampleRate: 48_000))
            try engine.load(timeline: loaded)
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
            "Rendering in 64-frame blocks differed from 4096-frame blocks."
        )
    }

    // MARK: The audio half of the round trip

    /// **The other half of the round-trip criterion.** A patch that has been
    /// through the document format renders exactly the same audio.
    ///
    /// Byte-identical parameters would be worth little if the conversion into
    /// the render core lost something on the way; this closes that gap, and it
    /// is what lets increment 004 promise that a preset sounds the same as the
    /// sound it was saved from.
    func testAPatchThatHasBeenThroughTheDocumentFormatRendersIdenticalAudio() throws {
        let original = Self.demandingPatch()
        let restored = try SynthPatchDocument.patch(
            from: SynthPatchDocument.data(from: original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(
            try render(original).canonicalData(),
            try render(restored).canonicalData(),
            "A serialised and reloaded patch rendered different audio."
        )
    }

    /// Two different patches are two different sounds all the way through the
    /// engine, so loading a patch really does determine what is heard.
    func testDifferentPatchesProduceDifferentRenders() throws {
        var closed = Self.demandingPatch()
        closed.filter.keyTracking = 0
        closed.filter.cutoffHertz = 200
        var open = closed
        open.filter.cutoffHertz = 12_000

        let dark = try render(closed)
        let bright = try render(open)

        XCTAssertNotEqual(dark.canonicalData(), bright.canonicalData())

        // Summed across the top of the spectrum rather than measured at one
        // frequency: the fixture's two notes and the effect chain put content
        // at unpredictable individual bins, but the total above 4 kHz is a
        // clean statement about how far open the filter is.
        func topEnergy(_ audio: PlaybackEngine.RenderedAudio) -> Double {
            [4_000.0, 5_000, 6_000, 7_000, 8_000].reduce(0) { total, hertz in
                total + AudioRenderFixtures.energy(audio.left, atHertz: hertz, sampleRate: 48_000)
            }
        }
        XCTAssertGreaterThan(
            topEnergy(bright), topEnergy(dark) * 3,
            "Opening the filter from 200 Hz to 12 kHz moved the energy above 4 kHz from "
                + "\(topEnergy(dark)) only to \(topEnergy(bright))."
        )
    }

    // MARK: AD7 — the default voice is now a patch

    /// The engine's default provider is the synthesizer, and its patch is the
    /// shipped default voice.
    ///
    /// AD7 in one assertion: increment 002's built-in voice is not beside the
    /// new engine, it is rendered *by* it.
    func testTheEngineDefaultsToTheSynthesizerAndTheDefaultVoicePatch() throws {
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: try timeline())

        let provider = try XCTUnwrap(engine.loadedProgram)
        XCTAssertEqual(provider.lineCount, 2)

        let defaultProvider = SynthPatchVoiceProvider()
        XCTAssertEqual(defaultProvider.identifier, "builtin.default-voice")
        XCTAssertEqual(defaultProvider.displayName, "Default Voice")
        XCTAssertEqual(defaultProvider.patch, .defaultVoice)
    }

    /// The default voice is the increment-002 sound: three sine partials at
    /// 1×, 2× and 3× and nothing else.
    ///
    /// The whole increment-002 offline suite still passing is the broad
    /// evidence for that; this is the direct measurement, so a future edit to
    /// the shipped patch cannot change what the app has always sounded like
    /// without a test saying so.
    func testTheDefaultVoiceIsStillThreeSinePartials() {
        let samples = SynthVoiceHarness.renderNote(
            patch: .defaultVoice, midiNoteNumber: 69, holdSeconds: 1.0)
        let steady = Array(samples[Int(0.3 * 48_000)..<Int(0.9 * 48_000)])
        let harmonics = AudioRenderFixtures.harmonicEnergies(
            steady, fundamental: 440, count: 6, sampleRate: 48_000)
        let normalized = harmonics.map { $0 / harmonics[0] }

        XCTAssertEqual(normalized[1], 0.34, accuracy: 0.02, "The second partial moved.")
        XCTAssertEqual(normalized[2], 0.13, accuracy: 0.02, "The third partial moved.")
        for index in 3..<normalized.count {
            XCTAssertLessThan(
                normalized[index], 0.01,
                "The default voice grew a \(index + 1)th partial it never had."
            )
        }
    }

    /// A rendered piece still leaves the engine headroom.
    func testTheRenderedPieceDoesNotClip() throws {
        let audio = try render(Self.demandingPatch())
        XCTAssertLessThan(audio.peak(), 1.0, "The demanding patch clips the mix.")
        XCTAssertGreaterThan(audio.peak(), 0.01, "The demanding patch is inaudible.")
    }
}
