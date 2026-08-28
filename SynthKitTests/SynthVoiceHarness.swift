import Foundation
@testable import SynthKit
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Drives one `SynthPatch` through the line-voice vtable directly and hands
/// back the samples.
///
/// **Why not go through `PlaybackEngine` for every DSP claim.** A claim like
/// "the saw has a second harmonic and the square does not" is a claim about
/// the oscillator, and the lowest layer that can answer it is the voice
/// itself. Routing it through MusicXML, the score compiler, the realizer and
/// the mixer would make the same assertion depend on four things that have
/// nothing to do with oscillators, and would leave a failure ambiguous about
/// which of them broke.
///
/// The whole-pipeline claims — determinism, patch round-trip, the real-time
/// budget — do go through `PlaybackEngine`, in `SynthEngineIntegrationTests`.
/// This harness calls exactly the function pointers the engine calls, in the
/// same order, so what it measures is the shipping render path.
final class SynthVoiceHarness {
    let sampleRate: Double
    private let instance: LineVoiceInstance
    private var vtable: SynthLineVoice

    /// Block size the harness renders in.
    ///
    /// Deliberately not a multiple of the engine's internal control block, so
    /// every test here also exercises the carry that makes the output
    /// independent of how a buffer is chopped.
    private let blockFrames = 500

    init(patch: SynthPatch, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.instance = SynthPatchVoiceProvider(patch: patch).makeVoice(sampleRate: sampleRate)
        self.vtable = instance.vtable
        vtable.prepare(vtable.state, sampleRate)
        vtable.reset(vtable.state)
    }

    deinit { instance.release() }

    func noteOn(_ midiNoteNumber: Int, velocity: Int = 100) {
        vtable.noteOn(vtable.state, Int32(midiNoteNumber), Int32(velocity))
    }

    func noteOff(_ midiNoteNumber: Int) {
        vtable.noteOff(vtable.state, Int32(midiNoteNumber))
    }

    func setSustainPedal(_ isDown: Bool) {
        vtable.setSustainPedal(vtable.state, isDown ? 1 : 0)
    }

    /// Render `seconds` of audio, in blocks, exactly as the engine would.
    func render(seconds: Double) -> [Float] {
        var output: [Float] = []
        var remaining = Int((seconds * sampleRate).rounded())
        output.reserveCapacity(remaining)

        var block = [Float](repeating: 0, count: blockFrames)
        while remaining > 0 {
            let count = min(blockFrames, remaining)
            block.withUnsafeMutableBufferPointer { buffer in
                vtable.render(vtable.state, buffer.baseAddress!, Int32(count))
            }
            output.append(contentsOf: block[0..<count])
            remaining -= count
        }
        return output
    }

    /// Hold one note for `holdSeconds`, then let it ring for `tailSeconds`.
    ///
    /// The shape almost every measurement here wants: something to analyse
    /// while the note sounds, and something to analyse after it stops.
    static func renderNote(
        patch: SynthPatch,
        midiNoteNumber: Int = 69,
        velocity: Int = 100,
        holdSeconds: Double = 1.0,
        tailSeconds: Double = 0,
        sampleRate: Double = 48_000
    ) -> [Float] {
        let harness = SynthVoiceHarness(patch: patch, sampleRate: sampleRate)
        harness.noteOn(midiNoteNumber, velocity: velocity)
        var samples = harness.render(seconds: holdSeconds)
        if tailSeconds > 0 {
            harness.noteOff(midiNoteNumber)
            samples.append(contentsOf: harness.render(seconds: tailSeconds))
        }
        return samples
    }
}

// MARK: - Patch builders

extension SynthPatch {
    /// A patch with exactly one oscillator sounding, everything else off.
    ///
    /// The baseline every oscillator and filter assertion is made against:
    /// with one source, no filter, no effects and a square amplitude envelope,
    /// what the spectrum shows is what the oscillator produced.
    static func singleOscillator(
        _ oscillator: Oscillator,
        name: String = "Test",
        filter: Filter = Filter(),
        modulation: [ModulationRoute] = Array(repeating: ModulationRoute(), count: modulationSlotCount),
        modulationEnvelope: Envelope = Envelope(
            attackSeconds: 0.010, decaySeconds: 0.400, sustainLevel: 0,
            releaseSeconds: 0.300, curve: 1
        ),
        lfos: [LFO] = [LFO(), LFO(rateHertz: 0.4)],
        noiseLevel: Double = 0,
        equalizer: Equalizer = Equalizer(),
        chorus: Chorus = Chorus(),
        delay: Delay = Delay(),
        reverb: Reverb = Reverb(),
        outputLevel: Double = 0.5,
        velocitySensitivity: Double = 1.6
    ) -> SynthPatch {
        var level = oscillator
        if level.level == 0 { level.level = 1 }
        return SynthPatch(
            identifier: "test.\(name.lowercased())",
            name: name,
            oscillators: [level, Oscillator(), Oscillator()],
            noiseLevel: noiseLevel,
            filter: filter,
            // A near-instant attack into a full sustain, so the amplitude
            // contour contributes nothing to a spectral measurement.
            amplitudeEnvelope: Envelope(
                attackSeconds: 0.002, decaySeconds: 0.010, sustainLevel: 1,
                releaseSeconds: 0.050, curve: 0
            ),
            modulationEnvelope: modulationEnvelope,
            lfos: lfos,
            modulation: modulation,
            equalizer: equalizer,
            chorus: chorus,
            delay: delay,
            reverb: reverb,
            outputLevel: outputLevel,
            velocitySensitivity: velocitySensitivity
        )
    }

    /// Replace one modulation slot, leaving the rest inactive.
    func routing(
        _ source: ModulationSource,
        to destination: ModulationDestination,
        amount: Double,
        slot: Int = 0
    ) -> SynthPatch {
        var patch = self
        patch.modulation[slot] = ModulationRoute(
            source: source, destination: destination, amount: amount
        )
        return patch
    }
}
