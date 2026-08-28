import Foundation

/// One complete sound: every parameter of the REQ-016 synthesis architecture,
/// in the form the library stores and the editor edits.
///
/// **Fixed but rich (D6).** There is no routing graph here and no way to add a
/// stage. Three oscillators, one filter, two envelopes, two LFOs, eight
/// modulation routes and four effects, always in that order and always all
/// present. What varies is what the numbers say and where the matrix sends its
/// sources. That ceiling is deliberate: it is what makes a patch a fixed-size
/// document, what makes the render thread's state a fixed-size allocation, and
/// what stops the editor becoming a modular patching surface.
///
/// **Loading a patch fully determines the sound.** Nothing about how a line
/// sounds lives outside this struct except the seed's effect on noise and
/// sample-and-hold, and the seed is in here too. `SynthPatchDocument` is the
/// serialised form; `SynthPatchVoiceProvider` is how one becomes audible.
///
/// Continuous parameters are `Double` rather than `Float` even though the
/// engine works in `Float`. A `Double` survives a JSON round trip exactly, so
/// "serialise, load, and get byte-identical parameters back" is a property of
/// the type rather than a hope about the encoder.
public struct SynthPatch: Codable, Equatable, Sendable {
    /// Document format version.
    ///
    /// Increment it for any change to the shape of the serialised form. A
    /// reader refuses anything newer than it understands rather than guessing,
    /// and reads older documents through `SynthPatchDocument`'s
    /// version-dispatched decode — so raising this number without adding a
    /// reader for the version it replaces fails loudly instead of silently
    /// refusing every patch already on a user's disk.
    public static let currentVersion = 1

    /// Oscillators per voice, fixed by the architecture.
    public static let oscillatorCount = 3
    /// LFOs per voice, fixed by the architecture.
    public static let lfoCount = 2
    /// Modulation matrix slots, fixed by the architecture.
    public static let modulationSlotCount = 8
    /// Highest polyphony one sound may use.
    public static let maximumPolyphony = 32

    // MARK: Identity

    /// Stable identity, so a stored patch, a preset and a mixer strip can all
    /// refer to the same sound. The library (SYN002) owns allocating these;
    /// the engine only carries one through.
    public var identifier: String
    /// Human-readable name, shown wherever a sound is chosen.
    public var name: String

    // MARK: Sound

    public var oscillators: [Oscillator]
    /// White noise mixed alongside the oscillators, inside the voice, so the
    /// filter and envelope shape it like any other source.
    public var noiseLevel: Double

    public var filter: Filter
    public var amplitudeEnvelope: Envelope
    /// A second envelope that exists only to be a modulation source.
    public var modulationEnvelope: Envelope
    public var lfos: [LFO]
    public var modulation: [ModulationRoute]

    public var equalizer: Equalizer
    public var chorus: Chorus
    public var delay: Delay
    public var reverb: Reverb

    /// Simultaneous notes, 1…32.
    public var maximumVoices: Int
    /// The sound's own loudness, 0…1. Per-line gain stays the engine's.
    public var outputLevel: Double
    /// Exponent applied to velocity before it becomes amplitude. 1 is linear;
    /// above 1 widens the dynamic range, which is what makes PLY002's realized
    /// dynamics audible rather than merely present.
    public var velocitySensitivity: Double

    /// Seeds noise, sample-and-hold LFOs and the per-note random source.
    ///
    /// Part of the patch rather than of the render call, because "same patch +
    /// same events → same audio" has to hold across processes, and a seed
    /// chosen at render time would not.
    public var seed: UInt64

    // MARK: Nested parameter blocks

    public enum OscillatorType: String, Codable, Sendable, CaseIterable {
        /// Band-limited analogue waveform.
        case analog
        /// Four-frame wavetable, morphed by `shapeAmount`.
        case wavetable
        /// Two-operator FM: sine carrier, sine modulator.
        case frequencyModulation
    }

    public enum AnalogShape: String, Codable, Sendable, CaseIterable {
        case sine, triangle, saw, square
        /// Variable width, so the mod matrix can sweep it.
        case pulse
    }

    public enum WavetableBank: String, Codable, Sendable, CaseIterable {
        /// Sine through saw.
        case harmonic
        /// A resonant peak climbing the harmonic series.
        case formant
        /// Sparse upper partials.
        case metallic
        /// Odd harmonics only.
        case hollow
    }

    public struct Oscillator: Codable, Equatable, Sendable {
        public var type: OscillatorType
        /// Used when `type` is `.analog`.
        public var analogShape: AnalogShape
        /// Used when `type` is `.wavetable`.
        public var wavetableBank: WavetableBank
        /// 0…1.
        public var level: Double
        /// -48…48.
        public var detuneSemitones: Double
        /// -100…100.
        public var detuneCents: Double
        /// The one continuous control the matrix can reach, 0…1: pulse width,
        /// wavetable position, or FM depth, depending on `type`.
        public var shapeAmount: Double
        /// Modulator : carrier ratio for FM, 0.25…16.
        public var frequencyModulationRatio: Double
        /// Restart the phase on every note-on. Off means the oscillator
        /// free-runs, so repeated notes differ slightly.
        public var retriggersPhase: Bool
        /// 0…1.
        public var startPhase: Double

        public init(
            type: OscillatorType = .analog,
            analogShape: AnalogShape = .sine,
            wavetableBank: WavetableBank = .harmonic,
            level: Double = 0,
            detuneSemitones: Double = 0,
            detuneCents: Double = 0,
            shapeAmount: Double = 0.5,
            frequencyModulationRatio: Double = 1,
            retriggersPhase: Bool = true,
            startPhase: Double = 0
        ) {
            self.type = type
            self.analogShape = analogShape
            self.wavetableBank = wavetableBank
            self.level = level
            self.detuneSemitones = detuneSemitones
            self.detuneCents = detuneCents
            self.shapeAmount = shapeAmount
            self.frequencyModulationRatio = frequencyModulationRatio
            self.retriggersPhase = retriggersPhase
            self.startPhase = startPhase
        }
    }

    public enum FilterType: String, Codable, Sendable, CaseIterable {
        case lowpass, highpass, bandpass, notch
    }

    public struct Filter: Codable, Equatable, Sendable {
        /// Off bypasses the stage entirely. A patch with no filtering is a
        /// real patch — the shipped default voice is one — and bypassing says
        /// so more honestly than a cutoff parked above the audible range.
        public var isEnabled: Bool
        public var type: FilterType
        /// 2 or 4. Four is two identical stages in series.
        public var poles: Int
        /// 20…20000 Hz, clamped at render time to 45% of the sample rate.
        public var cutoffHertz: Double
        /// 0…1. Resonant, never self-oscillating.
        public var resonance: Double
        /// 0…1. How far the cutoff follows the note about middle C.
        public var keyTracking: Double

        public init(
            isEnabled: Bool = false,
            type: FilterType = .lowpass,
            poles: Int = 2,
            cutoffHertz: Double = 12_000,
            resonance: Double = 0,
            keyTracking: Double = 0
        ) {
            self.isEnabled = isEnabled
            self.type = type
            self.poles = poles
            self.cutoffHertz = cutoffHertz
            self.resonance = resonance
            self.keyTracking = keyTracking
        }
    }

    public struct Envelope: Codable, Equatable, Sendable {
        /// 0.0005…10 seconds.
        public var attackSeconds: Double
        /// 0.001…20 seconds.
        public var decaySeconds: Double
        /// 0…1.
        public var sustainLevel: Double
        /// 0.001…20 seconds.
        public var releaseSeconds: Double
        /// 0 is a straight line; 1 is the fast-then-slow curve of an analogue
        /// envelope.
        public var curve: Double

        public init(
            attackSeconds: Double = 0.008,
            decaySeconds: Double = 0.120,
            sustainLevel: Double = 0.6,
            releaseSeconds: Double = 0.220,
            curve: Double = 0
        ) {
            self.attackSeconds = attackSeconds
            self.decaySeconds = decaySeconds
            self.sustainLevel = sustainLevel
            self.releaseSeconds = releaseSeconds
            self.curve = curve
        }
    }

    public enum LFOShape: String, Codable, Sendable, CaseIterable {
        case sine, triangle, saw, square
        /// Stepped random, seeded per render.
        case sampleAndHold
    }

    public struct LFO: Codable, Equatable, Sendable {
        public var shape: LFOShape
        /// 0.01…40 Hz.
        public var rateHertz: Double
        /// 0…1.
        public var startPhase: Double
        /// On: every note gets the same LFO shape. Off: the LFO free-runs
        /// across the whole sound, so a chord moves together.
        public var retriggersPerNote: Bool

        public init(
            shape: LFOShape = .sine,
            rateHertz: Double = 5,
            startPhase: Double = 0,
            retriggersPerNote: Bool = false
        ) {
            self.shape = shape
            self.rateHertz = rateHertz
            self.startPhase = startPhase
            self.retriggersPerNote = retriggersPerNote
        }
    }

    public enum ModulationSource: String, Codable, Sendable, CaseIterable {
        case none
        case amplitudeEnvelope
        case modulationEnvelope
        case lfo1
        case lfo2
        /// Note velocity, 0…1.
        case velocity
        /// Note number relative to middle C, -1…1.
        case keyTrack
        /// One seeded random value per note, -1…1.
        case noteRandom
    }

    /// Where a modulation route lands.
    ///
    /// Voice-level only. Nothing here can reach line gain, pan, mute or solo —
    /// those belong to the engine, and a sound that could move them would make
    /// the mixer's arithmetic un-analysable.
    public enum ModulationDestination: String, Codable, Sendable, CaseIterable {
        case none
        /// ±24 semitones at full amount.
        case oscillator1Pitch, oscillator2Pitch, oscillator3Pitch
        /// Scales the oscillator's level, 0…2×.
        case oscillator1Level, oscillator2Level, oscillator3Level
        /// Offsets `shapeAmount`.
        case oscillator1Shape, oscillator2Shape, oscillator3Shape
        /// ±6 octaves at full amount.
        case filterCutoff
        case filterResonance
        /// Scales the whole voice, 0…2×.
        case amplitude
    }

    public struct ModulationRoute: Codable, Equatable, Sendable {
        public var source: ModulationSource
        public var destination: ModulationDestination
        /// -1…1.
        public var amount: Double

        public init(
            source: ModulationSource = .none,
            destination: ModulationDestination = .none,
            amount: Double = 0
        ) {
            self.source = source
            self.destination = destination
            self.amount = amount
        }

        public var isActive: Bool { source != .none && destination != .none && amount != 0 }
    }

    public struct Equalizer: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        /// -24…24 dB.
        public var lowGainDecibels: Double
        /// 30…1000 Hz.
        public var lowHertz: Double
        public var midGainDecibels: Double
        /// 100…8000 Hz.
        public var midHertz: Double
        /// 0.2…8.
        public var midQ: Double
        public var highGainDecibels: Double
        /// 1000…16000 Hz.
        public var highHertz: Double

        public init(
            isEnabled: Bool = false,
            lowGainDecibels: Double = 0,
            lowHertz: Double = 200,
            midGainDecibels: Double = 0,
            midHertz: Double = 1000,
            midQ: Double = 1,
            highGainDecibels: Double = 0,
            highHertz: Double = 6000
        ) {
            self.isEnabled = isEnabled
            self.lowGainDecibels = lowGainDecibels
            self.lowHertz = lowHertz
            self.midGainDecibels = midGainDecibels
            self.midHertz = midHertz
            self.midQ = midQ
            self.highGainDecibels = highGainDecibels
            self.highHertz = highHertz
        }
    }

    public struct Chorus: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        /// 0.01…8 Hz.
        public var rateHertz: Double
        /// 0.5…20 ms.
        public var depthMilliseconds: Double
        /// 1…30 ms.
        public var centreMilliseconds: Double
        /// 0…1.
        public var mix: Double
        /// 0…0.7. Bounded so the two taps cannot run away.
        public var feedback: Double

        public init(
            isEnabled: Bool = false,
            rateHertz: Double = 0.6,
            depthMilliseconds: Double = 4,
            centreMilliseconds: Double = 12,
            mix: Double = 0.4,
            feedback: Double = 0.15
        ) {
            self.isEnabled = isEnabled
            self.rateHertz = rateHertz
            self.depthMilliseconds = depthMilliseconds
            self.centreMilliseconds = centreMilliseconds
            self.mix = mix
            self.feedback = feedback
        }
    }

    public struct Delay: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        /// 0.005…1 second.
        public var timeSeconds: Double
        /// 0…0.85. Bounded, and the feedback path is damped, so the tail
        /// always decays.
        public var feedback: Double
        /// 0…1.
        public var mix: Double
        /// 0…1. Higher loses more of the top on every repeat.
        public var dampening: Double

        public init(
            isEnabled: Bool = false,
            timeSeconds: Double = 0.28,
            feedback: Double = 0.35,
            mix: Double = 0.25,
            dampening: Double = 0.4
        ) {
            self.isEnabled = isEnabled
            self.timeSeconds = timeSeconds
            self.feedback = feedback
            self.mix = mix
            self.dampening = dampening
        }
    }

    public struct Reverb: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        /// 0…1.
        public var roomSize: Double
        /// 0…1.
        public var dampening: Double
        /// 0…1.
        public var mix: Double
        /// 0…0.1 seconds.
        public var preDelaySeconds: Double

        public init(
            isEnabled: Bool = false,
            roomSize: Double = 0.6,
            dampening: Double = 0.5,
            mix: Double = 0.25,
            preDelaySeconds: Double = 0.02
        ) {
            self.isEnabled = isEnabled
            self.roomSize = roomSize
            self.dampening = dampening
            self.mix = mix
            self.preDelaySeconds = preDelaySeconds
        }
    }

    // MARK: Construction

    public init(
        identifier: String,
        name: String,
        oscillators: [Oscillator],
        noiseLevel: Double = 0,
        filter: Filter = Filter(),
        amplitudeEnvelope: Envelope = Envelope(),
        modulationEnvelope: Envelope = Envelope(
            attackSeconds: 0.010, decaySeconds: 0.400, sustainLevel: 0,
            releaseSeconds: 0.300, curve: 1
        ),
        lfos: [LFO] = [LFO(), LFO(rateHertz: 0.4)],
        modulation: [ModulationRoute] = Array(repeating: ModulationRoute(), count: modulationSlotCount),
        equalizer: Equalizer = Equalizer(),
        chorus: Chorus = Chorus(),
        delay: Delay = Delay(),
        reverb: Reverb = Reverb(),
        maximumVoices: Int = maximumPolyphony,
        outputLevel: Double = 0.14,
        velocitySensitivity: Double = 1.6,
        seed: UInt64 = 0x5EED_0000_C0FF_EE
    ) {
        self.identifier = identifier
        self.name = name
        self.oscillators = oscillators
        self.noiseLevel = noiseLevel
        self.filter = filter
        self.amplitudeEnvelope = amplitudeEnvelope
        self.modulationEnvelope = modulationEnvelope
        self.lfos = lfos
        self.modulation = modulation
        self.equalizer = equalizer
        self.chorus = chorus
        self.delay = delay
        self.reverb = reverb
        self.maximumVoices = maximumVoices
        self.outputLevel = outputLevel
        self.velocitySensitivity = velocitySensitivity
        self.seed = seed
    }

    // MARK: The shipped default voice (AD7)

    /// Increment 002's built-in voice, as a patch.
    ///
    /// Three sine partials at 1×, 2× and 3× with weights 1, 0.34 and 0.13
    /// through a linear 8 ms / 120 ms / 0.60 / 220 ms ADSR, velocity exponent
    /// 1.6, output level 0.14 — the same numbers the C default voice used. AD7
    /// says increment 003 replaces that voice with the real engine; making the
    /// replacement's first patch reproduce it means the app sounds the same the
    /// day this lands, and any change the offline suite measures afterwards is
    /// a real change rather than a new instrument.
    ///
    /// 19.01955 semitones is 12 × log₂3 — the third harmonic written in the
    /// tuning units a patch actually has.
    public static let defaultVoice = SynthPatch(
        identifier: "builtin.default-voice",
        name: "Default Voice",
        oscillators: [
            Oscillator(type: .analog, analogShape: .sine, level: 1.0),
            Oscillator(type: .analog, analogShape: .sine, level: 0.34, detuneSemitones: 12),
            Oscillator(type: .analog, analogShape: .sine, level: 0.13, detuneSemitones: 19.01955)
        ]
    )
}
