import Foundation

/// Every parameter of a `SynthPatch`, as data.
///
/// **This is what "every parameter is user-editable" (REQ-016) is made of.**
/// The alternative — a hundred hand-written SwiftUI controls, each with its own
/// literal range, its own formatting and its own accessibility label — has two
/// problems that matter more than the typing. A parameter that nobody wrote a
/// control for is invisible rather than broken, so the claim can quietly become
/// false; and a range written into a `body` cannot be tested, so "invalid entry
/// clamps" would be a property of a view rather than of the sound.
///
/// So the parameters are a list. The editor renders the list, the tests walk
/// the list, and adding a parameter to `SynthPatch` without adding it here
/// fails `SynthParameterTests.testEveryPatchParameterIsEditable` rather than
/// silently shipping a knob that does not exist.
///
/// Ranges here are SYN001's, stated once. The C side clamps again at
/// `synth_patch_config_sanitize`; that clamp is what the audio thread relies
/// on, and this one is what the owner sees — a field that snaps back to 20 kHz
/// rather than a sound that quietly ignores what they typed.
public struct SynthParameter: Identifiable, Sendable, Equatable {
    public let id: SynthParameterID
    /// The panel this belongs to: "Oscillator 1", "Filter", "Delay".
    public let group: String
    /// The control's own label: "Cutoff", "Attack".
    public let name: String
    /// One sentence saying what it does. The control's help tag and its
    /// VoiceOver hint, so the two cannot drift apart.
    public let detail: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        /// A continuous value.
        ///
        /// `isLogarithmic` is about the *control*, not the value: a cutoff
        /// slider that moves linearly from 20 Hz to 20 kHz spends nine tenths
        /// of its travel above 2 kHz and is useless for the bottom two octaves.
        /// The stored number is the same either way.
        case number(range: ClosedRange<Double>, unit: Unit, decimals: Int, isLogarithmic: Bool)
        case integer(range: ClosedRange<Int>)
        case flag
        /// A closed set. `values` are the stored raw values; `labels` are what
        /// the owner reads, in the same order.
        case option(values: [String], labels: [String])
    }

    /// What a number means, for display and for spoken output.
    public enum Unit: String, Sendable, Equatable {
        case none
        case hertz
        case seconds
        case milliseconds
        case decibels
        case semitones
        case cents
        case percent

        /// Spoken in full, because "Hz" read letter by letter is not a unit.
        var spokenName: String {
            switch self {
            case .none: return ""
            case .hertz: return "hertz"
            case .seconds: return "seconds"
            case .milliseconds: return "milliseconds"
            case .decibels: return "decibels"
            case .semitones: return "semitones"
            case .cents: return "cents"
            case .percent: return "percent"
            }
        }
    }
}

/// Which parameter. One case per field of `SynthPatch`, with an index where the
/// architecture has more than one of something.
public enum SynthParameterID: Hashable, Sendable {
    case oscillatorType(Int)
    case oscillatorAnalogShape(Int)
    case oscillatorWavetableBank(Int)
    case oscillatorLevel(Int)
    case oscillatorDetuneSemitones(Int)
    case oscillatorDetuneCents(Int)
    case oscillatorShapeAmount(Int)
    case oscillatorFrequencyModulationRatio(Int)
    case oscillatorRetriggersPhase(Int)
    case oscillatorStartPhase(Int)

    case noiseLevel

    case filterEnabled
    case filterType
    case filterPoles
    case filterCutoff
    case filterResonance
    case filterKeyTracking

    case envelopeAttack(EnvelopeSlot)
    case envelopeDecay(EnvelopeSlot)
    case envelopeSustain(EnvelopeSlot)
    case envelopeRelease(EnvelopeSlot)
    case envelopeCurve(EnvelopeSlot)

    case lfoShape(Int)
    case lfoRate(Int)
    case lfoStartPhase(Int)
    case lfoRetriggersPerNote(Int)

    case modulationSource(Int)
    case modulationDestination(Int)
    case modulationAmount(Int)

    case equalizerEnabled
    case equalizerLowGain
    case equalizerLowHertz
    case equalizerMidGain
    case equalizerMidHertz
    case equalizerMidQ
    case equalizerHighGain
    case equalizerHighHertz

    case chorusEnabled
    case chorusRate
    case chorusDepth
    case chorusCentre
    case chorusMix
    case chorusFeedback

    case delayEnabled
    case delayTime
    case delayFeedback
    case delayMix
    case delayDampening

    case reverbEnabled
    case reverbRoomSize
    case reverbDampening
    case reverbMix
    case reverbPreDelay

    case maximumVoices
    case outputLevel
    case velocitySensitivity
    case seed
}

/// Which of the two envelopes. Named rather than indexed, because they are not
/// interchangeable: one is the amplitude, the other exists only to be routed.
public enum EnvelopeSlot: String, Hashable, Sendable, CaseIterable {
    case amplitude
    case modulation

    public var displayName: String {
        switch self {
        case .amplitude: return "Amplitude Envelope"
        case .modulation: return "Modulation Envelope"
        }
    }
}

/// One parameter's value, in the shape the parameter actually has.
public enum SynthParameterValue: Equatable, Sendable {
    case number(Double)
    case integer(Int)
    case flag(Bool)
    /// A `RawRepresentable` enum's raw value.
    case option(String)

    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var integerValue: Int? { if case .integer(let value) = self { return value }; return nil }
    public var flagValue: Bool? { if case .flag(let value) = self { return value }; return nil }
    public var optionValue: String? { if case .option(let value) = self { return value }; return nil }
}

// MARK: - The list

extension SynthParameter {
    /// Every parameter, in the order a classic polysynth's front panel puts
    /// them: sources, then shaping, then modulation, then the effects, then the
    /// things that describe the whole instrument.
    ///
    /// Order is part of the answer here, not an implementation detail — it is
    /// the layout of the editor and the order VoiceOver walks.
    public static let all: [SynthParameter] = {
        var parameters: [SynthParameter] = []

        for index in 0..<SynthPatch.oscillatorCount {
            parameters += oscillatorParameters(index)
        }
        parameters.append(
            SynthParameter(
                id: .noiseLevel, group: "Mixer", name: "Noise",
                detail: "White noise mixed in alongside the oscillators, inside the voice, "
                    + "so the filter and envelope shape it like any other source.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            )
        )

        parameters += filterParameters()
        for slot in EnvelopeSlot.allCases { parameters += envelopeParameters(slot) }
        for index in 0..<SynthPatch.lfoCount { parameters += lfoParameters(index) }
        for index in 0..<SynthPatch.modulationSlotCount { parameters += modulationParameters(index) }
        parameters += equalizerParameters()
        parameters += chorusParameters()
        parameters += delayParameters()
        parameters += reverbParameters()
        parameters += voiceParameters()

        return parameters
    }()

    /// The parameter with this identity. The editor's controls are built from
    /// `all`, so this is for tests and for a menu command naming one directly.
    public static func parameter(_ id: SynthParameterID) -> SynthParameter? {
        byID[id]
    }

    private static let byID: [SynthParameterID: SynthParameter] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    /// The panels, in order, each with its parameters. What the editor lays out.
    public static let groups: [(name: String, parameters: [SynthParameter])] = {
        var order: [String] = []
        var byGroup: [String: [SynthParameter]] = [:]
        for parameter in all {
            if byGroup[parameter.group] == nil { order.append(parameter.group) }
            byGroup[parameter.group, default: []].append(parameter)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }()

    // MARK: Group builders

    private static func oscillatorParameters(_ index: Int) -> [SynthParameter] {
        let group = "Oscillator \(index + 1)"
        return [
            SynthParameter(
                id: .oscillatorType(index), group: group, name: "Type",
                detail: "Analogue waveform, four-frame wavetable, or two-operator FM.",
                kind: .option(
                    values: SynthPatch.OscillatorType.allCases.map(\.rawValue),
                    labels: SynthPatch.OscillatorType.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .oscillatorAnalogShape(index), group: group, name: "Waveform",
                detail: "Which band-limited analogue waveform this oscillator reads.",
                kind: .option(
                    values: SynthPatch.AnalogShape.allCases.map(\.rawValue),
                    labels: SynthPatch.AnalogShape.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .oscillatorWavetableBank(index), group: group, name: "Bank",
                detail: "Which four-frame wavetable bank the shape control morphs through.",
                kind: .option(
                    values: SynthPatch.WavetableBank.allCases.map(\.rawValue),
                    labels: SynthPatch.WavetableBank.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .oscillatorLevel(index), group: group, name: "Level",
                detail: "How much of this oscillator reaches the filter.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .oscillatorDetuneSemitones(index), group: group, name: "Coarse",
                detail: "Transposes this oscillator in semitones.",
                kind: .number(range: -48...48, unit: .semitones, decimals: 2, isLogarithmic: false)
            ),
            SynthParameter(
                id: .oscillatorDetuneCents(index), group: group, name: "Fine",
                detail: "Detunes this oscillator in hundredths of a semitone. "
                    + "A few cents against another oscillator is what makes a patch sound wide.",
                kind: .number(range: -100...100, unit: .cents, decimals: 1, isLogarithmic: false)
            ),
            SynthParameter(
                id: .oscillatorShapeAmount(index), group: group, name: "Shape",
                detail: "Pulse width, wavetable position, or FM depth, depending on the type. "
                    + "The one continuous per-oscillator control the modulation matrix can reach.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .oscillatorFrequencyModulationRatio(index), group: group, name: "FM Ratio",
                detail: "Modulator to carrier frequency ratio. Whole numbers stay harmonic; "
                    + "anything else goes metallic.",
                kind: .number(range: 0.25...16, unit: .none, decimals: 2, isLogarithmic: true)
            ),
            SynthParameter(
                id: .oscillatorRetriggersPhase(index), group: group, name: "Retrigger Phase",
                detail: "On, every note starts at the same point in the waveform. "
                    + "Off, the oscillator free-runs, so repeated notes differ slightly.",
                kind: .flag
            ),
            SynthParameter(
                id: .oscillatorStartPhase(index), group: group, name: "Start Phase",
                detail: "Where in the waveform a retriggered note begins.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            )
        ]
    }

    private static func filterParameters() -> [SynthParameter] {
        let group = "Filter"
        return [
            SynthParameter(
                id: .filterEnabled, group: group, name: "Enabled",
                detail: "Off bypasses the filter entirely. A patch with no filtering is a real patch.",
                kind: .flag
            ),
            SynthParameter(
                id: .filterType, group: group, name: "Type",
                detail: "Which side of the cutoff the filter keeps.",
                kind: .option(
                    values: SynthPatch.FilterType.allCases.map(\.rawValue),
                    labels: SynthPatch.FilterType.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .filterPoles, group: group, name: "Slope",
                detail: "Two poles is 12 dB per octave; four is 24, two identical stages in series.",
                kind: .integer(range: 2...4)
            ),
            SynthParameter(
                id: .filterCutoff, group: group, name: "Cutoff",
                detail: "Where the filter turns over. Clamped at render time to 45% of the sample rate.",
                kind: .number(range: 20...20_000, unit: .hertz, decimals: 0, isLogarithmic: true)
            ),
            SynthParameter(
                id: .filterResonance, group: group, name: "Resonance",
                detail: "Emphasis at the cutoff. Resonant, never self-oscillating.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .filterKeyTracking, group: group, name: "Key Tracking",
                detail: "How far the cutoff follows the note about middle C. "
                    + "Full tracking keeps the same brightness across the keyboard.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            )
        ]
    }

    private static func envelopeParameters(_ slot: EnvelopeSlot) -> [SynthParameter] {
        let group = slot.displayName
        let what = slot == .amplitude
            ? "the voice's loudness"
            : "a value that exists only to be routed through the modulation matrix"
        return [
            SynthParameter(
                id: .envelopeAttack(slot), group: group, name: "Attack",
                detail: "How long \(what) takes to reach full after a note starts.",
                kind: .number(range: 0.0005...10, unit: .seconds, decimals: 4, isLogarithmic: true)
            ),
            SynthParameter(
                id: .envelopeDecay(slot), group: group, name: "Decay",
                detail: "How long it takes to fall from full to the sustain level.",
                kind: .number(range: 0.001...20, unit: .seconds, decimals: 3, isLogarithmic: true)
            ),
            SynthParameter(
                id: .envelopeSustain(slot), group: group, name: "Sustain",
                detail: "The level it holds at while a note is held down.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .envelopeRelease(slot), group: group, name: "Release",
                detail: "How long it takes to reach silence after the note is let go.",
                kind: .number(range: 0.001...20, unit: .seconds, decimals: 3, isLogarithmic: true)
            ),
            SynthParameter(
                id: .envelopeCurve(slot), group: group, name: "Curve",
                detail: "Zero is a straight line; full is the fast-then-slow curve of an analogue envelope.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            )
        ]
    }

    private static func lfoParameters(_ index: Int) -> [SynthParameter] {
        let group = "LFO \(index + 1)"
        return [
            SynthParameter(
                id: .lfoShape(index), group: group, name: "Shape",
                detail: "The waveform this LFO sends to the modulation matrix.",
                kind: .option(
                    values: SynthPatch.LFOShape.allCases.map(\.rawValue),
                    labels: SynthPatch.LFOShape.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .lfoRate(index), group: group, name: "Rate",
                detail: "How fast it moves.",
                kind: .number(range: 0.01...40, unit: .hertz, decimals: 2, isLogarithmic: true)
            ),
            SynthParameter(
                id: .lfoStartPhase(index), group: group, name: "Start Phase",
                detail: "Where in its cycle a retriggered LFO begins.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .lfoRetriggersPerNote(index), group: group, name: "Retrigger Per Note",
                detail: "On, every note gets the same LFO shape. "
                    + "Off, it free-runs across the whole sound, so a chord moves together.",
                kind: .flag
            )
        ]
    }

    private static func modulationParameters(_ index: Int) -> [SynthParameter] {
        let group = "Modulation Matrix"
        return [
            SynthParameter(
                id: .modulationSource(index), group: group, name: "Route \(index + 1) Source",
                detail: "What moves.",
                kind: .option(
                    values: SynthPatch.ModulationSource.allCases.map(\.rawValue),
                    labels: SynthPatch.ModulationSource.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .modulationDestination(index), group: group, name: "Route \(index + 1) Destination",
                detail: "What it moves. Voice-level only: nothing here can reach line gain, pan, mute or solo.",
                kind: .option(
                    values: SynthPatch.ModulationDestination.allCases.map(\.rawValue),
                    labels: SynthPatch.ModulationDestination.allCases.map(\.displayName)
                )
            ),
            SynthParameter(
                id: .modulationAmount(index), group: group, name: "Route \(index + 1) Amount",
                detail: "How much, and in which direction. Zero makes the route inactive.",
                kind: .number(range: -1...1, unit: .percent, decimals: 0, isLogarithmic: false)
            )
        ]
    }

    private static func equalizerParameters() -> [SynthParameter] {
        let group = "Equaliser"
        return [
            SynthParameter(id: .equalizerEnabled, group: group, name: "Enabled",
                           detail: "Three bands after the voices are summed: low shelf, peaking mid, high shelf.",
                           kind: .flag),
            SynthParameter(id: .equalizerLowGain, group: group, name: "Low Gain",
                           detail: "Cut or boost below the low frequency.",
                           kind: .number(range: -24...24, unit: .decibels, decimals: 1, isLogarithmic: false)),
            SynthParameter(id: .equalizerLowHertz, group: group, name: "Low Frequency",
                           detail: "Where the low shelf turns over.",
                           kind: .number(range: 30...1000, unit: .hertz, decimals: 0, isLogarithmic: true)),
            SynthParameter(id: .equalizerMidGain, group: group, name: "Mid Gain",
                           detail: "Cut or boost around the mid frequency.",
                           kind: .number(range: -24...24, unit: .decibels, decimals: 1, isLogarithmic: false)),
            SynthParameter(id: .equalizerMidHertz, group: group, name: "Mid Frequency",
                           detail: "The centre of the peaking band.",
                           kind: .number(range: 100...8000, unit: .hertz, decimals: 0, isLogarithmic: true)),
            SynthParameter(id: .equalizerMidQ, group: group, name: "Mid Q",
                           detail: "How narrow the peaking band is. Higher is narrower.",
                           kind: .number(range: 0.2...8, unit: .none, decimals: 2, isLogarithmic: true)),
            SynthParameter(id: .equalizerHighGain, group: group, name: "High Gain",
                           detail: "Cut or boost above the high frequency.",
                           kind: .number(range: -24...24, unit: .decibels, decimals: 1, isLogarithmic: false)),
            SynthParameter(id: .equalizerHighHertz, group: group, name: "High Frequency",
                           detail: "Where the high shelf turns over.",
                           kind: .number(range: 1000...16_000, unit: .hertz, decimals: 0, isLogarithmic: true))
        ]
    }

    private static func chorusParameters() -> [SynthParameter] {
        let group = "Chorus"
        return [
            SynthParameter(id: .chorusEnabled, group: group, name: "Enabled",
                           detail: "A modulated delay tap mixed back in, which widens a thin sound.",
                           kind: .flag),
            SynthParameter(id: .chorusRate, group: group, name: "Rate",
                           detail: "How fast the tap is swept.",
                           kind: .number(range: 0.01...8, unit: .hertz, decimals: 2, isLogarithmic: true)),
            SynthParameter(id: .chorusDepth, group: group, name: "Depth",
                           detail: "How far the tap is swept either side of centre.",
                           kind: .number(range: 0.5...20, unit: .milliseconds, decimals: 2, isLogarithmic: false)),
            SynthParameter(id: .chorusCentre, group: group, name: "Delay",
                           detail: "Where the tap sits when the sweep is at rest.",
                           kind: .number(range: 1...30, unit: .milliseconds, decimals: 2, isLogarithmic: false)),
            SynthParameter(id: .chorusMix, group: group, name: "Mix",
                           detail: "How much of the effect is heard against the dry signal.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .chorusFeedback, group: group, name: "Feedback",
                           detail: "How much of the tap is fed back in. Bounded so the two taps cannot run away.",
                           kind: .number(range: 0...0.7, unit: .percent, decimals: 0, isLogarithmic: false))
        ]
    }

    private static func delayParameters() -> [SynthParameter] {
        let group = "Delay"
        return [
            SynthParameter(id: .delayEnabled, group: group, name: "Enabled",
                           detail: "A single damped echo line after the chorus.",
                           kind: .flag),
            SynthParameter(id: .delayTime, group: group, name: "Time",
                           detail: "How long each repeat takes to come back.",
                           kind: .number(range: 0.005...1, unit: .seconds, decimals: 3, isLogarithmic: true)),
            SynthParameter(id: .delayFeedback, group: group, name: "Feedback",
                           detail: "How much of each repeat feeds the next. Damped, so the tail always decays.",
                           kind: .number(range: 0...0.85, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .delayMix, group: group, name: "Mix",
                           detail: "How much of the repeats are heard against the dry signal.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .delayDampening, group: group, name: "Dampening",
                           detail: "How much of the top is lost on every repeat.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false))
        ]
    }

    private static func reverbParameters() -> [SynthParameter] {
        let group = "Reverb"
        return [
            SynthParameter(id: .reverbEnabled, group: group, name: "Enabled",
                           detail: "Eight damped combs into four allpasses — a room, at the end of the chain.",
                           kind: .flag),
            SynthParameter(id: .reverbRoomSize, group: group, name: "Room Size",
                           detail: "How long the room rings for.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .reverbDampening, group: group, name: "Dampening",
                           detail: "How much of the top the room absorbs as it rings.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .reverbMix, group: group, name: "Mix",
                           detail: "How much of the room is heard against the dry signal.",
                           kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)),
            SynthParameter(id: .reverbPreDelay, group: group, name: "Pre-delay",
                           detail: "How long the room waits before it starts to answer.",
                           kind: .number(range: 0...0.1, unit: .seconds, decimals: 3, isLogarithmic: false))
        ]
    }

    private static func voiceParameters() -> [SynthParameter] {
        let group = "Voice"
        return [
            SynthParameter(
                id: .maximumVoices, group: group, name: "Polyphony",
                detail: "How many notes this sound may hold at once before it starts stealing.",
                kind: .integer(range: 1...SynthPatch.maximumPolyphony)
            ),
            SynthParameter(
                id: .outputLevel, group: group, name: "Output Level",
                detail: "The sound's own loudness relative to other sounds. Per-line gain stays the mixer's.",
                kind: .number(range: 0...1, unit: .percent, decimals: 0, isLogarithmic: false)
            ),
            SynthParameter(
                id: .velocitySensitivity, group: group, name: "Velocity Sensitivity",
                detail: "Exponent applied to velocity before it becomes amplitude. "
                    + "One is linear; above one widens the dynamic range.",
                kind: .number(range: 0.2...4, unit: .none, decimals: 2, isLogarithmic: false)
            ),
            SynthParameter(
                id: .seed, group: group, name: "Random Seed",
                detail: "Seeds noise, sample-and-hold LFOs and the per-note random source, "
                    + "so the same patch and the same notes always produce the same audio.",
                kind: .integer(range: 0...Self.seedCeiling)
            )
        ]
    }

    /// The largest seed the editor offers.
    ///
    /// The patch stores a full 64-bit seed and always will; this is what a
    /// person can reasonably type and what a stepper can reasonably reach.
    /// A patch whose seed is above it — none of the shipped ones are — reads
    /// back clamped in the editor and is left alone unless the owner changes
    /// it, which is why `setting` writes only when the value actually differs.
    public static let seedCeiling = 9_999_999
}

// MARK: - Display

extension SynthParameter {
    /// What the control shows: "12.0 kHz", "-3.5 dB", "8 ms", "Saw".
    public func displayText(for value: SynthParameterValue) -> String {
        switch (kind, value) {
        case (.flag, .flag(let flag)):
            return flag ? "On" : "Off"

        case (.integer, .integer(let number)):
            return "\(number)"

        case (.option(let values, let labels), .option(let raw)):
            guard let index = values.firstIndex(of: raw), index < labels.count else { return raw }
            return labels[index]

        case (.number(_, let unit, let decimals, _), .number(let number)):
            return Self.formatted(number, unit: unit, decimals: decimals)

        default:
            // A mismatched pair is a programming error rather than a state the
            // owner can produce; showing the raw value beats crashing a panel.
            return "\(value)"
        }
    }

    /// What VoiceOver says the control is set to.
    ///
    /// A separate string from `displayText` for one reason: "kHz" and "dB" read
    /// letter by letter, and a spoken value has to be a phrase.
    public func spokenValue(for value: SynthParameterValue) -> String {
        guard case .number(_, let unit, let decimals, _) = kind,
              case .number(let number) = value else {
            return displayText(for: value)
        }
        switch unit {
        case .none:
            return Self.trimmed(number, decimals: decimals)
        case .percent:
            return "\(Int((number * 100).rounded())) percent"
        case .hertz where number >= 1000:
            return "\(Self.trimmed(number / 1000, decimals: 2)) kilohertz"
        case .seconds where number < 1:
            return "\(Int((number * 1000).rounded())) milliseconds"
        default:
            return "\(Self.trimmed(number, decimals: decimals)) \(unit.spokenName)"
        }
    }

    /// What VoiceOver calls the control. The group is in it because "Attack"
    /// alone appears twice on this panel and "Rate" appears three times.
    public var accessibilityLabel: String { "\(group) \(name)" }

    private static func formatted(_ number: Double, unit: Unit, decimals: Int) -> String {
        switch unit {
        case .none:
            return trimmed(number, decimals: decimals)
        case .percent:
            return "\(Int((number * 100).rounded()))%"
        case .hertz:
            return number >= 1000
                ? "\(trimmed(number / 1000, decimals: 2)) kHz"
                : "\(trimmed(number, decimals: 0)) Hz"
        case .seconds:
            return number < 1
                ? "\(Int((number * 1000).rounded())) ms"
                : "\(trimmed(number, decimals: 2)) s"
        case .milliseconds:
            return "\(trimmed(number, decimals: 1)) ms"
        case .decibels:
            return "\(trimmed(number, decimals: 1)) dB"
        case .semitones:
            return "\(trimmed(number, decimals: 2)) st"
        case .cents:
            return "\(trimmed(number, decimals: 1)) ¢"
        }
    }

    /// A fixed number of decimals with the trailing zeros taken off, so a
    /// coarse detune of exactly 12 reads "12" rather than "12.00".
    ///
    /// Deliberately not a `NumberFormatter`: these strings are asserted in
    /// tests and read back off the accessibility tree as evidence, and a
    /// locale that writes "12,00" would make that evidence depend on where the
    /// machine thinks it is.
    private static func trimmed(_ number: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", number)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

// MARK: - Slider mapping

extension SynthParameter {
    /// A continuous parameter's value as 0…1 along its control.
    ///
    /// Only meaningful for `.number`; anything else has no travel and returns
    /// zero. Logarithmic parameters map by ratio, so the middle of a cutoff
    /// slider is the geometric mean of its ends rather than 10 kHz.
    public func normalized(_ number: Double) -> Double {
        guard case .number(let range, _, _, let isLogarithmic) = kind else { return 0 }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        if isLogarithmic, range.lowerBound > 0 {
            let low = log(range.lowerBound)
            let span = log(range.upperBound) - low
            return span > 0 ? (log(clamped) - low) / span : 0
        }
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (clamped - range.lowerBound) / span : 0
    }

    /// The inverse of `normalized`.
    public func denormalized(_ position: Double) -> Double {
        guard case .number(let range, _, _, let isLogarithmic) = kind else { return 0 }
        let clamped = min(max(position, 0), 1)
        if isLogarithmic, range.lowerBound > 0 {
            let low = log(range.lowerBound)
            let span = log(range.upperBound) - low
            return exp(low + span * clamped)
        }
        return range.lowerBound + (range.upperBound - range.lowerBound) * clamped
    }

    /// Bring a number into range. What "invalid parameter entry clamps to valid
    /// ranges" means, before the value ever reaches a patch.
    ///
    /// A value that is not a number at all — the result of an empty or
    /// nonsensical field — becomes the bottom of the range rather than
    /// propagating a NaN into the audio, which is the same choice
    /// `synth_patch_config_sanitize` makes.
    public func clamp(_ number: Double) -> Double {
        guard case .number(let range, _, _, _) = kind else { return number }
        guard number.isFinite else { return range.lowerBound }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}
