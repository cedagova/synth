import Foundation

/// Reading and writing one parameter of a patch by identity.
///
/// The editor never touches a `SynthPatch` field directly. It asks for a value
/// and sets a value, both by `SynthParameterID`, and every write goes through
/// the one clamp below. That is what makes "invalid parameter entry clamps to
/// valid ranges" a property of the sound rather than of whichever control
/// happened to be used, and it is what lets a test walk every parameter and
/// prove the round trip without knowing what any of them mean.
extension SynthPatch {
    /// This patch's current value for `id`.
    ///
    /// Returns nil only for an index outside the fixed architecture, which is a
    /// caller error rather than a state a patch can be in.
    public func value(for id: SynthParameterID) -> SynthParameterValue? {
        switch id {
        case .oscillatorType(let index):
            return oscillator(index).map { .option($0.type.rawValue) }
        case .oscillatorAnalogShape(let index):
            return oscillator(index).map { .option($0.analogShape.rawValue) }
        case .oscillatorWavetableBank(let index):
            return oscillator(index).map { .option($0.wavetableBank.rawValue) }
        case .oscillatorLevel(let index):
            return oscillator(index).map { .number($0.level) }
        case .oscillatorDetuneSemitones(let index):
            return oscillator(index).map { .number($0.detuneSemitones) }
        case .oscillatorDetuneCents(let index):
            return oscillator(index).map { .number($0.detuneCents) }
        case .oscillatorShapeAmount(let index):
            return oscillator(index).map { .number($0.shapeAmount) }
        case .oscillatorFrequencyModulationRatio(let index):
            return oscillator(index).map { .number($0.frequencyModulationRatio) }
        case .oscillatorRetriggersPhase(let index):
            return oscillator(index).map { .flag($0.retriggersPhase) }
        case .oscillatorStartPhase(let index):
            return oscillator(index).map { .number($0.startPhase) }

        case .noiseLevel: return .number(noiseLevel)

        case .filterEnabled: return .flag(filter.isEnabled)
        case .filterType: return .option(filter.type.rawValue)
        case .filterPoles: return .integer(filter.poles)
        case .filterCutoff: return .number(filter.cutoffHertz)
        case .filterResonance: return .number(filter.resonance)
        case .filterKeyTracking: return .number(filter.keyTracking)

        case .envelopeAttack(let slot): return .number(envelope(slot).attackSeconds)
        case .envelopeDecay(let slot): return .number(envelope(slot).decaySeconds)
        case .envelopeSustain(let slot): return .number(envelope(slot).sustainLevel)
        case .envelopeRelease(let slot): return .number(envelope(slot).releaseSeconds)
        case .envelopeCurve(let slot): return .number(envelope(slot).curve)

        case .lfoShape(let index): return lfo(index).map { .option($0.shape.rawValue) }
        case .lfoRate(let index): return lfo(index).map { .number($0.rateHertz) }
        case .lfoStartPhase(let index): return lfo(index).map { .number($0.startPhase) }
        case .lfoRetriggersPerNote(let index): return lfo(index).map { .flag($0.retriggersPerNote) }

        case .modulationSource(let index): return route(index).map { .option($0.source.rawValue) }
        case .modulationDestination(let index): return route(index).map { .option($0.destination.rawValue) }
        case .modulationAmount(let index): return route(index).map { .number($0.amount) }

        case .equalizerEnabled: return .flag(equalizer.isEnabled)
        case .equalizerLowGain: return .number(equalizer.lowGainDecibels)
        case .equalizerLowHertz: return .number(equalizer.lowHertz)
        case .equalizerMidGain: return .number(equalizer.midGainDecibels)
        case .equalizerMidHertz: return .number(equalizer.midHertz)
        case .equalizerMidQ: return .number(equalizer.midQ)
        case .equalizerHighGain: return .number(equalizer.highGainDecibels)
        case .equalizerHighHertz: return .number(equalizer.highHertz)

        case .chorusEnabled: return .flag(chorus.isEnabled)
        case .chorusRate: return .number(chorus.rateHertz)
        case .chorusDepth: return .number(chorus.depthMilliseconds)
        case .chorusCentre: return .number(chorus.centreMilliseconds)
        case .chorusMix: return .number(chorus.mix)
        case .chorusFeedback: return .number(chorus.feedback)

        case .delayEnabled: return .flag(delay.isEnabled)
        case .delayTime: return .number(delay.timeSeconds)
        case .delayFeedback: return .number(delay.feedback)
        case .delayMix: return .number(delay.mix)
        case .delayDampening: return .number(delay.dampening)

        case .reverbEnabled: return .flag(reverb.isEnabled)
        case .reverbRoomSize: return .number(reverb.roomSize)
        case .reverbDampening: return .number(reverb.dampening)
        case .reverbMix: return .number(reverb.mix)
        case .reverbPreDelay: return .number(reverb.preDelaySeconds)

        case .maximumVoices: return .integer(maximumVoices)
        case .outputLevel: return .number(outputLevel)
        case .velocitySensitivity: return .number(velocitySensitivity)
        case .seed: return .integer(Int(min(seed, UInt64(SynthParameter.seedCeiling))))
        }
    }

    /// This patch with `id` set to `value`, clamped into its declared range.
    ///
    /// A value of the wrong shape for the parameter — a flag handed to a
    /// frequency — is ignored and the patch comes back unchanged, rather than
    /// being coerced into something the owner did not ask for.
    public func setting(_ id: SynthParameterID, to value: SynthParameterValue) -> SynthPatch {
        guard let parameter = SynthParameter.parameter(id) else { return self }
        var patch = self

        switch (id, value) {
        // MARK: Oscillators
        case (.oscillatorType(let index), .option(let raw)):
            guard let choice = OscillatorType(rawValue: raw) else { return self }
            patch.updateOscillator(index) { $0.type = choice }
        case (.oscillatorAnalogShape(let index), .option(let raw)):
            guard let choice = AnalogShape(rawValue: raw) else { return self }
            patch.updateOscillator(index) { $0.analogShape = choice }
        case (.oscillatorWavetableBank(let index), .option(let raw)):
            guard let choice = WavetableBank(rawValue: raw) else { return self }
            patch.updateOscillator(index) { $0.wavetableBank = choice }
        case (.oscillatorLevel(let index), .number(let number)):
            patch.updateOscillator(index) { $0.level = parameter.clamp(number) }
        case (.oscillatorDetuneSemitones(let index), .number(let number)):
            patch.updateOscillator(index) { $0.detuneSemitones = parameter.clamp(number) }
        case (.oscillatorDetuneCents(let index), .number(let number)):
            patch.updateOscillator(index) { $0.detuneCents = parameter.clamp(number) }
        case (.oscillatorShapeAmount(let index), .number(let number)):
            patch.updateOscillator(index) { $0.shapeAmount = parameter.clamp(number) }
        case (.oscillatorFrequencyModulationRatio(let index), .number(let number)):
            patch.updateOscillator(index) { $0.frequencyModulationRatio = parameter.clamp(number) }
        case (.oscillatorRetriggersPhase(let index), .flag(let flag)):
            patch.updateOscillator(index) { $0.retriggersPhase = flag }
        case (.oscillatorStartPhase(let index), .number(let number)):
            patch.updateOscillator(index) { $0.startPhase = parameter.clamp(number) }

        case (.noiseLevel, .number(let number)):
            patch.noiseLevel = parameter.clamp(number)

        // MARK: Filter
        case (.filterEnabled, .flag(let flag)):
            patch.filter.isEnabled = flag
        case (.filterType, .option(let raw)):
            guard let choice = FilterType(rawValue: raw) else { return self }
            patch.filter.type = choice
        case (.filterPoles, .integer(let number)):
            // Two or four; the C side folds anything else to one of them, and
            // a stepper that offered three would be lying about the choice.
            patch.filter.poles = number >= 4 ? 4 : 2
        case (.filterCutoff, .number(let number)):
            patch.filter.cutoffHertz = parameter.clamp(number)
        case (.filterResonance, .number(let number)):
            patch.filter.resonance = parameter.clamp(number)
        case (.filterKeyTracking, .number(let number)):
            patch.filter.keyTracking = parameter.clamp(number)

        // MARK: Envelopes
        case (.envelopeAttack(let slot), .number(let number)):
            patch.updateEnvelope(slot) { $0.attackSeconds = parameter.clamp(number) }
        case (.envelopeDecay(let slot), .number(let number)):
            patch.updateEnvelope(slot) { $0.decaySeconds = parameter.clamp(number) }
        case (.envelopeSustain(let slot), .number(let number)):
            patch.updateEnvelope(slot) { $0.sustainLevel = parameter.clamp(number) }
        case (.envelopeRelease(let slot), .number(let number)):
            patch.updateEnvelope(slot) { $0.releaseSeconds = parameter.clamp(number) }
        case (.envelopeCurve(let slot), .number(let number)):
            patch.updateEnvelope(slot) { $0.curve = parameter.clamp(number) }

        // MARK: LFOs
        case (.lfoShape(let index), .option(let raw)):
            guard let choice = LFOShape(rawValue: raw) else { return self }
            patch.updateLFO(index) { $0.shape = choice }
        case (.lfoRate(let index), .number(let number)):
            patch.updateLFO(index) { $0.rateHertz = parameter.clamp(number) }
        case (.lfoStartPhase(let index), .number(let number)):
            patch.updateLFO(index) { $0.startPhase = parameter.clamp(number) }
        case (.lfoRetriggersPerNote(let index), .flag(let flag)):
            patch.updateLFO(index) { $0.retriggersPerNote = flag }

        // MARK: Modulation matrix
        case (.modulationSource(let index), .option(let raw)):
            guard let choice = ModulationSource(rawValue: raw) else { return self }
            patch.updateRoute(index) { $0.source = choice }
        case (.modulationDestination(let index), .option(let raw)):
            guard let choice = ModulationDestination(rawValue: raw) else { return self }
            patch.updateRoute(index) { $0.destination = choice }
        case (.modulationAmount(let index), .number(let number)):
            patch.updateRoute(index) { $0.amount = parameter.clamp(number) }

        // MARK: Effects
        case (.equalizerEnabled, .flag(let flag)): patch.equalizer.isEnabled = flag
        case (.equalizerLowGain, .number(let n)): patch.equalizer.lowGainDecibels = parameter.clamp(n)
        case (.equalizerLowHertz, .number(let n)): patch.equalizer.lowHertz = parameter.clamp(n)
        case (.equalizerMidGain, .number(let n)): patch.equalizer.midGainDecibels = parameter.clamp(n)
        case (.equalizerMidHertz, .number(let n)): patch.equalizer.midHertz = parameter.clamp(n)
        case (.equalizerMidQ, .number(let n)): patch.equalizer.midQ = parameter.clamp(n)
        case (.equalizerHighGain, .number(let n)): patch.equalizer.highGainDecibels = parameter.clamp(n)
        case (.equalizerHighHertz, .number(let n)): patch.equalizer.highHertz = parameter.clamp(n)

        case (.chorusEnabled, .flag(let flag)): patch.chorus.isEnabled = flag
        case (.chorusRate, .number(let n)): patch.chorus.rateHertz = parameter.clamp(n)
        case (.chorusDepth, .number(let n)): patch.chorus.depthMilliseconds = parameter.clamp(n)
        case (.chorusCentre, .number(let n)): patch.chorus.centreMilliseconds = parameter.clamp(n)
        case (.chorusMix, .number(let n)): patch.chorus.mix = parameter.clamp(n)
        case (.chorusFeedback, .number(let n)): patch.chorus.feedback = parameter.clamp(n)

        case (.delayEnabled, .flag(let flag)): patch.delay.isEnabled = flag
        case (.delayTime, .number(let n)): patch.delay.timeSeconds = parameter.clamp(n)
        case (.delayFeedback, .number(let n)): patch.delay.feedback = parameter.clamp(n)
        case (.delayMix, .number(let n)): patch.delay.mix = parameter.clamp(n)
        case (.delayDampening, .number(let n)): patch.delay.dampening = parameter.clamp(n)

        case (.reverbEnabled, .flag(let flag)): patch.reverb.isEnabled = flag
        case (.reverbRoomSize, .number(let n)): patch.reverb.roomSize = parameter.clamp(n)
        case (.reverbDampening, .number(let n)): patch.reverb.dampening = parameter.clamp(n)
        case (.reverbMix, .number(let n)): patch.reverb.mix = parameter.clamp(n)
        case (.reverbPreDelay, .number(let n)): patch.reverb.preDelaySeconds = parameter.clamp(n)

        // MARK: Whole voice
        case (.maximumVoices, .integer(let number)):
            patch.maximumVoices = min(max(number, 1), SynthPatch.maximumPolyphony)
        case (.outputLevel, .number(let n)): patch.outputLevel = parameter.clamp(n)
        case (.velocitySensitivity, .number(let n)): patch.velocitySensitivity = parameter.clamp(n)
        case (.seed, .integer(let number)):
            patch.seed = UInt64(min(max(number, 0), SynthParameter.seedCeiling))

        default:
            // Wrong shape for this parameter. Nothing changes.
            return self
        }

        return patch
    }

    // MARK: Element access

    private func oscillator(_ index: Int) -> Oscillator? {
        oscillators.indices.contains(index) ? oscillators[index] : nil
    }

    private func lfo(_ index: Int) -> LFO? {
        lfos.indices.contains(index) ? lfos[index] : nil
    }

    private func route(_ index: Int) -> ModulationRoute? {
        modulation.indices.contains(index) ? modulation[index] : nil
    }

    private func envelope(_ slot: EnvelopeSlot) -> Envelope {
        switch slot {
        case .amplitude: return amplitudeEnvelope
        case .modulation: return modulationEnvelope
        }
    }

    private mutating func updateOscillator(_ index: Int, _ change: (inout Oscillator) -> Void) {
        guard oscillators.indices.contains(index) else { return }
        change(&oscillators[index])
    }

    private mutating func updateLFO(_ index: Int, _ change: (inout LFO) -> Void) {
        guard lfos.indices.contains(index) else { return }
        change(&lfos[index])
    }

    private mutating func updateRoute(_ index: Int, _ change: (inout ModulationRoute) -> Void) {
        guard modulation.indices.contains(index) else { return }
        change(&modulation[index])
    }

    private mutating func updateEnvelope(_ slot: EnvelopeSlot, _ change: (inout Envelope) -> Void) {
        switch slot {
        case .amplitude: change(&amplitudeEnvelope)
        case .modulation: change(&modulationEnvelope)
        }
    }
}

// MARK: - A sound to start from

extension SynthPatch {
    /// What "create a sound from scratch" hands the owner.
    ///
    /// Deliberately not silence, and deliberately not the shipped default
    /// voice. Silence would make the first press of a key prove nothing, and
    /// starting from a finished sound makes the owner's first job deleting
    /// somebody else's decisions. This is the plainest thing that is
    /// unmistakably a synthesizer: one saw through an open low-pass filter with
    /// a short envelope. Every knob has somewhere to go from here.
    public static func newSound(identifier: String = "user.new", name: String = "New Sound") -> SynthPatch {
        SynthPatch(
            identifier: identifier,
            name: name,
            oscillators: [
                Oscillator(type: .analog, analogShape: .saw, level: 0.8),
                Oscillator(type: .analog, analogShape: .saw, level: 0.0, detuneCents: 7),
                Oscillator(type: .analog, analogShape: .sine, level: 0.0, detuneSemitones: -12)
            ],
            filter: Filter(isEnabled: true, type: .lowpass, poles: 2,
                           cutoffHertz: 3_000, resonance: 0.15, keyTracking: 0.3),
            amplitudeEnvelope: Envelope(attackSeconds: 0.01, decaySeconds: 0.25,
                                        sustainLevel: 0.7, releaseSeconds: 0.35, curve: 0.5),
            outputLevel: 0.18
        )
    }
}

// MARK: - Names for the closed sets

extension SynthPatch.OscillatorType {
    public var displayName: String {
        switch self {
        case .analog: return "Analogue"
        case .wavetable: return "Wavetable"
        case .frequencyModulation: return "FM"
        }
    }
}

extension SynthPatch.AnalogShape {
    public var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .saw: return "Saw"
        case .square: return "Square"
        case .pulse: return "Pulse"
        }
    }
}

extension SynthPatch.WavetableBank {
    public var displayName: String {
        switch self {
        case .harmonic: return "Harmonic"
        case .formant: return "Formant"
        case .metallic: return "Metallic"
        case .hollow: return "Hollow"
        }
    }
}

extension SynthPatch.FilterType {
    public var displayName: String {
        switch self {
        case .lowpass: return "Low-pass"
        case .highpass: return "High-pass"
        case .bandpass: return "Band-pass"
        case .notch: return "Notch"
        }
    }
}

extension SynthPatch.LFOShape {
    public var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .saw: return "Saw"
        case .square: return "Square"
        case .sampleAndHold: return "Sample & Hold"
        }
    }
}

extension SynthPatch.ModulationSource {
    public var displayName: String {
        switch self {
        case .none: return "—"
        case .amplitudeEnvelope: return "Amplitude Envelope"
        case .modulationEnvelope: return "Modulation Envelope"
        case .lfo1: return "LFO 1"
        case .lfo2: return "LFO 2"
        case .velocity: return "Velocity"
        case .keyTrack: return "Key Track"
        case .noteRandom: return "Note Random"
        }
    }
}

extension SynthPatch.ModulationDestination {
    public var displayName: String {
        switch self {
        case .none: return "—"
        case .oscillator1Pitch: return "Osc 1 Pitch"
        case .oscillator2Pitch: return "Osc 2 Pitch"
        case .oscillator3Pitch: return "Osc 3 Pitch"
        case .oscillator1Level: return "Osc 1 Level"
        case .oscillator2Level: return "Osc 2 Level"
        case .oscillator3Level: return "Osc 3 Level"
        case .oscillator1Shape: return "Osc 1 Shape"
        case .oscillator2Shape: return "Osc 2 Shape"
        case .oscillator3Shape: return "Osc 3 Shape"
        case .filterCutoff: return "Filter Cutoff"
        case .filterResonance: return "Filter Resonance"
        case .amplitude: return "Amplitude"
        }
    }
}
