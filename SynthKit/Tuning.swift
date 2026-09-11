import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// How the twelve pitch classes are spaced (REQ-006, D65-1).
///
/// **Two, and the product ships two.** A temperament catalogue is an explicit
/// non-goal of the approved plan: what REQ-006 asks for is the *option* of a
/// historical colour beside the modern default, not a tuning workbench. Equal
/// temperament is what every piece plays now; Werckmeister III is the one well
/// temperament the baroque repertoire this app is built around was actually
/// written into. User-defined temperaments and microtonal score support are out
/// of scope for the whole increment.
///
/// Adding a third later is adding a case and its published table, and nothing
/// else: every mechanism below — the reference anchor, the render table, the
/// engines, the picker — is written over `offsetsInCentsAboveEqual`.
public enum Temperament: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Twelve equal steps. The default, and what the engines did before this
    /// existed.
    case equal

    /// Werckmeister III (Andreas Werckmeister, 1691, *Musicalische
    /// Temperatur* — his "correct temperament no. 1"): the Pythagorean comma
    /// divided in four and distributed over C–G, G–D, D–A and B–F♯, leaving the
    /// common keys close to pure and the remote ones audibly coloured.
    case werckmeisterIII

    /// What the picker calls it.
    public var displayName: String {
        switch self {
        case .equal: return "Equal"
        case .werckmeisterIII: return "Werckmeister III"
        }
    }

    /// What VoiceOver says, where there is room for the whole sentence.
    public var accessibilityDescription: String {
        switch self {
        case .equal:
            return "Equal temperament, twelve equal steps"
        case .werckmeisterIII:
            return "Werckmeister III, a baroque well temperament"
        }
    }

    /// Each pitch class's distance above twelve-equal, in cents, indexed by
    /// `midiNoteNumber % 12` so index 0 is C and index 9 is A.
    ///
    /// **Stored as published, rooted on C.** These are the literature's own
    /// figures — Werckmeister III's degrees are 0, 90.225, 192.18, 294.135,
    /// 390.225, 498.045, 588.27, 696.09, 792.18, 888.27, 996.09 and 1092.18
    /// cents above its C — minus the equal-tempered degree at each step. Keeping
    /// them in that form is what makes this table checkable against a book
    /// instead of against this file. Where the tuning is *anchored* is a separate
    /// decision, made once in `TuningSettings.offsetsInCentsFromEqual`.
    public var offsetsInCentsAboveEqual: [Double] {
        switch self {
        case .equal:
            return Array(repeating: 0, count: TuningSettings.pitchClassCount)
        case .werckmeisterIII:
            return [
                 0.000,   // C
                -9.775,   // C♯
                -7.820,   // D
                -5.865,   // E♭
                -9.775,   // E
                -1.955,   // F
               -11.730,   // F♯
                -3.910,   // G
                -7.820,   // G♯
               -11.730,   // A
                -3.910,   // B♭
                -7.820    // B
            ]
        }
    }
}

/// What A above middle C is tuned to (REQ-006, D65-1).
///
/// Two, for the reason `Temperament` has two: the choice REQ-006 asks for is
/// modern concert pitch or the baroque pitch the repertoire was played at, not a
/// free frequency field.
public enum ReferencePitch: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Modern concert pitch. The default, and what the engines did before this
    /// existed.
    case a440

    /// Baroque pitch, roughly a semitone below modern — the pitch level much of
    /// the repertoire this app plays was written for.
    case a415

    /// A4, in hertz.
    public var hertz: Double {
        switch self {
        case .a440: return 440
        case .a415: return 415
        }
    }

    /// What the picker calls it.
    public var displayName: String {
        switch self {
        case .a440: return "A=440"
        case .a415: return "A=415"
        }
    }

    /// What VoiceOver says.
    public var accessibilityDescription: String {
        switch self {
        case .a440: return "A equals 440 hertz, modern concert pitch"
        case .a415: return "A equals 415 hertz, baroque pitch"
        }
    }
}

/// The whole of the owner's tuning choice (REQ-006): a temperament and a
/// reference pitch, stored with the preset.
///
/// **Two pickers and nothing else, per D65-1.** The mechanism underneath is a
/// per-program table of twelve ratios; what the owner sees is which temperament
/// and which A. Everything in between — the table, the anchor, the composition
/// with a per-instrument offset — is derived here and in the engines, and none of
/// it is a control.
///
/// A separate type from `ExpressionSettings` and `ProducedMasterSettings` for the
/// reason those two are separate from each other: they are different kinds of
/// thing. Expression shapes the realized timeline, the produced master shapes the
/// summed audio, and this shapes the frequency every voice derives at note-on.
/// Which is also why this one, alone of the three, rebuilds the render program:
/// tuning is baked into a voice when the voice is built.
public struct TuningSettings: Equatable, Hashable, Sendable, Codable {
    /// Pitch classes in a chromatic octave, and therefore entries in a tuning
    /// table. Indexed by `midiNoteNumber % 12`: index 0 is C, index 9 is A.
    public static let pitchClassCount = 12

    /// The pitch class A falls on, and therefore the table entry the reference
    /// pitch pins. `69 % 12`, written out because the whole anchoring rule below
    /// turns on it.
    public static let referencePitchClass = 9

    public let temperament: Temperament

    public let referencePitch: ReferencePitch

    /// A temperament name a stored document carried that this build does not
    /// know, or nil — which is the normal case.
    ///
    /// **Why it is kept rather than discarded.** REQ-006's failure clause says an
    /// unknown stored temperament decodes to equal temperament and is reported,
    /// never silence and never a crash. Decoding to equal satisfies the first
    /// half; keeping the name satisfies the rest of it twice over. It is what
    /// `failureSentence` has to say in order to say anything true, and it is what
    /// stops a preset written by a later build from being *destroyed* by an older
    /// one — the preset auto-saves on every performance change, so a silently
    /// dropped name would be overwritten with "equal" the next time the owner
    /// moved any slider. The owner choosing a temperament clears it, which is the
    /// one moment replacing it is what they asked for.
    public let unrecognizedTemperament: String?

    public init(
        temperament: Temperament = .equal,
        referencePitch: ReferencePitch = .a440,
        unrecognizedTemperament: String? = nil
    ) {
        self.temperament = temperament
        self.referencePitch = referencePitch
        self.unrecognizedTemperament = unrecognizedTemperament
    }

    /// What playback uses when the owner has not chosen: equal temperament at
    /// A=440.
    ///
    /// **Deliberately not an opinion**, unlike `ExpressionSettings.standard` and
    /// `ProducedMasterSettings.standard`, which owner decision D65-3 turns *on*
    /// for presets written before they existed. REQ-006 requires the default to
    /// be indistinguishable from what the app did before this leaf, so the
    /// default here is the identity and a library of stored presets sounds
    /// exactly as it did.
    /// It is also REQ-004's bypass state for the tuning term, and that is not a
    /// coincidence to be tidied into two names: REQ-006 *requires* the default to
    /// be the identity, so "the default" and "tuning off" are the same value by
    /// specification. `isDefault` is what a bypass check should assert.
    public static let standard = TuningSettings()

    /// True when this tuning changes nothing at all — equal temperament at
    /// A=440.
    ///
    /// **Load-bearing for REQ-004 and REQ-006**: the default is not merely close
    /// to the pre-feature render, it multiplies every frequency by exactly one.
    public var isDefault: Bool {
        temperament == .equal && referencePitch == .a440
    }

    /// Why this tuning is not quite what the stored preset asked for, or nil when
    /// there is nothing to say.
    ///
    /// The honest-reporting half of REQ-006's failure clause, phrased for the
    /// status bar the way `MasterCalibration.statusSentence` is.
    public var failureSentence: String? {
        guard let unrecognizedTemperament else { return nil }
        return "This preset asks for a temperament this version of Synth does not know "
            + "(“\(unrecognizedTemperament)”), so the piece is playing in equal temperament. "
            + "Choosing a temperament here replaces it."
    }

    // MARK: The table

    /// Each pitch class's distance from twelve-equal, in cents, as this tuning
    /// actually applies it — the temperament's published table shifted so that A
    /// is where the reference pitch says it is.
    ///
    /// **The one anchoring decision, made here and nowhere else.** A temperament
    /// is published as a set of degrees above its root, and Werckmeister's root is
    /// C; taken literally, selecting it would also move A off the reference pitch
    /// by 11.73 cents, and a setting labelled "A=440" would stop being true. So
    /// the published table is shifted by its own A entry. That changes no interval
    /// — every distance between two pitch classes is exactly what Werckmeister
    /// wrote — and it makes the two controls orthogonal: the temperament decides
    /// where the other eleven pitch classes sit *relative to A*, and the reference
    /// pitch decides where A is. The owner can then read the two rows as the two
    /// facts they state.
    ///
    /// The alternative — anchoring C and letting A drift — would make the
    /// reference-pitch row describe a frequency no note in the piece is tuned to.
    public var offsetsInCentsFromEqual: [Double] {
        let published = temperament.offsetsInCentsAboveEqual
        guard published.count == Self.pitchClassCount else {
            return Array(repeating: 0, count: Self.pitchClassCount)
        }
        let atA = published[Self.referencePitchClass]
        return published.map { $0 - atA }
    }

    /// The frequency this tuning gives a MIDI note, in hertz.
    ///
    /// The same arithmetic `SynthPatchEngine.c` performs at note-on, in the same
    /// order — so a test can state a per-pitch-class expectation in hertz and
    /// compare it against measured audio rather than against a second derivation
    /// written for the test.
    public func frequency(ofMIDINote midiNoteNumber: Int) -> Double {
        440 * pow(2, (Double(midiNoteNumber) - 69) / 12)
            * ratio(forMIDINote: midiNoteNumber)
    }

    /// What this tuning multiplies a note's frequency — or a sample's playback
    /// rate — by, relative to equal temperament at A=440.
    ///
    /// One number, used by both engines, which is what makes one setting mean one
    /// thing across a synth patch and a sampled instrument. It is the
    /// reference-pitch ratio and the temperament's own offset in a single factor:
    /// neither is applied without the other.
    public func ratio(forMIDINote midiNoteNumber: Int) -> Double {
        let pitchClass = ((midiNoteNumber % Self.pitchClassCount) + Self.pitchClassCount)
            % Self.pitchClassCount
        return ratiosByPitchClass[pitchClass]
    }

    /// The twelve ratios, in pitch-class order.
    ///
    /// Cents and hertz become ratios **here, on the control thread**, which is
    /// this repository's rule for the whole boundary — the same rule
    /// `InstrumentCustomization.renderCustomization` states for the tuning offset
    /// it converts. The audio thread never converts anything; it multiplies.
    public var ratiosByPitchClass: [Double] {
        let reference = referencePitch.hertz / ReferencePitch.a440.hertz
        return offsetsInCentsFromEqual.map { cents in
            // Written so the default is exact rather than nearly exact: at
            // A=440 the reference factor is literally 1.0, and `pow(2, 0)` is
            // literally 1.0, so the product is the identity and a note's
            // frequency comes out as the same bit pattern it did before this
            // table existed.
            reference * pow(2, cents / 1200)
        }
    }

    /// This tuning in the form the render core takes.
    ///
    /// The sampler's `renderCustomization` precedent exactly: one small flat
    /// struct, built on the control thread, holding only what the render thread
    /// multiplies by.
    var renderTable: SynthTuningTable {
        var table = SynthTuningTable()
        // Through the C default first, so this cannot be the place a new field
        // on that struct is left uninitialised.
        synth_tuning_table_default(&table)
        let ratios = ratiosByPitchClass
        // A C array of twelve doubles imports as a tuple, which has no
        // subscript; this is the standard way to write one element at a time.
        withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
            let entries = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: Double.self)
            for index in 0..<Self.pitchClassCount { entries[index] = ratios[index] }
        }
        return table
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case temperament, referencePitch
    }

    /// **Lenient about a name it does not know, strict about nothing else.**
    ///
    /// REQ-006's failure clause: a stored temperament this build cannot
    /// recognise reads as equal temperament and is reported, rather than
    /// refusing to open the preset or playing nothing. The `HumanizationSettings`
    /// clamp is the precedent — a stored document cannot smuggle a value past the
    /// model — with the difference that an enumeration has no nearest legal value
    /// to clamp to, so the legal value is the default and the original name is
    /// carried for the sentence that explains it.
    ///
    /// An unknown *reference pitch* is handled the same way and deliberately
    /// without its own report: the temperament is the setting whose name carries
    /// musical meaning, and a reference pitch that is not one of two known
    /// strings is a corrupt two-field record whose first field already spoke.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedTemperament = try container.decodeIfPresent(String.self, forKey: .temperament)
        let storedReference = try container.decodeIfPresent(String.self, forKey: .referencePitch)
        let known = storedTemperament.flatMap(Temperament.init(rawValue:))
        self.init(
            temperament: known ?? .equal,
            referencePitch: storedReference.flatMap(ReferencePitch.init(rawValue:)) ?? .a440,
            unrecognizedTemperament: known == nil ? storedTemperament : nil
        )
    }

    /// Writes the name the document came in with when this build did not know it,
    /// so an older build reading a newer preset reports the owner's choice rather
    /// than overwriting it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unrecognizedTemperament ?? temperament.rawValue, forKey: .temperament)
        try container.encode(referencePitch.rawValue, forKey: .referencePitch)
    }
}
