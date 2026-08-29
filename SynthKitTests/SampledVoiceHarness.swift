import Foundation
@testable import SynthKit
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Drives one sampled instrument through the line-voice vtable directly and
/// hands back the samples.
///
/// The sampler's counterpart to `SynthVoiceHarness`, and deliberately the same
/// shape: a claim like "velocity 100 selects the loud layer" is a claim about
/// the voice, and the lowest layer that can answer it is the voice's own
/// vtable. It calls exactly the function pointers `synth_audio_core_render`
/// calls, in the same order, so what it measures is the shipping render path
/// and not a second one written for the tests.
///
/// The whole-pipeline claims — determinism across two offline renders, the
/// real-time budget on the orchestral reference — go through `PlaybackEngine`
/// in `SampledInstrumentRenderTests` and `RealtimePlaybackTests`.
final class SampledVoiceHarness {
    let sampleRate: Double
    let provider: SampledInstrumentVoiceProvider
    private let instance: LineVoiceInstance
    private var vtable: SynthLineVoice

    /// Not a multiple of anything the player uses internally, so every test
    /// also exercises rendering across a block boundary.
    private let blockFrames = 500

    init(
        _ available: AvailableInstrument,
        sampleRate: Double = 44_100,
        renderSeed: UInt64? = nil,
        customization: InstrumentCustomization = .asRecorded
    ) throws {
        self.sampleRate = sampleRate
        self.provider = try SampledInstrumentVoiceProvider(
            available: available, renderSeed: renderSeed, customization: customization
        )
        self.instance = provider.makeVoice(sampleRate: sampleRate)
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

    func reset() { vtable.reset(vtable.state) }

    /// What the voice recorded about its own load: slots it had to steal, notes
    /// that reached no region, and the most it ever had sounding at once.
    var telemetry: (stolenSlots: Int64, unmappedNotes: Int64, peakSlots: Int32) {
        let state = OpaquePointer(vtable.state)
        return (
            sample_voice_stolen_slots(state),
            sample_voice_unmapped_notes(state),
            sample_voice_peak_slots(state)
        )
    }

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

    /// Play one note and report the level it settled at.
    ///
    /// The fixtures are constant levels chosen not to collide, so this one
    /// number identifies which region actually sounded — which is what makes a
    /// layer, round-robin or articulation assertion a measurement of the audio
    /// rather than of the player's own bookkeeping.
    func level(ofNote note: Int, velocity: Int = 100, after seconds: Double = 0.05) -> Float {
        noteOn(note, velocity: velocity)
        let samples = render(seconds: seconds)
        noteOff(note)
        _ = render(seconds: 0.05)
        return SampledVoiceHarness.meanAbsolute(samples.suffix(200))
    }

    static func meanAbsolute<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var total: Float = 0
        var count = 0
        for sample in samples { total += abs(sample); count += 1 }
        return count == 0 ? 0 : total / Float(count)
    }

    static func peak<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// Dominant frequency, by counting rising zero crossings.
    ///
    /// Enough for a pitch claim about a clean sine, and far less machinery than
    /// a spectrum for a measurement whose answer is one number.
    static func frequency(of samples: [Float], sampleRate: Double) -> Double {
        var crossings = 0
        var firstCrossing: Int?
        var lastCrossing: Int?
        for index in 1..<samples.count where samples[index - 1] <= 0 && samples[index] > 0 {
            crossings += 1
            if firstCrossing == nil { firstCrossing = index }
            lastCrossing = index
        }
        guard crossings > 1, let first = firstCrossing, let last = lastCrossing, last > first else {
            return 0
        }
        return Double(crossings - 1) * sampleRate / Double(last - first)
    }
}
