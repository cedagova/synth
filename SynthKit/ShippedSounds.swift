import Foundation

/// The categorised starter collection every copy of Synth is born with
/// (REQ-019).
///
/// **These are app content, not store rows.** The collection is compiled into
/// the build and versioned with it, so:
///
/// - it is present on first run without anything being written anywhere;
/// - "shipped content is never duplicated into user storage until edited" is
///   literally true rather than a rule someone has to remember;
/// - deleting a shipped sound is *impossible* rather than refused — there is no
///   row to delete; and
/// - improving a shipped sound in a later app version reaches every owner,
///   instead of only the ones who install fresh.
///
/// The owner's route to changing any of these is `SoundLibrary.makeEditableCopy`
/// (REQ-017): it produces a user sound with its own identity, and nothing the
/// owner then does to that copy can reach back here.
public struct ShippedSoundCollection: Sendable {
    /// Every shipped sound, in the order the library lists them.
    public let sounds: [SoundEntry]

    public init(sounds: [SoundEntry]) {
        self.sounds = sounds.sorted(by: SoundEntry.isOrderedBefore)
    }

    /// The shipped sound with this identity, if it is one.
    public func sound(withID id: String) -> SoundEntry? {
        sounds.first { $0.id == id }
    }

    /// The collection this build ships.
    public static let standard = ShippedSoundCollection(
        sounds: ShippedSounds.all.map(ShippedSounds.entry(for:))
    )
}

/// The shipped patches themselves.
///
/// Twenty-five sounds across the eight synth `SoundCategory` values, every
/// category occupied. They are written against the fixed REQ-016 architecture
/// (D6) and use it: analogue, wavetable and FM oscillators; the filter with and
/// without the modulation matrix driving it; all four effects. A starter
/// collection whose members all sounded alike would satisfy a naive "is it
/// categorised" test and fail the product, so `ShippedSoundCollectionTests`
/// renders them and asserts each one is audible and spectrally distinct from
/// the rest, and `ShippedSoundAuditTests` asserts each answers to velocity,
/// stops when released, and sits level with the others.
///
/// Two groups. The **starter thirteen** (increment 003) cover the classic
/// polysynth ground. The **Baroque Modular twelve** are built the way the
/// timbres on *Switched-On Bach* were: saw and narrow-pulse oscillators into a
/// four-pole tracked low-pass, the filter shaped by an envelope and by
/// velocity — the touch-sensitive keyboard Carlos asked Moog for — vibrato
/// from an LFO, formants from the EQ standing in for the fixed filter bank,
/// and one deliberately monophonic lead. `docs/sound-design/switched-on-bach.md`
/// records what is documented about the album and what is inferred.
enum ShippedSounds {
    /// One shipped sound: its identity, where it is filed, and the patch.
    struct Definition: Sendable {
        let id: String
        let category: SoundCategory
        let patch: SynthPatch
    }

    /// Wraps a definition as the library entry the rest of the app sees.
    ///
    /// Shipped entries have no store row, so they have no timestamps and no
    /// revision: within one build they never change, and across builds the app
    /// version is what says which collection you have.
    static func entry(for definition: Definition) -> SoundEntry {
        SoundEntry(
            id: definition.id,
            name: definition.patch.name,
            category: definition.category,
            origin: .shipped,
            shippedOriginID: nil,
            documentVersion: SynthPatch.currentVersion,
            revision: 0,
            createdAt: "",
            updatedAt: "",
            content: .synth(definition.patch)
        )
    }

    /// Eight modulation slots, the leading ones filled from `routes`.
    private static func matrix(
        _ routes: [SynthPatch.ModulationRoute]
    ) -> [SynthPatch.ModulationRoute] {
        precondition(routes.count <= SynthPatch.modulationSlotCount)
        return routes + Array(
            repeating: SynthPatch.ModulationRoute(),
            count: SynthPatch.modulationSlotCount - routes.count
        )
    }

    private static func route(
        _ source: SynthPatch.ModulationSource,
        _ destination: SynthPatch.ModulationDestination,
        _ amount: Double
    ) -> SynthPatch.ModulationRoute {
        SynthPatch.ModulationRoute(source: source, destination: destination, amount: amount)
    }

    /// An oscillator slot that is present but silent. The architecture is fixed
    /// at three, so a two-oscillator sound says so with one of these.
    private static var silent: SynthPatch.Oscillator { SynthPatch.Oscillator(level: 0) }

    static let all: [Definition] = [
        keysDefaultVoice,
        keysGlass,
        padWarmAnalog,
        padBreath,
        bassSub,
        bassReso,
        leadBright,
        leadHollow,
        bellFM,
        bellMusicBox,
        pluckNylon,
        brassSection,
        stringsBowed,
        // Baroque Modular
        keysModularHarpsichord,
        keysSinfoniaOrgan,
        leadBrandenburgViolin,
        leadLadderMono,
        leadWachetReed,
        leadAirFlute,
        brassCantataTrumpet,
        bassContinuo,
        stringsModularCello,
        padChoraleVox,
        bellClankBox,
        pluckPizzicato
    ]

    // MARK: Keys

    /// Increment 002's built-in voice, shipped as a patch (AD7).
    ///
    /// Its identifier stays `builtin.default-voice` — the one SYN001 gave it —
    /// rather than being renamed into a `shipped.` namespace, because that
    /// string is already the app's default sound and renaming it would be a
    /// gratuitous break for no gain.
    static let keysDefaultVoice = Definition(
        id: SynthPatch.defaultVoice.identifier,
        category: .keys,
        patch: SynthPatch.defaultVoice
    )

    static let keysGlass = Definition(
        id: "shipped.glass-keys",
        category: .keys,
        patch: SynthPatch(
            identifier: "shipped.glass-keys",
            name: "Glass Keys",
            oscillators: [
                .init(type: .wavetable, wavetableBank: .harmonic, level: 0.90, shapeAmount: 0.25),
                .init(type: .analog, analogShape: .sine, level: 0.35, detuneSemitones: 12),
                .init(type: .analog, analogShape: .sine, level: 0.12,
                      detuneSemitones: 19.01955, detuneCents: 4)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 5_200, resonance: 0.12, keyTracking: 0.5),
            amplitudeEnvelope: .init(attackSeconds: 0.004, decaySeconds: 0.90,
                                     sustainLevel: 0.25, releaseSeconds: 0.60, curve: 0.7),
            // Audit (2026-09): velocity moved loudness only. A harder key now
            // opens the filter too, so a *forte* is brighter and not merely
            // louder — the touch-sensitive-keyboard behaviour the Baroque
            // Modular group is built on, applied across the collection.
            modulation: matrix([
                route(.velocity, .filterCutoff, 0.25)
            ]),
            chorus: .init(isEnabled: true, rateHertz: 0.5, depthMilliseconds: 3,
                          centreMilliseconds: 11, mix: 0.30, feedback: 0.10),
            reverb: .init(isEnabled: true, roomSize: 0.50, dampening: 0.45,
                          mix: 0.22, preDelaySeconds: 0.015),
            outputLevel: 0.16
        )
    )

    // MARK: Pads

    static let padWarmAnalog = Definition(
        id: "shipped.warm-analog-pad",
        category: .pads,
        patch: SynthPatch(
            identifier: "shipped.warm-analog-pad",
            name: "Warm Analog Pad",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.80,
                      detuneCents: -7, retriggersPhase: false),
                .init(type: .analog, analogShape: .saw, level: 0.80,
                      detuneCents: 9, retriggersPhase: false),
                .init(type: .analog, analogShape: .triangle, level: 0.40,
                      detuneSemitones: -12, retriggersPhase: false)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 1_600, resonance: 0.18, keyTracking: 0.35),
            amplitudeEnvelope: .init(attackSeconds: 0.60, decaySeconds: 1.50,
                                     sustainLevel: 0.75, releaseSeconds: 1.40, curve: 0.4),
            modulationEnvelope: .init(attackSeconds: 0.90, decaySeconds: 2.00,
                                      sustainLevel: 0.50, releaseSeconds: 1.50, curve: 0.5),
            lfos: [
                .init(shape: .triangle, rateHertz: 0.18, retriggersPerNote: false),
                .init(shape: .sine, rateHertz: 4.6, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.lfo1, .filterCutoff, 0.35),
                route(.modulationEnvelope, .filterCutoff, 0.30),
                route(.velocity, .filterCutoff, 0.20)
            ]),
            chorus: .init(isEnabled: true, rateHertz: 0.35, depthMilliseconds: 6,
                          centreMilliseconds: 14, mix: 0.45, feedback: 0.20),
            reverb: .init(isEnabled: true, roomSize: 0.75, dampening: 0.40,
                          mix: 0.32, preDelaySeconds: 0.030),
            // Audit (2026-09): measured 0.038 RMS against a collection median
            // of 0.057; the 4-pole filter at 1.6 kHz takes more out of three
            // saws than the level allowed for.
            outputLevel: 0.17
        )
    )

    static let padBreath = Definition(
        id: "shipped.breath-pad",
        category: .pads,
        patch: SynthPatch(
            identifier: "shipped.breath-pad",
            name: "Breath Pad",
            oscillators: [
                .init(type: .wavetable, wavetableBank: .formant, level: 0.75,
                      shapeAmount: 0.40, retriggersPhase: false),
                .init(type: .wavetable, wavetableBank: .hollow, level: 0.45,
                      detuneSemitones: 7, shapeAmount: 0.60, retriggersPhase: false),
                silent
            ],
            noiseLevel: 0.22,
            // Low enough that the played note's own fundamental is inside the
            // passband. Parked an octave above it, the patch was all breath and
            // no pitch — audibly present, but three times quieter than anything
            // else in the collection.
            filter: .init(isEnabled: true, type: .bandpass, poles: 2,
                          cutoffHertz: 700, resonance: 0.25, keyTracking: 0.60),
            amplitudeEnvelope: .init(attackSeconds: 1.00, decaySeconds: 2.00,
                                     sustainLevel: 0.85, releaseSeconds: 2.20, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 0.12, retriggersPerNote: false),
                .init(shape: .triangle, rateHertz: 0.90, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.lfo1, .filterCutoff, 0.45),
                route(.lfo2, .oscillator1Shape, 0.25)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.90, dampening: 0.30,
                          mix: 0.38, preDelaySeconds: 0.050),
            // A band-passed pad through a wet reverb loses a lot of level on
            // the way out; this is the gain that brings it level with the rest
            // of the collection. Audit (2026-09): still the quietest sound
            // shipped at 0.45 (0.031 RMS against a median of 0.057), so up.
            outputLevel: 0.60
        )
    )

    // MARK: Bass

    static let bassSub = Definition(
        id: "shipped.sub-bass",
        category: .bass,
        patch: SynthPatch(
            identifier: "shipped.sub-bass",
            name: "Sub Bass",
            oscillators: [
                .init(type: .analog, analogShape: .sine, level: 1.00, detuneSemitones: -12),
                .init(type: .analog, analogShape: .square, level: 0.25, shapeAmount: 0.5),
                .init(type: .analog, analogShape: .triangle, level: 0.15,
                      detuneSemitones: -12, detuneCents: 6)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 420, resonance: 0.15, keyTracking: 0.80),
            amplitudeEnvelope: .init(attackSeconds: 0.004, decaySeconds: 0.25,
                                     sustainLevel: 0.85, releaseSeconds: 0.14, curve: 0.3),
            equalizer: .init(isEnabled: true, lowGainDecibels: 4, lowHertz: 90,
                             midGainDecibels: -2, midHertz: 500, midQ: 1.0,
                             highGainDecibels: -6, highHertz: 4_000),
            // A bass line is monophonic in practice; 32 voices of sub would be
            // 32 voices of mud, and the ceiling says so.
            maximumVoices: 8,
            // Backed off from the 0.18 it was written at: a sine-heavy bass
            // peaks efficiently, and at 0.18 an eight-note fortissimo chord sat
            // on the limiter at 0.996. Squashing a shipped sound by default is
            // not a headroom policy.
            outputLevel: 0.15
        )
    )

    static let bassReso = Definition(
        id: "shipped.reso-bass",
        category: .bass,
        patch: SynthPatch(
            identifier: "shipped.reso-bass",
            name: "Reso Bass",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.90),
                .init(type: .analog, analogShape: .pulse, level: 0.50,
                      detuneCents: -6, shapeAmount: 0.30),
                .init(type: .analog, analogShape: .sine, level: 0.40, detuneSemitones: -12)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 300, resonance: 0.80, keyTracking: 0.40),
            amplitudeEnvelope: .init(attackSeconds: 0.003, decaySeconds: 0.40,
                                     sustainLevel: 0.55, releaseSeconds: 0.16, curve: 0.4),
            modulationEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.35,
                                      sustainLevel: 0.05, releaseSeconds: 0.25, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.55),
                route(.velocity, .filterCutoff, 0.25)
            ]),
            maximumVoices: 8,
            outputLevel: 0.14
        )
    )

    // MARK: Leads

    static let leadBright = Definition(
        id: "shipped.bright-lead",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.bright-lead",
            name: "Bright Lead",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.90),
                .init(type: .analog, analogShape: .saw, level: 0.70, detuneCents: 12),
                .init(type: .analog, analogShape: .square, level: 0.25, detuneSemitones: 12)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 4_200, resonance: 0.30, keyTracking: 0.70),
            amplitudeEnvelope: .init(attackSeconds: 0.006, decaySeconds: 0.30,
                                     sustainLevel: 0.70, releaseSeconds: 0.28, curve: 0.3),
            modulationEnvelope: .init(attackSeconds: 0.004, decaySeconds: 0.45,
                                      sustainLevel: 0.10, releaseSeconds: 0.30, curve: 1.0),
            lfos: [
                .init(shape: .sine, rateHertz: 5.2, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.40, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.lfo1, .oscillator1Pitch, 0.03),
                route(.modulationEnvelope, .filterCutoff, 0.25),
                route(.velocity, .filterCutoff, 0.25)
            ]),
            // Audit (2026-09): a 260 ms echo at 0.30 feedback rang 1.35 s past
            // the release. Tempo-unrelated repeats behind a fugue voice are
            // heard as wrong notes; kept as a hint of space, not a rhythm.
            delay: .init(isEnabled: true, timeSeconds: 0.26, feedback: 0.18,
                         mix: 0.12, dampening: 0.50),
            maximumVoices: 6,
            outputLevel: 0.15
        )
    )

    static let leadHollow = Definition(
        id: "shipped.hollow-lead",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.hollow-lead",
            name: "Hollow Lead",
            oscillators: [
                // Far enough into the bank that the odd-harmonic frames are the
                // ones being heard; near the bottom it is barely a sine, which
                // is not what "hollow" is supposed to mean.
                .init(type: .wavetable, wavetableBank: .hollow, level: 0.95, shapeAmount: 0.55),
                .init(type: .analog, analogShape: .pulse, level: 0.45,
                      detuneSemitones: 7, shapeAmount: 0.50),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 3_400, resonance: 0.25, keyTracking: 0.60),
            amplitudeEnvelope: .init(attackSeconds: 0.020, decaySeconds: 0.50,
                                     sustainLevel: 0.65, releaseSeconds: 0.35, curve: 0.2),
            lfos: [
                .init(shape: .triangle, rateHertz: 0.70, retriggersPerNote: false),
                .init(shape: .sine, rateHertz: 5.8, retriggersPerNote: true)
            ],
            modulation: matrix([
                route(.lfo1, .oscillator2Shape, 0.40),
                route(.lfo1, .oscillator1Shape, 0.30),
                route(.velocity, .filterCutoff, 0.25)
            ]),
            // Audit (2026-09): the longest tail in the collection, 2.35 s after
            // release, all of it this delay. See Bright Lead.
            delay: .init(isEnabled: true, timeSeconds: 0.375, feedback: 0.18,
                         mix: 0.12, dampening: 0.55),
            maximumVoices: 6,
            // Less of the signal in the delay's wet mix means more of it dry,
            // which made this the second-loudest sound shipped; trimmed back.
            outputLevel: 0.12
        )
    )

    // MARK: Bells

    static let bellFM = Definition(
        id: "shipped.fm-bell",
        category: .bells,
        patch: SynthPatch(
            identifier: "shipped.fm-bell",
            name: "FM Bell",
            oscillators: [
                .init(type: .frequencyModulation, level: 1.00,
                      shapeAmount: 0.55, frequencyModulationRatio: 3.5),
                .init(type: .analog, analogShape: .sine, level: 0.30,
                      detuneSemitones: 12, detuneCents: 3),
                silent
            ],
            amplitudeEnvelope: .init(attackSeconds: 0.002, decaySeconds: 2.40,
                                     sustainLevel: 0.0, releaseSeconds: 1.80, curve: 1.0),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.60,
                                      sustainLevel: 0.0, releaseSeconds: 0.50, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .oscillator1Shape, 0.45)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.70, dampening: 0.35,
                          mix: 0.30, preDelaySeconds: 0.020),
            outputLevel: 0.15
        )
    )

    static let bellMusicBox = Definition(
        id: "shipped.music-box",
        category: .bells,
        patch: SynthPatch(
            identifier: "shipped.music-box",
            name: "Music Box",
            oscillators: [
                .init(type: .frequencyModulation, level: 1.00,
                      shapeAmount: 0.35, frequencyModulationRatio: 7.0),
                .init(type: .analog, analogShape: .triangle, level: 0.35, detuneSemitones: 12),
                silent
            ],
            filter: .init(isEnabled: true, type: .highpass, poles: 2,
                          cutoffHertz: 300, resonance: 0.10, keyTracking: 0.30),
            amplitudeEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.90,
                                     sustainLevel: 0.0, releaseSeconds: 0.70, curve: 1.0),
            reverb: .init(isEnabled: true, roomSize: 0.45, dampening: 0.60,
                          mix: 0.25, preDelaySeconds: 0.010),
            outputLevel: 0.16
        )
    )

    // MARK: Plucks

    static let pluckNylon = Definition(
        id: "shipped.nylon-pluck",
        category: .plucks,
        patch: SynthPatch(
            identifier: "shipped.nylon-pluck",
            name: "Nylon Pluck",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.85),
                .init(type: .analog, analogShape: .triangle, level: 0.40, detuneCents: 5),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 1_200, resonance: 0.30, keyTracking: 0.70),
            amplitudeEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.75,
                                     sustainLevel: 0.0, releaseSeconds: 0.35, curve: 0.9),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.18,
                                      sustainLevel: 0.0, releaseSeconds: 0.15, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.60),
                route(.velocity, .filterCutoff, 0.30)
            ]),
            delay: .init(isEnabled: true, timeSeconds: 0.19, feedback: 0.22,
                         mix: 0.16, dampening: 0.60),
            outputLevel: 0.17
        )
    )

    // MARK: Brass

    static let brassSection = Definition(
        id: "shipped.brass-section",
        category: .brass,
        patch: SynthPatch(
            identifier: "shipped.brass-section",
            name: "Brass Section",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.90),
                .init(type: .analog, analogShape: .saw, level: 0.75, detuneCents: -8),
                .init(type: .analog, analogShape: .saw, level: 0.50,
                      detuneSemitones: 12, detuneCents: 6)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 1_500, resonance: 0.22, keyTracking: 0.60),
            amplitudeEnvelope: .init(attackSeconds: 0.050, decaySeconds: 0.40,
                                     sustainLevel: 0.80, releaseSeconds: 0.30, curve: 0.2),
            // The brass swell: the filter opens a little after the note starts,
            // which is what makes this read as brass rather than as a saw pad.
            modulationEnvelope: .init(attackSeconds: 0.090, decaySeconds: 0.50,
                                      sustainLevel: 0.45, releaseSeconds: 0.30, curve: 0.4),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.50),
                route(.velocity, .filterCutoff, 0.30)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: -3, lowHertz: 150,
                             midGainDecibels: 5, midHertz: 1_400, midQ: 1.2,
                             highGainDecibels: 2, highHertz: 5_000),
            reverb: .init(isEnabled: true, roomSize: 0.50, dampening: 0.50,
                          mix: 0.18, preDelaySeconds: 0.020),
            outputLevel: 0.14
        )
    )

    // MARK: Strings

    static let stringsBowed = Definition(
        id: "shipped.bowed-strings",
        category: .strings,
        patch: SynthPatch(
            identifier: "shipped.bowed-strings",
            name: "Bowed Strings",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.80, retriggersPhase: false),
                .init(type: .analog, analogShape: .saw, level: 0.70,
                      detuneCents: 11, retriggersPhase: false),
                .init(type: .analog, analogShape: .saw, level: 0.55,
                      detuneSemitones: -12, detuneCents: -9, retriggersPhase: false)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 2_400, resonance: 0.15, keyTracking: 0.50),
            amplitudeEnvelope: .init(attackSeconds: 0.25, decaySeconds: 0.80,
                                     sustainLevel: 0.80, releaseSeconds: 0.70, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 5.4, retriggersPerNote: true),
                .init(shape: .triangle, rateHertz: 0.25, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.lfo1, .oscillator1Pitch, 0.025),
                route(.lfo1, .oscillator2Pitch, 0.020),
                route(.lfo2, .filterCutoff, 0.15),
                route(.velocity, .filterCutoff, 0.30)
            ]),
            chorus: .init(isEnabled: true, rateHertz: 0.45, depthMilliseconds: 5,
                          centreMilliseconds: 13, mix: 0.35, feedback: 0.15),
            reverb: .init(isEnabled: true, roomSize: 0.68, dampening: 0.45,
                          mix: 0.30, preDelaySeconds: 0.025),
            // Audit (2026-09): 0.035 RMS against a median of 0.057 — the
            // second-quietest sound shipped, on the line a score gives most
            // often. Up.
            outputLevel: 0.20
        )
    )

    // MARK: - Baroque Modular

    /// The twelve sounds built the way *Switched-On Bach*'s were. See the file
    /// comment and `docs/sound-design/switched-on-bach.md`.
    ///
    /// Two conventions run through all of them. **Velocity reaches the filter**
    /// as well as the amplitude, because Carlos's touch-sensitive keyboard
    /// made a harder note brighter and that is where the record's phrasing
    /// lives. **Vibrato is a retriggered LFO on oscillator pitch at about a
    /// quarter-tone peak** (0.010–0.012 of the ±24-semitone range), which is
    /// what a hand on a 901's frequency knob produced; there is no delayed
    /// vibrato in this architecture, so the amounts are kept modest enough to
    /// live on every note.

    /// Narrow pulse into a tracked four-pole filter, with a filter click on
    /// the attack and an immediate decay — the harpsichord-like registration
    /// the Inventions and the WTC preludes were played on.
    static let keysModularHarpsichord = Definition(
        id: "shipped.modular-harpsichord",
        category: .keys,
        patch: SynthPatch(
            identifier: "shipped.modular-harpsichord",
            name: "Modular Harpsichord",
            oscillators: [
                .init(type: .analog, analogShape: .pulse, level: 0.90, shapeAmount: 0.12),
                .init(type: .analog, analogShape: .saw, level: 0.35, detuneSemitones: 12),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 2_600, resonance: 0.15, keyTracking: 0.70),
            amplitudeEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.55,
                                     sustainLevel: 0.12, releaseSeconds: 0.08, curve: 0.9),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.12,
                                      sustainLevel: 0.0, releaseSeconds: 0.05, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.45),
                route(.velocity, .filterCutoff, 0.25)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.35, dampening: 0.60,
                          mix: 0.14, preDelaySeconds: 0.010),
            maximumVoices: 16,
            // A 1 ms attack into a 0.55 s decay spends little time loud; this
            // is what puts its loudest moment level with the sustained sounds.
            outputLevel: 0.30,
            // A plectrum barely knows how hard the key went down; the touch
            // keyboard still let a little through.
            velocitySensitivity: 1.2
        )
    )

    /// Three ranks — square, pulse at the octave, sine an octave below — with
    /// a flat envelope and a church behind it. Cantata 29, *Wachet auf*, the
    /// chorale textures. A slow LFO nudges the octave rank by a few cents, the
    /// tuning drift every take had to be checked for.
    static let keysSinfoniaOrgan = Definition(
        id: "shipped.sinfonia-organ",
        category: .keys,
        patch: SynthPatch(
            identifier: "shipped.sinfonia-organ",
            name: "Sinfonia Organ",
            oscillators: [
                .init(type: .analog, analogShape: .square, level: 0.70, shapeAmount: 0.5),
                .init(type: .analog, analogShape: .pulse, level: 0.50,
                      detuneSemitones: 12, detuneCents: 3, shapeAmount: 0.30),
                .init(type: .analog, analogShape: .sine, level: 0.60, detuneSemitones: -12)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 4_500, resonance: 0.05, keyTracking: 0.50),
            amplitudeEnvelope: .init(attackSeconds: 0.012, decaySeconds: 0.10,
                                     sustainLevel: 1.0, releaseSeconds: 0.06, curve: 0),
            lfos: [
                .init(shape: .triangle, rateHertz: 0.30, retriggersPerNote: false),
                .init(shape: .sine, rateHertz: 5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.lfo1, .oscillator2Pitch, 0.003),
                route(.velocity, .filterCutoff, 0.15)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: 0, lowHertz: 100,
                             midGainDecibels: 2, midHertz: 1_800, midQ: 1.0,
                             highGainDecibels: 0, highHertz: 6_000),
            reverb: .init(isEnabled: true, roomSize: 0.60, dampening: 0.50,
                          mix: 0.22, preDelaySeconds: 0.020),
            maximumVoices: 24,
            outputLevel: 0.11,
            // An organ has no touch, and the album's organ-like lines were the
            // most evenly played on it; enough sensitivity to keep a hairpin.
            velocitySensitivity: 0.7
        )
    )

    /// Two saws a few cents apart with a pulse an octave up for edge, a
    /// four-pole filter that swells under a bow-pressure envelope, vibrato,
    /// and a body resonance from the EQ. The Brandenburg upper lines, the Air.
    static let leadBrandenburgViolin = Definition(
        id: "shipped.brandenburg-violin",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.brandenburg-violin",
            name: "Brandenburg Violin",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.85),
                .init(type: .analog, analogShape: .saw, level: 0.60, detuneCents: 7),
                .init(type: .analog, analogShape: .pulse, level: 0.18,
                      detuneSemitones: 12, shapeAmount: 0.35)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 2_200, resonance: 0.22, keyTracking: 0.65),
            amplitudeEnvelope: .init(attackSeconds: 0.070, decaySeconds: 0.35,
                                     sustainLevel: 0.85, releaseSeconds: 0.18, curve: 0.3),
            modulationEnvelope: .init(attackSeconds: 0.15, decaySeconds: 0.60,
                                      sustainLevel: 0.60, releaseSeconds: 0.20, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 5.6, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.20),
                route(.lfo1, .oscillator1Pitch, 0.011),
                route(.lfo1, .oscillator2Pitch, 0.011),
                route(.velocity, .filterCutoff, 0.35)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: -2, lowHertz: 180,
                             midGainDecibels: 3, midHertz: 2_600, midQ: 1.4,
                             highGainDecibels: 0, highHertz: 8_000),
            reverb: .init(isEnabled: true, roomSize: 0.45, dampening: 0.50,
                          mix: 0.16, preDelaySeconds: 0.015),
            maximumVoices: 6,
            outputLevel: 0.13
        )
    )

    /// One saw and its sub-octave into a resonant four-pole filter under a
    /// fast envelope — the fuzzy, buzzing solo line — and **one voice**, which
    /// is the constraint the whole album was played under: the note has to
    /// end before the next can begin. A chord played on this steals.
    static let leadLadderMono = Definition(
        id: "shipped.ladder-mono-lead",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.ladder-mono-lead",
            name: "Ladder Mono Lead",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 1.00),
                .init(type: .analog, analogShape: .saw, level: 0.50,
                      detuneSemitones: -12, detuneCents: -4),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 900, resonance: 0.55, keyTracking: 0.50),
            amplitudeEnvelope: .init(attackSeconds: 0.005, decaySeconds: 0.20,
                                     sustainLevel: 0.80, releaseSeconds: 0.12, curve: 0.5),
            modulationEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.50,
                                      sustainLevel: 0.25, releaseSeconds: 0.20, curve: 1.0),
            lfos: [
                .init(shape: .sine, rateHertz: 5.0, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.50),
                route(.velocity, .filterCutoff, 0.30),
                route(.lfo1, .oscillator1Pitch, 0.008)
            ]),
            maximumVoices: 1,
            outputLevel: 0.16
        )
    )

    /// Two narrow pulses with a formant peak from the EQ standing in for the
    /// fixed filter bank: the nasal oboe- and bassoon-like lines of
    /// *Wachet auf* and the Inventions.
    static let leadWachetReed = Definition(
        id: "shipped.wachet-reed",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.wachet-reed",
            name: "Wachet Reed",
            oscillators: [
                .init(type: .analog, analogShape: .pulse, level: 0.90, shapeAmount: 0.10),
                .init(type: .analog, analogShape: .pulse, level: 0.40,
                      detuneCents: -5, shapeAmount: 0.18),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 3_200, resonance: 0.30, keyTracking: 0.60),
            amplitudeEnvelope: .init(attackSeconds: 0.035, decaySeconds: 0.30,
                                     sustainLevel: 0.80, releaseSeconds: 0.14, curve: 0.3),
            modulationEnvelope: .init(attackSeconds: 0.020, decaySeconds: 0.25,
                                      sustainLevel: 0.50, releaseSeconds: 0.15, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 5.2, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.15),
                route(.velocity, .filterCutoff, 0.30),
                route(.lfo1, .oscillator1Pitch, 0.009),
                route(.lfo1, .oscillator2Pitch, 0.009)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: -4, lowHertz: 150,
                             midGainDecibels: 5, midHertz: 1_500, midQ: 2.5,
                             highGainDecibels: -2, highHertz: 6_000),
            reverb: .init(isEnabled: true, roomSize: 0.40, dampening: 0.55,
                          mix: 0.14, preDelaySeconds: 0.012),
            maximumVoices: 4,
            // Two narrow pulses carry little energy; the formant EQ takes more.
            outputLevel: 0.21
        )
    )

    /// Triangle and a sine at the octave with a breath of noise, a pitch
    /// chirp and a filter puff on the attack, and a vibrato that moves the
    /// loudness as much as the pitch — the hollow flute and recorder tones.
    static let leadAirFlute = Definition(
        id: "shipped.air-flute",
        category: .leads,
        patch: SynthPatch(
            identifier: "shipped.air-flute",
            name: "Air Flute",
            oscillators: [
                .init(type: .analog, analogShape: .triangle, level: 0.90),
                .init(type: .analog, analogShape: .sine, level: 0.45, detuneSemitones: 12),
                silent
            ],
            noiseLevel: 0.06,
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 2_800, resonance: 0.15, keyTracking: 0.70),
            amplitudeEnvelope: .init(attackSeconds: 0.045, decaySeconds: 0.30,
                                     sustainLevel: 0.85, releaseSeconds: 0.16, curve: 0.3),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.06,
                                      sustainLevel: 0.0, releaseSeconds: 0.05, curve: 1.0),
            lfos: [
                .init(shape: .sine, rateHertz: 4.8, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .oscillator1Pitch, 0.020),
                route(.modulationEnvelope, .filterCutoff, 0.25),
                route(.lfo1, .oscillator1Pitch, 0.008),
                route(.lfo1, .amplitude, 0.08),
                route(.velocity, .filterCutoff, 0.30)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.55, dampening: 0.40,
                          mix: 0.20, preDelaySeconds: 0.015),
            maximumVoices: 4,
            outputLevel: 0.16
        )
    )

    /// Saw with a pulse for bite into a tracked four-pole filter, the brass
    /// "blip" from an envelope that opens the filter just after the note
    /// starts, and a lot of velocity into the cutoff: a *forte* is a bright
    /// trumpet and a *piano* is a soft one. Cantata 29's opening line.
    static let brassCantataTrumpet = Definition(
        id: "shipped.cantata-trumpet",
        category: .brass,
        patch: SynthPatch(
            identifier: "shipped.cantata-trumpet",
            name: "Cantata Trumpet",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.95),
                .init(type: .analog, analogShape: .pulse, level: 0.40,
                      detuneCents: 4, shapeAmount: 0.30),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 1_500, resonance: 0.30, keyTracking: 0.75),
            amplitudeEnvelope: .init(attackSeconds: 0.030, decaySeconds: 0.25,
                                     sustainLevel: 0.85, releaseSeconds: 0.14, curve: 0.2),
            modulationEnvelope: .init(attackSeconds: 0.060, decaySeconds: 0.35,
                                      sustainLevel: 0.55, releaseSeconds: 0.15, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 5.4, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.40),
                route(.velocity, .filterCutoff, 0.45),
                route(.lfo1, .oscillator1Pitch, 0.006)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: -2, lowHertz: 200,
                             midGainDecibels: 4, midHertz: 2_200, midQ: 1.5,
                             highGainDecibels: 1, highHertz: 6_000),
            reverb: .init(isEnabled: true, roomSize: 0.50, dampening: 0.50,
                          mix: 0.16, preDelaySeconds: 0.015),
            maximumVoices: 4,
            outputLevel: 0.13
        )
    )

    /// Saw with a square an octave down into a heavily tracked four-pole
    /// filter, a short filter envelope for the front of each note, three
    /// voices: the continuo line under everything.
    static let bassContinuo = Definition(
        id: "shipped.continuo-bass",
        category: .bass,
        patch: SynthPatch(
            identifier: "shipped.continuo-bass",
            name: "Continuo Bass",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.90),
                .init(type: .analog, analogShape: .square, level: 0.45,
                      detuneSemitones: -12, shapeAmount: 0.5),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 520, resonance: 0.30, keyTracking: 0.90),
            amplitudeEnvelope: .init(attackSeconds: 0.004, decaySeconds: 0.30,
                                     sustainLevel: 0.70, releaseSeconds: 0.10, curve: 0.4),
            modulationEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.22,
                                      sustainLevel: 0.15, releaseSeconds: 0.10, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.35),
                route(.velocity, .filterCutoff, 0.30)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: 2, lowHertz: 80,
                             midGainDecibels: -1, midHertz: 400, midQ: 1.0,
                             highGainDecibels: -4, highHertz: 4_000),
            maximumVoices: 3,
            outputLevel: 0.14
        )
    )

    /// Saw and a wide pulse, free-running so repeated notes differ, a slower
    /// bow than the violin, vibrato, a body peak low in the EQ. The cello and
    /// viola lines of the Brandenburg.
    static let stringsModularCello = Definition(
        id: "shipped.modular-cello",
        category: .strings,
        patch: SynthPatch(
            identifier: "shipped.modular-cello",
            name: "Modular Cello",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.85, retriggersPhase: false),
                .init(type: .analog, analogShape: .pulse, level: 0.50,
                      detuneCents: 6, shapeAmount: 0.42, retriggersPhase: false),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 1_300, resonance: 0.20, keyTracking: 0.70),
            amplitudeEnvelope: .init(attackSeconds: 0.11, decaySeconds: 0.40,
                                     sustainLevel: 0.85, releaseSeconds: 0.28, curve: 0.3),
            modulationEnvelope: .init(attackSeconds: 0.20, decaySeconds: 0.50,
                                      sustainLevel: 0.60, releaseSeconds: 0.25, curve: 0.3),
            lfos: [
                .init(shape: .sine, rateHertz: 5.0, retriggersPerNote: true),
                .init(shape: .sine, rateHertz: 0.5, retriggersPerNote: false)
            ],
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.18),
                route(.lfo1, .oscillator1Pitch, 0.012),
                route(.lfo1, .oscillator2Pitch, 0.012),
                route(.velocity, .filterCutoff, 0.35)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: 0, lowHertz: 100,
                             midGainDecibels: 3, midHertz: 500, midQ: 1.2,
                             highGainDecibels: -1, highHertz: 6_000),
            reverb: .init(isEnabled: true, roomSize: 0.50, dampening: 0.50,
                          mix: 0.18, preDelaySeconds: 0.020),
            maximumVoices: 4,
            outputLevel: 0.15
        )
    )

    /// The formant wavetable with a pulse beneath it, the vowel drifting under
    /// a slow LFO, a light vibrato, and a formant peak in the EQ: a sustained
    /// chorale texture for the lines the album doubled with a "voice".
    static let padChoraleVox = Definition(
        id: "shipped.chorale-vox",
        category: .pads,
        patch: SynthPatch(
            identifier: "shipped.chorale-vox",
            name: "Chorale Vox",
            oscillators: [
                .init(type: .wavetable, wavetableBank: .formant, level: 0.80,
                      shapeAmount: 0.30, retriggersPhase: false),
                .init(type: .analog, analogShape: .pulse, level: 0.50,
                      detuneCents: -6, shapeAmount: 0.35, retriggersPhase: false),
                .init(type: .analog, analogShape: .sine, level: 0.30, detuneSemitones: -12)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2,
                          cutoffHertz: 2_400, resonance: 0.20, keyTracking: 0.50),
            amplitudeEnvelope: .init(attackSeconds: 0.22, decaySeconds: 0.60,
                                     sustainLevel: 0.85, releaseSeconds: 0.45, curve: 0.3),
            lfos: [
                .init(shape: .triangle, rateHertz: 0.15, retriggersPerNote: false),
                .init(shape: .sine, rateHertz: 5.3, retriggersPerNote: true)
            ],
            modulation: matrix([
                route(.lfo1, .oscillator1Shape, 0.25),
                route(.lfo2, .oscillator1Pitch, 0.006),
                route(.lfo2, .oscillator2Pitch, 0.006),
                route(.velocity, .filterCutoff, 0.25)
            ]),
            equalizer: .init(isEnabled: true, lowGainDecibels: 0, lowHertz: 100,
                             midGainDecibels: 4, midHertz: 1_000, midQ: 2.0,
                             highGainDecibels: 0, highHertz: 6_000),
            reverb: .init(isEnabled: true, roomSize: 0.70, dampening: 0.45,
                          mix: 0.28, preDelaySeconds: 0.030),
            maximumVoices: 12,
            outputLevel: 0.20
        )
    )

    /// Two FM operators at inharmonic ratios — the nearest this architecture
    /// has to a ring modulator — struck bright and decaying dull, harder
    /// strikes brighter. The "intergalactic music box" the reviewers heard.
    static let bellClankBox = Definition(
        id: "shipped.clank-box",
        category: .bells,
        patch: SynthPatch(
            identifier: "shipped.clank-box",
            name: "Clank Box",
            oscillators: [
                .init(type: .frequencyModulation, level: 1.00,
                      shapeAmount: 0.50, frequencyModulationRatio: 2.76),
                .init(type: .frequencyModulation, level: 0.40, detuneSemitones: 12,
                      shapeAmount: 0.30, frequencyModulationRatio: 1.41),
                silent
            ],
            filter: .init(isEnabled: true, type: .highpass, poles: 2,
                          cutoffHertz: 200, resonance: 0.05, keyTracking: 0.20),
            amplitudeEnvelope: .init(attackSeconds: 0.001, decaySeconds: 1.20,
                                     sustainLevel: 0.0, releaseSeconds: 0.60, curve: 1.0),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.35,
                                      sustainLevel: 0.0, releaseSeconds: 0.30, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .oscillator1Shape, 0.50),
                route(.modulationEnvelope, .oscillator2Shape, 0.40),
                route(.velocity, .oscillator1Shape, 0.30)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.50, dampening: 0.50,
                          mix: 0.22, preDelaySeconds: 0.015),
            outputLevel: 0.14
        )
    )

    /// A pulse and a triangle into a heavily tracked four-pole filter under a
    /// fast filter envelope, no sustain: pizzicato, and the detached bass
    /// figures the one-note-at-a-time keyboard made of everything.
    static let pluckPizzicato = Definition(
        id: "shipped.pizzicato-pulse",
        category: .plucks,
        patch: SynthPatch(
            identifier: "shipped.pizzicato-pulse",
            name: "Pizzicato Pulse",
            oscillators: [
                .init(type: .analog, analogShape: .pulse, level: 0.90, shapeAmount: 0.25),
                .init(type: .analog, analogShape: .triangle, level: 0.40, detuneCents: 4),
                silent
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 800, resonance: 0.25, keyTracking: 0.80),
            amplitudeEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.28,
                                     sustainLevel: 0.0, releaseSeconds: 0.06, curve: 1.0),
            modulationEnvelope: .init(attackSeconds: 0.001, decaySeconds: 0.10,
                                      sustainLevel: 0.0, releaseSeconds: 0.05, curve: 1.0),
            modulation: matrix([
                route(.modulationEnvelope, .filterCutoff, 0.55),
                route(.velocity, .filterCutoff, 0.35)
            ]),
            reverb: .init(isEnabled: true, roomSize: 0.40, dampening: 0.60,
                          mix: 0.12, preDelaySeconds: 0.010),
            maximumVoices: 12,
            outputLevel: 0.30
        )
    )
}
