import XCTest
@testable import SynthKit

/// Issue #17: "Offline-render tests demonstrate each oscillator type, filter
/// modulation via the mod matrix, envelope shaping, and each effect
/// audibly/measurably active."
///
/// Every assertion here is a measurement of rendered audio, not of a parameter
/// struct. Setting `analogShape = .square` and then checking that the patch
/// says `.square` would prove nothing about what anyone hears; what these
/// tests do instead is render the note and ask the buffer which harmonics are
/// in it.
///
/// The measurements are single-bin Goertzel probes at harmonics of the played
/// note (`AudioRenderFixtures.harmonicEnergies`) and windowed RMS
/// (`AudioRenderFixtures.rms(_:from:to:sampleRate:)`), because the questions
/// are "how much of this partial is present?" and "is there energy here yet?"
/// and those answer exactly that.
///
/// Voices are driven through the line-voice vtable directly — see
/// `SynthVoiceHarness` for why. Whole-pipeline claims are in
/// `SynthEngineIntegrationTests`.
final class SynthEngineRenderTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let note = 69                       // A4
    private var fundamental: Double { AudioRenderFixtures.frequency(ofMIDINote: note) }

    /// Harmonic energies of a sustained note, normalised so the fundamental is
    /// 1. Measured across a window that starts after the attack and ends
    /// before the release, so the envelope is flat throughout.
    private func harmonics(
        of patch: SynthPatch, count: Int = 6, midiNoteNumber: Int? = nil
    ) -> [Double] {
        let played = midiNoteNumber ?? note
        let samples = SynthVoiceHarness.renderNote(
            patch: patch, midiNoteNumber: played, holdSeconds: 1.0, sampleRate: sampleRate
        )
        let steady = Array(samples[Int(0.2 * sampleRate)..<Int(0.9 * sampleRate)])
        let energies = AudioRenderFixtures.harmonicEnergies(
            steady,
            fundamental: AudioRenderFixtures.frequency(ofMIDINote: played),
            count: count,
            sampleRate: sampleRate
        )
        let reference = max(energies[0], 1e-12)
        return energies.map { $0 / reference }
    }

    private func analog(_ shape: SynthPatch.AnalogShape, width: Double = 0.5) -> SynthPatch {
        .singleOscillator(
            .init(type: .analog, analogShape: shape, level: 1, shapeAmount: width),
            name: shape.rawValue
        )
    }

    // MARK: Analog oscillators

    /// The classic waveforms have the harmonic series the textbook says they
    /// do, to within a few percent.
    ///
    /// Asserting the *ratios* rather than "the spectrum is different from a
    /// sine" is the difference between proving the oscillator is a saw and
    /// proving it is not silent. A saw's nth harmonic is 1/n; a square's and a
    /// triangle's have no even harmonics at all, and fall off as 1/n and 1/n²
    /// respectively.
    func testAnalogWaveformsHaveTheirTextbookHarmonicSeries() {
        let sine = harmonics(of: analog(.sine))
        for index in 1..<sine.count {
            XCTAssertLessThan(
                sine[index], 0.01,
                "The sine oscillator has energy at harmonic \(index + 1); it should have none."
            )
        }

        let saw = harmonics(of: analog(.saw))
        for index in 1..<saw.count {
            let expected = 1.0 / Double(index + 1)
            XCTAssertEqual(
                saw[index], expected, accuracy: expected * 0.05,
                "Saw harmonic \(index + 1) is \(saw[index]), not 1/\(index + 1)."
            )
        }

        let square = harmonics(of: analog(.square))
        for index in stride(from: 1, to: square.count, by: 2) {
            XCTAssertLessThan(
                square[index], 0.01,
                "The square oscillator has an even harmonic at \(index + 1)."
            )
        }
        for index in stride(from: 2, to: square.count, by: 2) {
            let expected = 1.0 / Double(index + 1)
            XCTAssertEqual(square[index], expected, accuracy: expected * 0.05)
        }

        let triangle = harmonics(of: analog(.triangle))
        for index in stride(from: 1, to: triangle.count, by: 2) {
            XCTAssertLessThan(triangle[index], 0.01, "The triangle has an even harmonic.")
        }
        for index in stride(from: 2, to: triangle.count, by: 2) {
            let harmonic = Double(index + 1)
            let expected = 1.0 / (harmonic * harmonic)
            XCTAssertEqual(triangle[index], expected, accuracy: expected * 0.08)
        }
    }

    /// A pulse at 50% width is a square; away from 50% the even harmonics come
    /// back. That is what pulse width *is*, and it is what makes a PWM sweep
    /// through the mod matrix audible.
    func testPulseWidthControlsTheEvenHarmonics() {
        let square = harmonics(of: analog(.pulse, width: 0.5))
        XCTAssertLessThan(square[1], 0.01, "A 50% pulse should have no second harmonic.")

        let narrow = harmonics(of: analog(.pulse, width: 0.1))
        XCTAssertGreaterThan(
            narrow[1], 0.5,
            "A narrow pulse should have a strong second harmonic; it measured \(narrow[1])."
        )
    }

    // MARK: Wavetable oscillator

    /// The wavetable position is a continuous morph, not a switch: sweeping it
    /// across the harmonic bank monotonically increases how much energy sits
    /// above the second harmonic.
    func testWavetablePositionSweepsBrightnessContinuously() {
        func brightness(_ position: Double) -> Double {
            let patch = SynthPatch.singleOscillator(
                .init(type: .wavetable, wavetableBank: .harmonic, level: 1, shapeAmount: position),
                name: "wavetable"
            )
            let energies = harmonics(of: patch, count: 8)
            return energies[2...].reduce(0, +)
        }

        let dark = brightness(0)
        let middle = brightness(0.5)
        let bright = brightness(1)

        XCTAssertLessThan(dark, middle, "Position 0.5 is no brighter than position 0.")
        XCTAssertLessThan(middle, bright, "Position 1 is no brighter than position 0.5.")
        XCTAssertGreaterThan(
            bright / max(dark, 1e-12), 10,
            "The whole position sweep changed brightness by less than 10×; it is barely a morph."
        )
    }

    /// The four banks are genuinely different spectra rather than four names
    /// for one table.
    func testEachWavetableBankHasItsOwnSpectrum() {
        var spectra: [SynthPatch.WavetableBank: [Double]] = [:]
        for bank in SynthPatch.WavetableBank.allCases {
            let patch = SynthPatch.singleOscillator(
                .init(type: .wavetable, wavetableBank: bank, level: 1, shapeAmount: 0.6),
                name: bank.rawValue
            )
            spectra[bank] = harmonics(of: patch, count: 10)
        }

        // The hollow bank is odd-harmonic by construction; the others are not.
        let hollow = try! XCTUnwrap(spectra[.hollow])
        for index in stride(from: 1, to: hollow.count, by: 2) {
            XCTAssertLessThan(hollow[index], 0.01, "The hollow bank has an even harmonic.")
        }

        for (first, second) in [
            (SynthPatch.WavetableBank.harmonic, SynthPatch.WavetableBank.formant),
            (.harmonic, .metallic), (.harmonic, .hollow),
            (.formant, .metallic), (.formant, .hollow), (.metallic, .hollow)
        ] {
            let a = try! XCTUnwrap(spectra[first])
            let b = try! XCTUnwrap(spectra[second])
            let distance = zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
            XCTAssertGreaterThan(
                distance, 0.2,
                "The \(first.rawValue) and \(second.rawValue) banks have near-identical spectra "
                    + "(total harmonic difference \(distance)); they are not distinct sounds."
            )
        }
    }

    // MARK: FM oscillator

    /// FM depth is what makes an FM operator an FM operator: at depth zero it
    /// is a sine, and raising it puts energy in sidebands the carrier alone
    /// cannot produce.
    func testFrequencyModulationDepthCreatesSidebands() {
        func fm(depth: Double, ratio: Double = 1) -> SynthPatch {
            .singleOscillator(
                .init(type: .frequencyModulation, level: 1, shapeAmount: depth,
                      frequencyModulationRatio: ratio),
                name: "fm"
            )
        }

        let silentModulator = harmonics(of: fm(depth: 0))
        for index in 1..<silentModulator.count {
            XCTAssertLessThan(
                silentModulator[index], 0.01,
                "At zero depth the FM oscillator should be exactly a sine."
            )
        }

        let modulated = harmonics(of: fm(depth: 0.25))
        let sidebandEnergy = modulated[1...].reduce(0, +)
        XCTAssertGreaterThan(
            sidebandEnergy, 1.0,
            "Depth 0.25 produced almost no sidebands (total \(sidebandEnergy) relative to the carrier)."
        )

        // A different ratio is a different timbre, not just a different level.
        let wide = harmonics(of: fm(depth: 0.25, ratio: 3))
        let distance = zip(modulated, wide).reduce(0) { $0 + abs($1.0 - $1.1) }
        XCTAssertGreaterThan(
            distance, 1.0,
            "Changing the FM ratio barely changed the spectrum (difference \(distance))."
        )
    }

    // MARK: The three types are distinct

    /// One note, three oscillator types, three different sounds.
    ///
    /// The acceptance criterion asks for each type to be *demonstrably
    /// distinct*, and comparing spectra is how that is demonstrated: two
    /// oscillators could easily produce different buffers while sounding the
    /// same, and only the harmonic content says otherwise.
    func testTheThreeOscillatorTypesAreMeasurablyDistinct() {
        let analogSaw = harmonics(of: analog(.saw), count: 8)
        let wavetable = harmonics(of: .singleOscillator(
            .init(type: .wavetable, wavetableBank: .formant, level: 1, shapeAmount: 0.7),
            name: "wavetable"
        ), count: 8)
        let frequencyModulation = harmonics(of: .singleOscillator(
            .init(type: .frequencyModulation, level: 1, shapeAmount: 0.3,
                  frequencyModulationRatio: 2),
            name: "fm"
        ), count: 8)

        for (name, first, second) in [
            ("analog vs wavetable", analogSaw, wavetable),
            ("analog vs FM", analogSaw, frequencyModulation),
            ("wavetable vs FM", wavetable, frequencyModulation)
        ] {
            let distance = zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) }
            XCTAssertGreaterThan(distance, 0.5, "\(name): spectra differ by only \(distance).")
        }
    }

    /// Every oscillator plays the note it was asked for.
    ///
    /// Distinctness is not enough on its own — three oscillators could be
    /// distinct and all of them wrong. The fundamental has to be where equal
    /// temperament puts it.
    func testEveryOscillatorTypeSoundsTheRequestedPitch() {
        let patches: [(String, SynthPatch)] = [
            ("analog", analog(.saw)),
            ("wavetable", .singleOscillator(
                .init(type: .wavetable, wavetableBank: .harmonic, level: 1, shapeAmount: 0.8),
                name: "wavetable")),
            ("fm", .singleOscillator(
                .init(type: .frequencyModulation, level: 1, shapeAmount: 0.2,
                      frequencyModulationRatio: 2),
                name: "fm"))
        ]

        for played in [45, 69, 84] {
            let expected = AudioRenderFixtures.frequency(ofMIDINote: played)
            for (name, patch) in patches {
                let samples = SynthVoiceHarness.renderNote(
                    patch: patch, midiNoteNumber: played, holdSeconds: 0.8, sampleRate: sampleRate
                )
                let steady = Array(samples[Int(0.2 * sampleRate)..<Int(0.7 * sampleRate)])
                let atPitch = AudioRenderFixtures.energy(
                    steady, atHertz: expected, sampleRate: sampleRate)
                // A semitone away, where a mis-tuned oscillator would land.
                let aSemitoneSharp = AudioRenderFixtures.energy(
                    steady, atHertz: expected * 1.0595, sampleRate: sampleRate)
                XCTAssertGreaterThan(
                    atPitch, aSemitoneSharp * 8,
                    "\(name) at MIDI \(played): energy at \(expected) Hz is \(atPitch), "
                        + "barely above the \(aSemitoneSharp) a semitone away."
                )
            }
        }
    }

    /// Band-limited tables, checked where it matters: a high note.
    ///
    /// A naively generated saw is perfectly fine at A4 and disastrous three
    /// octaves up, where its upper harmonics fold back below the fundamental
    /// as inharmonic tones. Nothing else in this suite would notice, because
    /// aliased energy is still energy and still deterministic — so this
    /// measures the one thing that distinguishes a band-limited oscillator: no
    /// significant energy below the note being played.
    func testHighNotesDoNotAlias() {
        for played in [93, 105] {
            let samples = SynthVoiceHarness.renderNote(
                patch: analog(.saw), midiNoteNumber: played, holdSeconds: 0.6,
                sampleRate: sampleRate
            )
            let steady = Array(samples[Int(0.2 * sampleRate)..<Int(0.55 * sampleRate)])
            let expected = AudioRenderFixtures.frequency(ofMIDINote: played)
            let fundamental = AudioRenderFixtures.energy(
                steady, atHertz: expected, sampleRate: sampleRate)

            var worst = 0.0
            var worstHertz = 0.0
            var probe = 60.0
            while probe < expected * 0.85 {
                let measured = AudioRenderFixtures.energy(
                    steady, atHertz: probe, sampleRate: sampleRate)
                if measured > worst { worst = measured; worstHertz = probe }
                probe *= 1.03
            }

            let decibels = AudioRenderFixtures.decibels(worst / max(fundamental, 1e-12))
            XCTAssertLessThan(
                decibels, -30,
                "MIDI \(played) has \(decibels) dB of energy at \(worstHertz) Hz, below its own "
                    + "\(expected) Hz fundamental. The oscillator is aliasing."
            )
        }
    }

    // MARK: Filter

    /// A lowpass removes upper harmonics, and four poles remove more of them
    /// than two.
    func testTheFilterRemovesHarmonicsAboveItsCutoff() {
        let open = harmonics(of: .singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "open"), count: 6)
        let twoPole = harmonics(of: .singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "lp2",
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: 400)), count: 6)
        let fourPole = harmonics(of: .singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "lp4",
            filter: .init(isEnabled: true, type: .lowpass, poles: 4, cutoffHertz: 400)), count: 6)

        XCTAssertGreaterThan(open[3], 0.2, "The unfiltered saw should have a strong 4th harmonic.")
        XCTAssertLessThan(
            twoPole[3], open[3] * 0.3,
            "A 400 Hz two-pole lowpass barely touched the 4th harmonic of a 440 Hz saw."
        )
        XCTAssertLessThan(
            fourPole[3], twoPole[3] * 0.5,
            "Four poles removed no more than two: \(fourPole[3]) against \(twoPole[3])."
        )
    }

    /// A highpass is the mirror image, so the filter type is a real parameter
    /// rather than a lowpass with a label.
    func testFilterTypeChangesWhichSideOfTheCutoffSurvives() {
        let lowpass = harmonics(of: .singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "lp",
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: 900)), count: 8)
        let highpass = harmonics(of: .singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "hp",
            filter: .init(isEnabled: true, type: .highpass, poles: 2, cutoffHertz: 900)), count: 8)

        // Normalised to the fundamental, so this compares shape, not level.
        XCTAssertLessThan(lowpass[5], 0.1, "The lowpass kept too much of the 6th harmonic.")
        XCTAssertGreaterThan(
            highpass[5], lowpass[5] * 5,
            "The highpass kept no more of the 6th harmonic than the lowpass did."
        )
    }

    // MARK: The modulation matrix

    /// **The mod-matrix acceptance criterion.** A filter cutoff modulated
    /// through the matrix measurably changes the spectrum over time.
    ///
    /// One patch, rendered twice, differing only in whether one matrix slot
    /// routes the modulation envelope to the cutoff. The measurement is the
    /// ratio of upper-harmonic to lower-harmonic energy — the standard
    /// "brightness" figure — taken just after the attack and again a second and
    /// a half later, once the modulation envelope has decayed to nothing.
    ///
    /// Comparing against the same patch with the route switched off is what
    /// makes this a claim about the matrix rather than about the filter: the
    /// filter's own envelope-free sweep is the control.
    func testModulationMatrixCutoffRoutingChangesTheSpectrumOverTime() {
        let base = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1),
            name: "sweep",
            filter: .init(isEnabled: true, type: .lowpass, poles: 4,
                          cutoffHertz: 250, resonance: 0.2),
            modulationEnvelope: .init(attackSeconds: 0.002, decaySeconds: 0.5,
                                      sustainLevel: 0, releaseSeconds: 0.3, curve: 1)
        )
        let routed = base.routing(.modulationEnvelope, to: .filterCutoff, amount: 0.55)

        func brightness(_ patch: SynthPatch) -> (early: Double, late: Double) {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 2.0, sampleRate: sampleRate)
            func measure(_ from: Double, _ to: Double) -> Double {
                let window = Array(samples[Int(from * sampleRate)..<Int(to * sampleRate)])
                let energies = AudioRenderFixtures.harmonicEnergies(
                    window, fundamental: fundamental, count: 8, sampleRate: sampleRate)
                let low = energies[0] + energies[1]
                let high = energies[4...].reduce(0, +)
                return high / max(low, 1e-12)
            }
            return (measure(0.02, 0.08), measure(1.4, 1.9))
        }

        let unrouted = brightness(base)
        let modulated = brightness(routed)

        XCTAssertEqual(
            unrouted.late, modulated.late, accuracy: max(unrouted.late, 1e-9) * 0.5,
            "With the modulation envelope spent, the two renders should have settled to the "
                + "same spectrum; they measured \(unrouted.late) and \(modulated.late)."
        )
        XCTAssertGreaterThan(
            modulated.early, unrouted.early * 4,
            "Routing the modulation envelope to the cutoff only moved the early brightness from "
                + "\(unrouted.early) to \(modulated.early). The matrix is barely reaching the filter."
        )
        XCTAssertGreaterThan(
            modulated.early / max(modulated.late, 1e-12), 20,
            "The routed patch's spectrum barely moved between its attack and its sustain."
        )
    }

    /// An LFO through the matrix modulates continuously rather than once, so
    /// the level keeps moving for as long as the note is held.
    func testAnLFORoutedToAmplitudeKeepsMovingTheLevel() {
        let steady = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "steady",
            lfos: [.init(shape: .sine, rateHertz: 6, retriggersPerNote: true), .init()]
        )
        let tremolo = steady.routing(.lfo1, to: .amplitude, amount: 0.8)

        func variation(_ patch: SynthPatch) -> Double {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 1.5, sampleRate: sampleRate)
            return AudioRenderFixtures.levelVariation(
                Array(samples[Int(0.2 * sampleRate)..<Int(1.4 * sampleRate)]))
        }

        let flat = variation(steady)
        let moving = variation(tremolo)
        XCTAssertGreaterThan(
            moving, flat * 5,
            "A 6 Hz LFO at 0.8 into amplitude moved the level by \(moving) against a baseline "
                + "of \(flat); the LFO is not reaching the VCA."
        )
    }

    /// A route with amount zero is inert, so an unused matrix slot cannot
    /// colour a sound by accident.
    func testAnInactiveMatrixSlotChangesNothing() {
        let patch = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "inert")
        let wired = patch.routing(.lfo1, to: .filterCutoff, amount: 0)

        let plain = SynthVoiceHarness.renderNote(patch: patch, holdSeconds: 0.5,
                                                 sampleRate: sampleRate)
        let routed = SynthVoiceHarness.renderNote(patch: wired, holdSeconds: 0.5,
                                                  sampleRate: sampleRate)
        XCTAssertEqual(plain, routed, "A zero-amount modulation route changed the output.")
    }

    // MARK: Envelopes

    /// **The envelope acceptance criterion.** Attack, sustain and release are
    /// each visible in the amplitude contour of the rendered audio.
    func testTheAmplitudeEnvelopeShapesTheRenderedContour() {
        func render(attack: Double, sustain: Double, release: Double) -> [Float] {
            var patch = SynthPatch.singleOscillator(
                .init(type: .analog, analogShape: .saw, level: 1), name: "envelope")
            patch.amplitudeEnvelope = .init(
                attackSeconds: attack, decaySeconds: 0.1, sustainLevel: sustain,
                releaseSeconds: release, curve: 0
            )
            return SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 1.0, tailSeconds: 1.0, sampleRate: sampleRate)
        }

        // Attack: a 400 ms ramp is nearly silent in its first 30 ms; a 2 ms one
        // is already at full level.
        let fast = render(attack: 0.002, sustain: 0.8, release: 0.05)
        let slow = render(attack: 0.400, sustain: 0.8, release: 0.05)
        let fastOnset = AudioRenderFixtures.rms(fast, from: 0, to: 0.03, sampleRate: sampleRate)
        let slowOnset = AudioRenderFixtures.rms(slow, from: 0, to: 0.03, sampleRate: sampleRate)
        XCTAssertGreaterThan(
            fastOnset / max(slowOnset, 1e-12), 10,
            "A 400 ms attack was \(slowOnset) in its first 30 ms against \(fastOnset) for a 2 ms "
                + "attack; the attack time is not shaping the contour."
        )
        // And the slow attack does get there.
        XCTAssertEqual(
            AudioRenderFixtures.rms(slow, from: 0.6, to: 0.9, sampleRate: sampleRate),
            AudioRenderFixtures.rms(fast, from: 0.6, to: 0.9, sampleRate: sampleRate),
            accuracy: 0.005,
            "The slow attack never reached the same sustain level."
        )

        // Sustain: the held level is the sustain fraction of the peak.
        let quiet = render(attack: 0.002, sustain: 0.2, release: 0.05)
        let loud = render(attack: 0.002, sustain: 0.8, release: 0.05)
        let quietLevel = AudioRenderFixtures.rms(quiet, from: 0.6, to: 0.9, sampleRate: sampleRate)
        let loudLevel = AudioRenderFixtures.rms(loud, from: 0.6, to: 0.9, sampleRate: sampleRate)
        XCTAssertEqual(
            quietLevel / loudLevel, 0.25, accuracy: 0.03,
            "Sustain 0.2 against sustain 0.8 gave a level ratio of \(quietLevel / loudLevel), "
                + "not the 0.25 the parameter asks for."
        )

        // Release: 400 ms after the note ends, a long release is still audible
        // and a short one has finished.
        let shortTail = render(attack: 0.002, sustain: 0.8, release: 0.05)
        let longTail = render(attack: 0.002, sustain: 0.8, release: 0.80)
        XCTAssertLessThan(
            AudioRenderFixtures.rms(shortTail, from: 1.35, to: 1.45, sampleRate: sampleRate),
            0.0005,
            "A 50 ms release was still sounding 350 ms after the note ended."
        )
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(longTail, from: 1.35, to: 1.45, sampleRate: sampleRate),
            0.02,
            "An 800 ms release had already died 350 ms after the note ended."
        )
    }

    /// The envelope curve is a real parameter: an exponential decay is below
    /// its linear equivalent halfway through and above it near the end.
    func testTheEnvelopeCurveChangesTheShapeOfTheDecay() {
        func decayLevel(curve: Double, at seconds: Double) -> Double {
            var patch = SynthPatch.singleOscillator(
                .init(type: .analog, analogShape: .saw, level: 1), name: "curve")
            patch.amplitudeEnvelope = .init(
                attackSeconds: 0.002, decaySeconds: 1.0, sustainLevel: 0,
                releaseSeconds: 0.05, curve: curve
            )
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 1.2, sampleRate: sampleRate)
            return AudioRenderFixtures.rms(
                samples, from: seconds, to: seconds + 0.02, sampleRate: sampleRate)
        }

        XCTAssertLessThan(
            decayLevel(curve: 1, at: 0.3), decayLevel(curve: 0, at: 0.3) * 0.75,
            "An exponential decay is not falling faster than a linear one early on."
        )
    }

    // MARK: Effects

    /// **The effects acceptance criterion**, one effect at a time: each is
    /// measurably active against the same patch with it bypassed.
    ///
    /// Each effect is measured by the thing it actually does, not by "the
    /// output changed". A reverb and a delay both add a tail, so they are
    /// measured by the shape of that tail; a chorus adds no tail at all and is
    /// measured by how much it keeps the level moving; an EQ moves neither and
    /// is measured band by band.
    func testReverbAddsATailThatBypassDoesNot() {
        let dry = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "dry")
        let wet = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "wet",
            reverb: .init(isEnabled: true, roomSize: 0.8, dampening: 0.3, mix: 0.5))

        func tail(_ patch: SynthPatch) -> Double {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 0.4, tailSeconds: 2.0, sampleRate: sampleRate)
            // Well past the 50 ms release, so nothing the voice itself produced
            // is still sounding.
            return AudioRenderFixtures.rms(samples, from: 1.0, to: 1.2, sampleRate: sampleRate)
        }

        XCTAssertLessThan(tail(dry), 1e-6, "The bypassed patch has a tail of its own.")
        XCTAssertGreaterThan(
            tail(wet), 1e-3,
            "600 ms after the note ended the reverb tail measured \(tail(wet)); it is inaudible."
        )
    }

    func testDelayRepeatsTheSignalAtItsSetTime() {
        let time = 0.25
        let patch = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "delay",
            delay: .init(isEnabled: true, timeSeconds: time, feedback: 0.7, mix: 0.5))
        let dry = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "dry")

        let wetSamples = SynthVoiceHarness.renderNote(
            patch: patch, holdSeconds: 0.2, tailSeconds: 1.4, sampleRate: sampleRate)
        let drySamples = SynthVoiceHarness.renderNote(
            patch: dry, holdSeconds: 0.2, tailSeconds: 1.4, sampleRate: sampleRate)

        // The repeats land a delay time apart and each is quieter than the last.
        let first = AudioRenderFixtures.rms(
            wetSamples, from: 0.30, to: 0.44, sampleRate: sampleRate)
        let second = AudioRenderFixtures.rms(
            wetSamples, from: 0.55, to: 0.69, sampleRate: sampleRate)
        let silentInDry = AudioRenderFixtures.rms(
            drySamples, from: 0.30, to: 0.44, sampleRate: sampleRate)

        XCTAssertLessThan(silentInDry, 1e-6, "The bypassed patch is still sounding after the note.")
        XCTAssertGreaterThan(first, 1e-3, "No first repeat: \(first).")
        XCTAssertGreaterThan(second, 1e-4, "No second repeat: \(second).")
        XCTAssertLessThan(second, first, "The repeats are not decaying.")
    }

    func testChorusKeepsTheLevelMovingWhereBypassDoesNot() {
        let settings = SynthPatch.Chorus(
            isEnabled: true, rateHertz: 1, depthMilliseconds: 15,
            centreMilliseconds: 20, mix: 0.5, feedback: 0.5
        )
        let dry = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "dry")
        let wet = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "wet", chorus: settings)

        func variation(_ patch: SynthPatch) -> Double {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, holdSeconds: 1.5, sampleRate: sampleRate)
            return AudioRenderFixtures.levelVariation(
                Array(samples[Int(0.2 * sampleRate)..<Int(1.4 * sampleRate)]))
        }

        let flat = variation(dry)
        let moving = variation(wet)
        XCTAssertGreaterThan(
            moving, flat * 3,
            "The chorus moved the level by \(moving) against a bypassed baseline of \(flat); "
                + "its comb notches are not sweeping."
        )
    }

    func testTheEqualizerMovesTheBandItIsPointedAt() {
        let bass = SynthPatch.Oscillator(type: .analog, analogShape: .saw, level: 1)

        func bands(_ equalizer: SynthPatch.Equalizer) -> (low: Double, high: Double) {
            let patch = SynthPatch.singleOscillator(bass, name: "eq", equalizer: equalizer)
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, midiNoteNumber: 45, holdSeconds: 1.0, sampleRate: sampleRate)
            let steady = Array(samples[Int(0.3 * sampleRate)..<Int(0.9 * sampleRate)])
            return (
                AudioRenderFixtures.energy(steady, atHertz: 110, sampleRate: sampleRate),
                AudioRenderFixtures.energy(steady, atHertz: 7040, sampleRate: sampleRate)
            )
        }

        let flat = bands(.init())
        let cut = bands(.init(isEnabled: true, lowGainDecibels: -20, lowHertz: 200))
        let boosted = bands(.init(isEnabled: true, highGainDecibels: 18, highHertz: 5000))

        XCTAssertLessThan(
            AudioRenderFixtures.decibels(cut.low / flat.low), -12,
            "A -20 dB low shelf only moved 110 Hz by "
                + "\(AudioRenderFixtures.decibels(cut.low / flat.low)) dB."
        )
        XCTAssertEqual(
            cut.high, flat.high, accuracy: flat.high * 0.05,
            "A low shelf changed the level at 7 kHz."
        )
        XCTAssertGreaterThan(
            AudioRenderFixtures.decibels(boosted.high / flat.high), 8,
            "An 18 dB high shelf only moved 7 kHz by "
                + "\(AudioRenderFixtures.decibels(boosted.high / flat.high)) dB."
        )
    }

    // MARK: Velocity

    /// **The dynamics acceptance criterion.** Velocity moves the rendered
    /// level along the curve the patch asks for, so PLY002's realized dynamics
    /// are heard rather than merely stored.
    func testVelocityFollowsThePatchSensitivityCurve() {
        let sensitivity = 1.6
        let patch = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "velocity",
            velocitySensitivity: sensitivity)

        func level(_ velocity: Int) -> Double {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch, velocity: velocity, holdSeconds: 0.5, sampleRate: sampleRate)
            return AudioRenderFixtures.rms(samples, from: 0.2, to: 0.45, sampleRate: sampleRate)
        }

        let velocities = [20, 40, 60, 100, 127]
        let levels = velocities.map(level)

        for index in 1..<levels.count {
            XCTAssertGreaterThan(
                levels[index], levels[index - 1],
                "Velocity \(velocities[index]) was no louder than \(velocities[index - 1])."
            )
        }

        // The curve, not just the direction: level should track
        // (velocity / 127) ^ sensitivity.
        let reference = levels[velocities.firstIndex(of: 100)!]
        for (velocity, measured) in zip(velocities, levels) {
            let expected = reference
                * pow(Double(velocity) / 100, sensitivity)
            XCTAssertEqual(
                measured, expected, accuracy: expected * 0.05,
                "Velocity \(velocity) rendered at \(measured); the \(sensitivity) curve predicts "
                    + "\(expected)."
            )
        }

        // A different sensitivity is a different curve.
        let linear = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "linear",
            velocitySensitivity: 1.0)
        let quietOnCurve = level(40)
        let quietLinear = AudioRenderFixtures.rms(
            SynthVoiceHarness.renderNote(
                patch: linear, velocity: 40, holdSeconds: 0.5, sampleRate: sampleRate),
            from: 0.2, to: 0.45, sampleRate: sampleRate)
        XCTAssertGreaterThan(
            quietLinear, quietOnCurve * 1.5,
            "Sensitivity 1.0 and 1.6 produced almost the same level at velocity 40."
        )
    }

    // MARK: Safety

    /// A patch asking for everything at once still cannot leave the voice
    /// outside ±1, and its tail still ends.
    ///
    /// This is the runaway-feedback guarantee the issue asks for, measured
    /// rather than asserted: maximum delay feedback into the largest room with
    /// no damping, at full output level, held for five seconds and then left
    /// alone for five more.
    func testAPatchCannotProduceUnboundedOrEndlessOutput() {
        let hot = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .saw, level: 1), name: "hot",
            delay: .init(isEnabled: true, timeSeconds: 0.01, feedback: 0.85, mix: 1.0),
            reverb: .init(isEnabled: true, roomSize: 1.0, dampening: 0.0, mix: 1.0),
            outputLevel: 1.0
        )
        let samples = SynthVoiceHarness.renderNote(
            patch: hot, holdSeconds: 5.0, tailSeconds: 5.0, sampleRate: sampleRate)

        XCTAssertLessThanOrEqual(
            AudioRenderFixtures.peak(samples), 1.0,
            "The voice produced a sample outside ±1; the limiter is not holding."
        )
        for sample in samples {
            XCTAssertTrue(sample.isFinite, "The voice produced a non-finite sample.")
        }
        XCTAssertLessThan(
            AudioRenderFixtures.rms(samples, from: 9.0, to: 10.0, sampleRate: sampleRate),
            0.01,
            "Five seconds after the note ended the effects were still ringing at full strength."
        )
    }

    /// Full polyphony with a loud patch stays inside the limiter, and the
    /// engine still has headroom of its own afterwards.
    func testFullPolyphonyStaysInsideTheLimiter() {
        let harness = SynthVoiceHarness(patch: .defaultVoice, sampleRate: sampleRate)
        for note in 40...71 { harness.noteOn(note, velocity: 127) }
        let chord = harness.render(seconds: 1.0)

        XCTAssertLessThanOrEqual(AudioRenderFixtures.peak(chord), 1.0)
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(chord, from: 0.2, to: 0.9, sampleRate: sampleRate), 0.05,
            "A 32-note chord is barely audible."
        )
    }

    /// `maximumVoices` is enforced: asking for thirty-two notes on a four-voice
    /// patch produces four notes, not thirty-two.
    func testMaximumVoicesLimitsWhatSounds() {
        func level(maximumVoices: Int) -> Double {
            var patch = SynthPatch.defaultVoice
            patch.maximumVoices = maximumVoices
            let harness = SynthVoiceHarness(patch: patch, sampleRate: sampleRate)
            for note in 40...71 { harness.noteOn(note, velocity: 100) }
            let samples = harness.render(seconds: 0.5)
            return AudioRenderFixtures.rms(samples, from: 0.2, to: 0.45, sampleRate: sampleRate)
        }

        let four = level(maximumVoices: 4)
        let all = level(maximumVoices: 32)
        XCTAssertGreaterThan(four, 0.01, "A four-voice patch produced nothing.")
        XCTAssertGreaterThan(
            all, four * 1.5,
            "Thirty-two voices were no louder than four (\(all) against \(four)); the voice limit "
                + "is not being applied."
        )
    }

    /// Noise is a source like any other — shaped by the envelope, and seeded,
    /// so two renders of it are identical.
    func testNoiseIsBroadbandAndRepeatable() {
        let patch = SynthPatch.singleOscillator(
            .init(type: .analog, analogShape: .sine, level: 0.0001), name: "noise",
            noiseLevel: 0.5)

        let first = SynthVoiceHarness.renderNote(
            patch: patch, holdSeconds: 0.5, sampleRate: sampleRate)
        let second = SynthVoiceHarness.renderNote(
            patch: patch, holdSeconds: 0.5, sampleRate: sampleRate)

        XCTAssertEqual(first, second, "Two renders of the same seeded noise differed.")

        let steady = Array(first[Int(0.1 * sampleRate)..<Int(0.45 * sampleRate)])
        // Broadband: comparable energy at unrelated frequencies, unlike any
        // oscillator here.
        let low = AudioRenderFixtures.energy(steady, atHertz: 300, sampleRate: sampleRate)
        let high = AudioRenderFixtures.energy(steady, atHertz: 6100, sampleRate: sampleRate)
        XCTAssertGreaterThan(low, 1e-4)
        XCTAssertGreaterThan(high, low * 0.2, "The noise source is not broadband.")
    }
}
