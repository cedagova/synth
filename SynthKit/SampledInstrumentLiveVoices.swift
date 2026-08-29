import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

extension InstrumentCustomization {
    /// This customization in the units the render core multiplies by.
    ///
    /// Decibels become linear gains and cents become a playback-rate ratio
    /// here, on the control thread, so the audio thread never converts. The one
    /// value that stays in cents is the vibrato depth, because it modulates a
    /// ratio rather than being one.
    var renderCustomization: SampleVoiceCustomization {
        let bounded = clamped()
        var render = sample_voice_customization_neutral()
        render.toneLowGain = Float(pow(10.0, bounded.toneLowDecibels / 20.0))
        render.toneHighGain = Float(pow(10.0, bounded.toneHighDecibels / 20.0))
        render.dynamicsResponse = Float(bounded.dynamicsResponse)
        render.attackSecondsAdded = Float(bounded.attackSeconds)
        render.releaseScale = Float(bounded.releaseScale)
        render.vibratoDepthCents = Float(bounded.vibratoDepthCents)
        render.vibratoRateHz = Float(bounded.vibratoRateHz)
        render.tuningRatio = Float(pow(2.0, bounded.tuningOffsetCents / 1200.0))
        return render
    }
}

/// The control thread's end of live instrument editing: one customization, and
/// every sampled voice currently rendering with it.
///
/// **The sampler's `SynthPatchLiveVoices`, and deliberately the same shape.**
/// SYN001 hit this first: choosing a sound means building a voice, building a
/// voice means rebuilding the render program, and rebuilding the program stops
/// the music — which is right for choosing and wrong for *editing*. A synth
/// patch got `synth_patch_voice_publish`; a sampled instrument gets
/// `sample_voice_set_customization`, and this is the object that owns it.
///
/// **Threading.** Every method here is control-thread work and every one takes
/// the same lock. The render thread never touches that lock: what crosses to
/// the audio side is a handful of relaxed atomic stores inside
/// `sample_voice_set_customization`. The lock exists for a different race — a
/// voice being released (a `RenderProgram` deinit, which can land on any
/// thread) while an edit is being pushed into it — and serialising
/// registration, release and publication against each other is what stops a
/// publish reaching freed storage.
public final class SampledInstrumentLiveVoices: @unchecked Sendable {
    /// What happened to one `apply`.
    public struct Result: Equatable, Sendable {
        /// Voices the customization was pushed into.
        public let reached: Int

        public var reachedAnyVoice: Bool { reached > 0 }
    }

    private let lock = NSLock()
    private var customization: InstrumentCustomization
    /// Voice state address → the rate that voice was prepared at.
    private var voices: [UInt: Double] = [:]

    public init(customization: InstrumentCustomization = .asRecorded) {
        self.customization = customization
    }

    /// The customization every voice on this channel is currently rendering.
    ///
    /// Read when a voice is *built*, not only when one is updated, so a graph
    /// rebuilt for a device change comes back playing the edited instrument
    /// rather than the one the provider was constructed with.
    public var currentCustomization: InstrumentCustomization {
        lock.lock()
        defer { lock.unlock() }
        return customization
    }

    /// How many voices this channel is currently driving.
    public var voiceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return voices.count
    }

    /// Make `customization` the sound, and push it into every voice already
    /// rendering.
    ///
    /// Returns without waiting. Each voice takes the new values up at its next
    /// render block — within one buffer — and keeps its notes, positions and
    /// envelopes while it does, which is the whole point: the change is heard
    /// on the notes that are already sounding.
    @discardableResult
    public func apply(_ customization: InstrumentCustomization) -> Result {
        lock.lock()
        defer { lock.unlock() }

        self.customization = customization
        return publishLocked(customization)
    }

    /// The smallest number of customizations any one voice has taken up.
    ///
    /// The *smallest*, so this answers "has the edit reached every voice that
    /// is playing" rather than "did some voice somewhere notice". Zero when
    /// there are no voices at all.
    public var adoptionsTakenUp: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !voices.isEmpty else { return 0 }
        return voices.keys.reduce(Int64.max) { lowest, address in
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return lowest }
            return min(lowest, sample_voice_customization_adoptions(OpaquePointer(pointer)))
        }
    }

    // MARK: Voice registration

    /// A voice built from this channel. Called by
    /// `SampledInstrumentVoiceProvider.makeVoice`.
    func register(state: UnsafeMutableRawPointer, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        voices[UInt(bitPattern: state)] = sampleRate
    }

    /// The voice's storage is about to be freed.
    func unregister(state: UnsafeMutableRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        voices.removeValue(forKey: UInt(bitPattern: state))
    }

    // MARK: Internals

    private func publishLocked(_ customization: InstrumentCustomization) -> Result {
        var render = customization.renderCustomization
        var reached = 0
        for address in voices.keys {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { continue }
            sample_voice_set_customization(OpaquePointer(pointer), &render)
            reached += 1
        }
        return Result(reached: reached)
    }
}
