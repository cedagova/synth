import XCTest
@testable import SynthKit

/// What the customization controls actually do to the audio.
///
/// **Every claim here is measured from rendered samples**, through the same
/// vtable `synth_audio_core_render` calls, in the same order. A test that
/// asserted on `SampleVoiceCustomization`'s fields would prove that a struct
/// was filled in; what has to be true is that the note comes out different, and
/// different in the direction the control's label promises.
///
/// The fixtures are sines and constants rather than instruments, for the reason
/// INS002's suite gives: a claim like "this raises the top end" is a claim
/// about one number, and a sample whose spectrum is known makes that number
/// readable.
final class InstrumentCustomizationRenderTests: XCTestCase {
    private var root: URL!
    private let sampleRate = 44_100.0

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try SFZFixtures.makeLibraryDirectory("customization-render")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func harness(
        _ available: AvailableInstrument, _ customization: InstrumentCustomization
    ) throws -> SampledVoiceHarness {
        try SampledVoiceHarness(
            available, sampleRate: sampleRate, customization: customization
        )
    }

    // MARK: Tuning offset

    /// A tuning offset moves the pitch by exactly the cents it names.
    func testATuningOffsetShiftsThePitchByTheCentsItNames() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)

        func frequency(offsetCents: Double) throws -> Double {
            let voice = try harness(
                pitched, InstrumentCustomization(tuningOffsetCents: offsetCents)
            )
            voice.noteOn(69)
            let samples = voice.render(seconds: 0.5)
            voice.noteOff(69)
            return SampledVoiceHarness.frequency(
                of: Array(samples[(samples.count / 4)...]), sampleRate: sampleRate
            )
        }

        let plain = try frequency(offsetCents: 0)
        XCTAssertEqual(plain, 440, accuracy: 3, "The fixture is A440 untransposed")

        // +100 cents is one semitone: 440 × 2^(1/12) = 466.16 Hz.
        let up = try frequency(offsetCents: 100)
        XCTAssertEqual(up, 466.16, accuracy: 4, "A semitone up")

        // −50 cents is a quarter tone down: 440 × 2^(-1/24) = 427.47 Hz.
        let down = try frequency(offsetCents: -50)
        XCTAssertEqual(down, 427.47, accuracy: 4, "A quarter tone down")
    }

    // MARK: Vibrato

    /// Vibrato modulates the pitch periodically, at the rate it names, and
    /// leaves the pitch alone when its depth is zero.
    func testVibratoModulatesThePitchAtTheRateItNames() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)

        // A slow, deep vibrato so one LFO period is long enough to measure the
        // pitch inside a quarter of it.
        let rate = 2.0
        let voice = try harness(
            pitched,
            InstrumentCustomization(vibratoDepthCents: 100, vibratoRateHz: rate)
        )
        voice.noteOn(69)
        let samples = voice.render(seconds: 1.0)
        voice.noteOff(69)

        // The LFO starts at zero, reaches +1 a quarter period in and −1 three
        // quarters in. Measuring around those two points reads the extremes of
        // the swing.
        let period = sampleRate / rate
        func frequency(aroundFraction fraction: Double) -> Double {
            let centre = Int(period * fraction)
            let window = Int(period * 0.12)
            let slice = Array(samples[max(0, centre - window)..<min(samples.count, centre + window)])
            return SampledVoiceHarness.frequency(of: slice, sampleRate: sampleRate)
        }

        let sharp = frequency(aroundFraction: 0.25)
        let flat = frequency(aroundFraction: 0.75)

        XCTAssertGreaterThan(
            sharp, flat + 20,
            "A quarter period in the pitch must be measurably above where it is three "
                + "quarters in — otherwise the LFO is not swinging (sharp \(sharp), flat \(flat))"
        )
        // 100 cents peak-to-peak either side of 440 is roughly 415…466.
        XCTAssertEqual(sharp, 466, accuracy: 25)
        XCTAssertEqual(flat, 415, accuracy: 25)
    }

    func testZeroDepthVibratoLeavesThePitchExactlyWhereItWas() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)

        let plain = try harness(pitched, .asRecorded)
        plain.noteOn(69)
        let without = plain.render(seconds: 0.4)

        let armed = try harness(
            pitched, InstrumentCustomization(vibratoDepthCents: 0, vibratoRateHz: 8)
        )
        armed.noteOn(69)
        let with = armed.render(seconds: 0.4)

        XCTAssertEqual(
            with, without,
            "A rate with no depth must be inaudible, not a very small vibrato"
        )
    }

    // MARK: Tone

    /// The shelves move the band each one names, in the direction it names, and
    /// leave the other band roughly where it was.
    func testTheToneShelvesMoveTheBandsTheyName() throws {
        // Two tones an octave and a half apart, well inside each shelf's band.
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 100, seconds: 2.0, sampleRate: sampleRate),
            to: root.appending(path: "low.wav"), sampleRate: sampleRate
        )
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 8_000, seconds: 2.0, sampleRate: sampleRate),
            to: root.appending(path: "high.wav"), sampleRate: sampleRate
        )
        let twoTone = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=low.wav lokey=60 hikey=60 pitch_keycenter=60
            <region> sample=high.wav lokey=61 hikey=61 pitch_keycenter=61
            """,
            named: "twotone.sfz", in: root, instrumentName: "Two Tone"
        )

        func level(ofNote note: Int, _ customization: InstrumentCustomization) throws -> Double {
            let voice = try harness(twoTone, customization)
            voice.noteOn(note)
            let samples = voice.render(seconds: 0.5)
            voice.noteOff(note)
            // The tail, so the filters have settled.
            return Double(SampledVoiceHarness.meanAbsolute(samples.suffix(8_000)))
        }

        let flatLow = try level(ofNote: 60, .asRecorded)
        let flatHigh = try level(ofNote: 61, .asRecorded)

        let boostedLow = try level(ofNote: 60, InstrumentCustomization(toneLowDecibels: 9))
        let cutLow = try level(ofNote: 60, InstrumentCustomization(toneLowDecibels: -9))
        XCTAssertGreaterThan(boostedLow, flatLow * 1.5, "A low boost must raise a 100 Hz tone")
        XCTAssertLessThan(cutLow, flatLow * 0.7, "A low cut must lower it")

        let boostedHigh = try level(ofNote: 61, InstrumentCustomization(toneHighDecibels: 9))
        let cutHigh = try level(ofNote: 61, InstrumentCustomization(toneHighDecibels: -9))
        XCTAssertGreaterThan(boostedHigh, flatHigh * 1.5, "A high boost must raise an 8 kHz tone")
        XCTAssertLessThan(cutHigh, flatHigh * 0.7, "A high cut must lower it")

        // …and each shelf largely leaves the other band alone. A one-pole shelf
        // is gentle by design, so this is a bound rather than an equality.
        let lowBoostOnHigh = try level(ofNote: 61, InstrumentCustomization(toneLowDecibels: 9))
        XCTAssertEqual(
            lowBoostOnHigh, flatHigh, accuracy: flatHigh * 0.25,
            "The low shelf must not be a volume knob"
        )
    }

    func testAFlatToneRendersExactlyWhatTheInstrumentRecorded() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)

        let plain = try harness(pitched, .asRecorded)
        plain.noteOn(69)
        let without = plain.render(seconds: 0.3)

        let flat = try harness(
            pitched, InstrumentCustomization(toneLowDecibels: 0, toneHighDecibels: 0)
        )
        flat.noteOn(69)
        let with = flat.render(seconds: 0.3)

        XCTAssertEqual(
            with, without,
            "A tone control at zero must cost the signal nothing at all — INS002's "
                + "measurements have to keep holding for an uncustomized instrument"
        )
    }

    // MARK: Dynamics response

    /// Response above 1 widens the gap between a soft note and a loud one;
    /// below 1 narrows it; and the loudest note is unchanged at every setting,
    /// which is what stops this being a volume control.
    func testDynamicsResponseWidensAndNarrowsTheGapWithoutMovingTheLoudest() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)

        func level(velocity: Int, response: Double) throws -> Double {
            let voice = try harness(
                deep, InstrumentCustomization(dynamicsResponse: response)
            )
            return Double(voice.level(ofNote: 60, velocity: velocity, after: 0.2))
        }

        let softAsRecorded = try level(velocity: 20, response: 1)
        let loudAsRecorded = try level(velocity: 127, response: 1)
        XCTAssertGreaterThan(loudAsRecorded, softAsRecorded, "The fixture has real dynamics")

        let softWidened = try level(velocity: 20, response: 1.8)
        let loudWidened = try level(velocity: 127, response: 1.8)
        XCTAssertLessThan(
            softWidened, softAsRecorded * 0.9,
            "A wider response must push the soft end further down"
        )
        XCTAssertEqual(
            loudWidened, loudAsRecorded, accuracy: loudAsRecorded * 0.02,
            "…and leave the loudest note where it was"
        )

        let softNarrowed = try level(velocity: 20, response: 0.4)
        let loudNarrowed = try level(velocity: 127, response: 0.4)
        XCTAssertGreaterThan(
            softNarrowed, softAsRecorded * 1.1,
            "A narrower response must bring the soft end up"
        )
        XCTAssertEqual(loudNarrowed, loudAsRecorded, accuracy: loudAsRecorded * 0.02)
    }

    /// On a one-layer patch the control is gated off, and `bounded` makes that
    /// mean *inert* rather than merely greyed out.
    func testDynamicsResponseIsInertOnAOneLayerPatchEvenWhenAskedFor() throws {
        let thin = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)
        let instrument = try SampledInstrument(thin)
        let capabilities = InstrumentCapabilities(
            features: instrument.features,
            coverage: thin.coverage,
            alternateArticulationCount: 0
        )
        XCTAssertFalse(capabilities.isSupported(.dynamicsResponse))

        let asked = InstrumentCustomization(dynamicsResponse: 1.9)
        let plain = try harness(thin, .asRecorded)
        let gated = try harness(thin, capabilities.bounded(asked))

        XCTAssertEqual(
            Double(gated.level(ofNote: 69, velocity: 20, after: 0.2)),
            Double(plain.level(ofNote: 69, velocity: 20, after: 0.2)),
            accuracy: 1e-6,
            "A control the instrument cannot support must have no effect on the audio"
        )
    }

    // MARK: Envelope

    func testAttackSofteningLengthensTheRiseWithoutChangingTheDestination() throws {
        let looped = try SFZFixtures.loopedInstrument(in: root, sampleRate: sampleRate)

        /// The level over the first `seconds` of the note, and the level once
        /// it has settled. A longer attack lowers the first without moving the
        /// second: the note arrives more slowly and arrives at the same place.
        func levels(added: Double) throws -> (start: Double, settled: Double) {
            let voice = try harness(looped, InstrumentCustomization(attackSeconds: added))
            voice.noteOn(60)
            let samples = voice.render(seconds: 0.8)
            voice.noteOff(60)
            let firstFifty = Int(0.05 * sampleRate)
            return (
                Double(SampledVoiceHarness.meanAbsolute(samples.prefix(firstFifty))),
                Double(SampledVoiceHarness.meanAbsolute(samples.suffix(firstFifty)))
            )
        }

        let immediate = try levels(added: 0)
        let softened = try levels(added: 0.25)

        XCTAssertGreaterThan(immediate.start, 0.1, "The fixture starts at full level")
        XCTAssertLessThan(
            softened.start, immediate.start * 0.35,
            "A quarter-second of added attack must make the first fifty milliseconds much quieter"
        )
        XCTAssertEqual(
            softened.settled, immediate.settled, accuracy: immediate.settled * 0.05,
            "…and must leave the note where it was going"
        )
    }

    func testReleaseScaleLengthensAndShortensTheTail() throws {
        let looped = try SFZFixtures.loopedInstrument(in: root, sampleRate: sampleRate)

        func tailEnergy(scale: Double) throws -> Double {
            let voice = try harness(looped, InstrumentCustomization(releaseScale: scale))
            voice.noteOn(60)
            _ = voice.render(seconds: 0.3)
            voice.noteOff(60)
            // The fixture states a ten-millisecond release, so the window that
            // separates a quarter of it from four times it is the sixty
            // milliseconds after the damper falls.
            let tail = voice.render(seconds: 0.06)
            return Double(SampledVoiceHarness.meanAbsolute(tail))
        }

        let recorded = try tailEnergy(scale: 1)
        let longer = try tailEnergy(scale: 4)
        let shorter = try tailEnergy(scale: 0.25)

        XCTAssertGreaterThan(longer, recorded * 2, "Four times the release must ring on")
        XCTAssertLessThan(shorter, recorded, "A quarter of it must be gone sooner")
    }

    /// The tail the render program reserves grows with the release, or an
    /// export would cut the last note off while live playback sounded complete.
    func testTheReleaseScaleReachesTheProgramsReservedTail() throws {
        let looped = try SFZFixtures.loopedInstrument(in: root, sampleRate: sampleRate)
        let instrument = try SampledInstrument(looped)

        let recorded = SampledInstrumentVoiceProvider(instrument: instrument)
        let stretched = SampledInstrumentVoiceProvider(
            instrument: instrument, customization: InstrumentCustomization(releaseScale: 4)
        )

        XCTAssertGreaterThan(recorded.releaseTailSeconds, 0)
        XCTAssertEqual(
            stretched.releaseTailSeconds, recorded.releaseTailSeconds * 4, accuracy: 1e-9
        )
        XCTAssertLessThanOrEqual(
            stretched.releaseTailSeconds, RenderProgram.maximumReleaseTailSeconds,
            "…and still inside the cap, so one extreme variant cannot make every render minutes long"
        )
    }

    // MARK: Determinism and live editing

    /// REQ-012 and REQ-026 through a customized instrument: two renders of one
    /// passage agree exactly.
    func testTwoRendersOfOneCustomizedPassageAreIdentical() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)
        let customization = InstrumentCustomization(
            toneLowDecibels: 4,
            toneHighDecibels: -3,
            dynamicsResponse: 1.5,
            attackSeconds: 0.05,
            releaseScale: 2,
            vibratoDepthCents: 30,
            vibratoRateHz: 5
        )

        func render() throws -> [Float] {
            let voice = try harness(deep, customization)
            voice.noteOn(60, velocity: 80)
            let held = voice.render(seconds: 0.4)
            voice.noteOff(60)
            return held + voice.render(seconds: 0.4)
        }

        XCTAssertEqual(try render(), try render())
    }

    /// A seek resets the voice, and the vibrato and the shelves go back with
    /// it — so the same passage sounds the same whether it was played from the
    /// start or jumped to.
    func testResettingAVoiceRewindsTheVibratoAndTheShelves() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)
        let voice = try harness(
            pitched,
            InstrumentCustomization(
                toneLowDecibels: 6, vibratoDepthCents: 60, vibratoRateHz: 3
            )
        )

        voice.noteOn(69)
        let first = voice.render(seconds: 0.3)
        voice.noteOff(69)
        _ = voice.render(seconds: 0.2)

        voice.reset()
        voice.noteOn(69)
        let second = voice.render(seconds: 0.3)

        XCTAssertEqual(
            first, second,
            "A reset must put the LFO and the filters back, or a seek would change the sound"
        )
    }

    /// REQ-018 for a customized instrument: an edit reaches the notes that are
    /// already sounding, without rebuilding anything.
    func testAnEditReachesAVoiceThatIsAlreadySounding() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: sampleRate)
        let instrument = try SampledInstrument(pitched)
        let channel = SampledInstrumentLiveVoices()
        let provider = SampledInstrumentVoiceProvider(instrument: instrument, live: channel)

        let voice = provider.makeVoice(sampleRate: sampleRate)
        defer { voice.release() }
        var vtable = voice.vtable
        vtable.prepare(vtable.state, sampleRate)
        vtable.reset(vtable.state)

        XCTAssertEqual(channel.voiceCount, 1, "The voice must register itself")
        // One adoption already: `makeVoice` seats the channel's current
        // customization on the new voice, which is what makes a graph rebuilt
        // for a device change come back playing the edited instrument.
        let adoptionsBeforeTheEdit = channel.adoptionsTakenUp

        func render(seconds: Double) -> [Float] {
            var block = [Float](repeating: 0, count: 512)
            var output: [Float] = []
            var remaining = Int(seconds * sampleRate)
            while remaining > 0 {
                let count = min(512, remaining)
                block.withUnsafeMutableBufferPointer {
                    vtable.render(vtable.state, $0.baseAddress!, Int32(count))
                }
                output.append(contentsOf: block[0..<count])
                remaining -= count
            }
            return output
        }

        // A note is sounding, and stays sounding across the edit.
        vtable.noteOn(vtable.state, 69, 100)
        let before = render(seconds: 0.2)

        let result = channel.apply(InstrumentCustomization(toneLowDecibels: -12))
        XCTAssertTrue(result.reachedAnyVoice)
        XCTAssertGreaterThan(
            channel.adoptionsTakenUp, adoptionsBeforeTheEdit,
            "The publish must have reached the voice, not merely been recorded"
        )

        let after = render(seconds: 0.2)
        vtable.noteOff(vtable.state, 69)

        XCTAssertNotEqual(
            SampledVoiceHarness.meanAbsolute(after.suffix(2_000)),
            SampledVoiceHarness.meanAbsolute(before.suffix(2_000)),
            "The edit must be heard on the note that was already playing"
        )
    }

    func testANeutralCustomizationRendersWhatTheUncustomizedEngineDid() throws {
        let deep = try SFZFixtures.deeplyLayeredInstrument(in: root)

        let uncustomized = try SampledVoiceHarness(deep, sampleRate: sampleRate)
        uncustomized.noteOn(60, velocity: 90)
        let baseline = uncustomized.render(seconds: 0.3)

        let neutral = try harness(deep, .asRecorded)
        neutral.noteOn(60, velocity: 90)
        let customized = neutral.render(seconds: 0.3)

        XCTAssertEqual(
            baseline, customized,
            "An instrument nobody has customized must render exactly what INS002 measured"
        )
    }
}
