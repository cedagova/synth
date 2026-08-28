import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Renders one line with one `SynthPatch`.
///
/// This is the synthesizer's implementation of PLY003's line-voice interface,
/// and the AD7 replacement for increment 002's fixed built-in voice: the
/// engine, the transport, the mixer and the offline render path are all
/// unchanged, and the only difference is which vtable a line gets.
///
/// The patch crosses the boundary as a flat C struct copied into the voice's
/// own storage at construction. Nothing the render thread reads points back at
/// Swift, so there is no object for it to retain and no way for an edit on the
/// control thread to be half-visible to a render in progress.
///
/// **Choosing a sound builds a new voice; editing one does not.** Increment 003
/// added the second case. A provider built with `init(live:)` takes its patch
/// from a `SynthPatchLiveVoices` channel and registers every voice it makes
/// with that channel, so an edit reaches the voices that are already rendering
/// instead of requiring a program rebuild — which is what REQ-018's "audible
/// while playback continues" actually costs. A provider built with
/// `init(patch:)` is the fixed sound it always was.
public struct SynthPatchVoiceProvider: LineVoiceProvider {
    /// The sound, for a provider that has one of its own.
    public let patch: SynthPatch

    /// The channel this provider follows, when it follows one.
    ///
    /// Its patch wins over `patch`, and it wins at every `makeVoice` rather
    /// than only at the first — so a graph rebuilt for a device change comes
    /// back playing what the owner has edited, not what the provider was
    /// constructed with.
    public let live: SynthPatchLiveVoices?

    public init(patch: SynthPatch = .defaultVoice) {
        self.patch = patch
        self.live = nil
    }

    /// A provider that renders whatever `live` currently holds.
    public init(live: SynthPatchLiveVoices) {
        self.patch = live.currentPatch
        self.live = live
    }

    /// The sound this provider would build a voice for right now.
    public var currentPatch: SynthPatch { live?.currentPatch ?? patch }

    public var identifier: String { currentPatch.identifier }
    public var displayName: String { currentPatch.name }

    /// How long this patch can still be heard after its last note ends.
    ///
    /// The amplitude envelope's release, plus however long the effect chain
    /// keeps ringing after that. The delay's figure is the time it takes its
    /// feedback to fall 60 dB; the reverb's is the same calculation over its
    /// comb loop. Both are estimates of an exponential decay, deliberately
    /// generous, because too long only makes an export slightly longer while
    /// too short truncates the sound.
    public var releaseTailSeconds: Double {
        let patch = currentPatch
        var tail = patch.amplitudeEnvelope.releaseSeconds

        if patch.delay.isEnabled, patch.delay.mix > 0, patch.delay.feedback > 0 {
            // Repeats until 60 dB down: log(0.001) / log(feedback) of them.
            let repeats = log(0.001) / log(min(patch.delay.feedback, 0.99))
            tail += patch.delay.timeSeconds * repeats
        } else if patch.delay.isEnabled, patch.delay.mix > 0 {
            tail += patch.delay.timeSeconds
        }

        if patch.reverb.isEnabled, patch.reverb.mix > 0 {
            // The longest Freeverb comb is 1617 frames at 44.1 kHz — about
            // 37 ms round trip — decaying by `roomSize`'s feedback each pass.
            let feedback = min(0.70 + 0.28 * patch.reverb.roomSize, 0.99)
            let passes = log(0.001) / log(feedback)
            tail += patch.reverb.preDelaySeconds + 0.0367 * passes
        }

        return min(tail, RenderProgram.maximumReleaseTailSeconds)
    }

    public func makeVoice(sampleRate: Double) -> LineVoiceInstance {
        // Sized and aligned by the C core so the layout stays private to it.
        let byteCount = synth_patch_voice_state_size()
        let alignment = synth_patch_voice_state_alignment()
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        var config = currentPatch.renderConfiguration
        var vtable = SynthLineVoice()
        // `SynthPatchVoiceState` is incomplete in the public header on purpose,
        // so it crosses into Swift as an opaque pointer.
        synth_patch_voice_init(OpaquePointer(raw), &vtable, sampleRate, &config)

        // Registered before the voice is handed out and unregistered before its
        // storage is freed, both under the channel's lock, so a live edit can
        // never reach a voice that has gone.
        live?.register(state: raw, sampleRate: sampleRate)

        // The pointer reaches the teardown closure as an integer because a raw
        // pointer is not `Sendable`. Ownership is unambiguous: this voice is
        // the only thing that holds it, and `release` runs exactly once, after
        // the engine using it has been destroyed.
        let address = UInt(bitPattern: raw)
        let channel = live
        return LineVoiceInstance(vtable: vtable, release: {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            channel?.unregister(state: pointer)
            pointer.deallocate()
        })
    }
}

extension SynthPatch {
    /// This patch as the flat struct the render core takes.
    ///
    /// Built on top of `synth_patch_config_default`, so every field has a
    /// defined value even if this function ever forgets one. The C side clamps
    /// the result again at `synth_patch_voice_init`; that clamp — not this
    /// conversion — is what the audio thread relies on.
    var renderConfiguration: SynthPatchConfig {
        var config = SynthPatchConfig()
        synth_patch_config_default(&config)

        for (index, oscillator) in oscillators.prefix(Self.oscillatorCount).enumerated() {
            var element = SynthOscillatorConfig()
            element.type = oscillator.type.renderValue
            element.shape = oscillator.type == .wavetable
                ? oscillator.wavetableBank.renderValue
                : oscillator.analogShape.renderValue
            element.level = Float(oscillator.level)
            element.detuneSemitones = Float(oscillator.detuneSemitones)
            element.detuneCents = Float(oscillator.detuneCents)
            element.shapeAmount = Float(oscillator.shapeAmount)
            element.fmRatio = Float(oscillator.frequencyModulationRatio)
            element.retriggersPhase = oscillator.retriggersPhase ? 1 : 0
            element.startPhase = Float(oscillator.startPhase)
            synth_patch_config_set_oscillator(&config, Int32(index), &element)
        }

        config.noiseLevel = Float(noiseLevel)

        config.filter.isEnabled = filter.isEnabled ? 1 : 0
        config.filter.type = filter.type.renderValue
        config.filter.poles = Int32(filter.poles)
        config.filter.cutoffHertz = Float(filter.cutoffHertz)
        config.filter.resonance = Float(filter.resonance)
        config.filter.keyTracking = Float(filter.keyTracking)

        config.amplitudeEnvelope = amplitudeEnvelope.renderConfiguration
        config.modulationEnvelope = modulationEnvelope.renderConfiguration

        for (index, lfo) in lfos.prefix(Self.lfoCount).enumerated() {
            var element = SynthLFOConfig()
            element.shape = lfo.shape.renderValue
            element.rateHertz = Float(lfo.rateHertz)
            element.startPhase = Float(lfo.startPhase)
            element.retriggersPerNote = lfo.retriggersPerNote ? 1 : 0
            synth_patch_config_set_lfo(&config, Int32(index), &element)
        }

        for (index, route) in modulation.prefix(Self.modulationSlotCount).enumerated() {
            var element = SynthModulationSlotConfig()
            element.source = route.source.renderValue
            element.destination = route.destination.renderValue
            element.amount = Float(route.amount)
            synth_patch_config_set_modulation(&config, Int32(index), &element)
        }

        config.equalizer.isEnabled = equalizer.isEnabled ? 1 : 0
        config.equalizer.lowGainDecibels = Float(equalizer.lowGainDecibels)
        config.equalizer.lowHertz = Float(equalizer.lowHertz)
        config.equalizer.midGainDecibels = Float(equalizer.midGainDecibels)
        config.equalizer.midHertz = Float(equalizer.midHertz)
        config.equalizer.midQ = Float(equalizer.midQ)
        config.equalizer.highGainDecibels = Float(equalizer.highGainDecibels)
        config.equalizer.highHertz = Float(equalizer.highHertz)

        config.chorus.isEnabled = chorus.isEnabled ? 1 : 0
        config.chorus.rateHertz = Float(chorus.rateHertz)
        config.chorus.depthMilliseconds = Float(chorus.depthMilliseconds)
        config.chorus.centreMilliseconds = Float(chorus.centreMilliseconds)
        config.chorus.mix = Float(chorus.mix)
        config.chorus.feedback = Float(chorus.feedback)

        config.delay.isEnabled = delay.isEnabled ? 1 : 0
        config.delay.timeSeconds = Float(delay.timeSeconds)
        config.delay.feedback = Float(delay.feedback)
        config.delay.mix = Float(delay.mix)
        config.delay.dampening = Float(delay.dampening)

        config.reverb.isEnabled = reverb.isEnabled ? 1 : 0
        config.reverb.roomSize = Float(reverb.roomSize)
        config.reverb.dampening = Float(reverb.dampening)
        config.reverb.mix = Float(reverb.mix)
        config.reverb.preDelaySeconds = Float(reverb.preDelaySeconds)

        config.maximumVoices = Int32(maximumVoices)
        config.outputLevel = Float(outputLevel)
        config.velocitySensitivity = Float(velocitySensitivity)
        config.seed = seed

        return config
    }
}

// MARK: - Enumerated parameters, in the render core's numbering
//
// Written out rather than derived from `allCases.firstIndex(of:)`: the C
// constants are a wire format that a stored patch and a running engine both
// depend on, and a mapping that silently followed a reordered Swift enum would
// change what every saved patch means.

extension SynthPatch.OscillatorType {
    var renderValue: Int32 {
        switch self {
        case .analog: return Int32(SynthOscillatorTypeAnalog)
        case .wavetable: return Int32(SynthOscillatorTypeWavetable)
        case .frequencyModulation: return Int32(SynthOscillatorTypeFM)
        }
    }
}

extension SynthPatch.AnalogShape {
    var renderValue: Int32 {
        switch self {
        case .sine: return Int32(SynthAnalogShapeSine)
        case .triangle: return Int32(SynthAnalogShapeTriangle)
        case .saw: return Int32(SynthAnalogShapeSaw)
        case .square: return Int32(SynthAnalogShapeSquare)
        case .pulse: return Int32(SynthAnalogShapePulse)
        }
    }
}

extension SynthPatch.WavetableBank {
    var renderValue: Int32 {
        switch self {
        case .harmonic: return Int32(SynthWavetableBankHarmonic)
        case .formant: return Int32(SynthWavetableBankFormant)
        case .metallic: return Int32(SynthWavetableBankMetallic)
        case .hollow: return Int32(SynthWavetableBankHollow)
        }
    }
}

extension SynthPatch.FilterType {
    var renderValue: Int32 {
        switch self {
        case .lowpass: return Int32(SynthFilterTypeLowpass)
        case .highpass: return Int32(SynthFilterTypeHighpass)
        case .bandpass: return Int32(SynthFilterTypeBandpass)
        case .notch: return Int32(SynthFilterTypeNotch)
        }
    }
}

extension SynthPatch.LFOShape {
    var renderValue: Int32 {
        switch self {
        case .sine: return Int32(SynthLFOShapeSine)
        case .triangle: return Int32(SynthLFOShapeTriangle)
        case .saw: return Int32(SynthLFOShapeSaw)
        case .square: return Int32(SynthLFOShapeSquare)
        case .sampleAndHold: return Int32(SynthLFOShapeSampleAndHold)
        }
    }
}

extension SynthPatch.ModulationSource {
    var renderValue: Int32 {
        switch self {
        case .none: return Int32(SynthModSourceNone)
        case .amplitudeEnvelope: return Int32(SynthModSourceAmplitudeEnvelope)
        case .modulationEnvelope: return Int32(SynthModSourceModulationEnvelope)
        case .lfo1: return Int32(SynthModSourceLFO1)
        case .lfo2: return Int32(SynthModSourceLFO2)
        case .velocity: return Int32(SynthModSourceVelocity)
        case .keyTrack: return Int32(SynthModSourceKeyTrack)
        case .noteRandom: return Int32(SynthModSourceNoteRandom)
        }
    }
}

extension SynthPatch.ModulationDestination {
    var renderValue: Int32 {
        switch self {
        case .none: return Int32(SynthModDestinationNone)
        case .oscillator1Pitch: return Int32(SynthModDestinationOscillator1Pitch)
        case .oscillator2Pitch: return Int32(SynthModDestinationOscillator2Pitch)
        case .oscillator3Pitch: return Int32(SynthModDestinationOscillator3Pitch)
        case .oscillator1Level: return Int32(SynthModDestinationOscillator1Level)
        case .oscillator2Level: return Int32(SynthModDestinationOscillator2Level)
        case .oscillator3Level: return Int32(SynthModDestinationOscillator3Level)
        case .oscillator1Shape: return Int32(SynthModDestinationOscillator1Shape)
        case .oscillator2Shape: return Int32(SynthModDestinationOscillator2Shape)
        case .oscillator3Shape: return Int32(SynthModDestinationOscillator3Shape)
        case .filterCutoff: return Int32(SynthModDestinationFilterCutoff)
        case .filterResonance: return Int32(SynthModDestinationFilterResonance)
        case .amplitude: return Int32(SynthModDestinationAmplitude)
        }
    }
}

extension SynthPatch.Envelope {
    var renderConfiguration: SynthEnvelopeConfig {
        var config = SynthEnvelopeConfig()
        config.attackSeconds = Float(attackSeconds)
        config.decaySeconds = Float(decaySeconds)
        config.sustainLevel = Float(sustainLevel)
        config.releaseSeconds = Float(releaseSeconds)
        config.curve = Float(curve)
        return config
    }
}
