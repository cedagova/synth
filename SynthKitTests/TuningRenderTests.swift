import XCTest
@testable import SynthKit
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// What the tuning settings actually do to the audio (TUN001, REQ-006).
///
/// **Every claim here is a frequency measured from rendered samples**, through the
/// same vtable `synth_audio_core_render` calls. A test that read back
/// `synth_patch_voice_tuning` would prove a struct was copied; what REQ-006 asks
/// is that the note comes out at a different pitch, per pitch class, and by the
/// amount the temperament names.
///
/// **Both engine kinds, because "both" is the acceptance criterion.** The
/// synthesizer derives a frequency from the note number; the sampler derives a
/// playback rate from the distance to a recorded key centre and has no absolute
/// pitch of its own. Those are two different mechanisms that have to agree about
/// one setting, so each is measured separately and then against the other.
///
/// The fixtures are sines, for the reason the rest of the sampler suite gives: a
/// claim about pitch is a claim about one number, and a sine makes that number
/// readable to a fraction of a cent.
final class TuningRenderTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let samplerRate = 44_100.0
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try SFZFixtures.makeLibraryDirectory("tuning-render")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// The twelve pitch classes of one octave, named so a failure says which.
    private static let pitchClassNames = [
        "C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"
    ]

    /// C4 upwards: one octave, every pitch class once, inside both fixtures'
    /// ranges.
    private static let octave = Array(60...71)

    // MARK: Measurement

    /// Fundamental frequency of a clean sine, to a small fraction of a cent.
    ///
    /// **Interpolated zero crossings, not counted ones.** The existing
    /// `SampledVoiceHarness.frequency` counts rising crossings and divides, which
    /// quantises the first and last crossing to a whole sample — about a tenth of a
    /// cent over these windows. That is fine for "a semitone up" and not fine here:
    /// Werckmeister III's smallest offset is 1.955 cents, and a claim that small
    /// has to be measured with room to spare. Interpolating linearly between the
    /// two samples that straddle each crossing removes the quantisation and leaves
    /// the estimate limited by the window length alone.
    static func sineFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        var first: Double?
        var last: Double?
        var crossings = 0
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            guard previous <= 0, current > 0 else { continue }
            // Where the straight line between the two samples crosses zero.
            let fraction = previous == current
                ? 0
                : Double(-previous) / Double(current - previous)
            let position = Double(index - 1) + fraction
            if first == nil { first = position }
            last = position
            crossings += 1
        }
        guard crossings > 1, let first, let last, last > first else { return 0 }
        return Double(crossings - 1) * sampleRate / (last - first)
    }

    /// How far `measured` is from `expected`, in cents.
    private func cents(_ measured: Double, from expected: Double) -> Double {
        1200 * log2(measured / expected)
    }

    // MARK: The synthesizer

    /// A patch that is one sine and nothing else, so its pitch is the only thing
    /// there is to measure.
    private var sinePatch: SynthPatch {
        .singleOscillator(.init(type: .analog, analogShape: .sine, level: 1), name: "tuning-sine")
    }

    private func synthFrequency(of note: Int, tuning: TuningSettings) -> Double {
        let harness = SynthVoiceHarness(
            patch: sinePatch, sampleRate: sampleRate, tuning: tuning
        )
        harness.noteOn(note)
        let samples = harness.render(seconds: 0.8)
        harness.noteOff(note)
        // Past the attack, so the envelope contributes no asymmetry to the
        // crossings.
        return Self.sineFrequency(
            Array(samples[Int(0.1 * sampleRate)...]), sampleRate: sampleRate
        )
    }

    /// **REQ-006 on the synthesizer, pitch class by pitch class.** Every one of the
    /// twelve comes out where the chosen temperament and reference pitch say it
    /// should, to within a fifth of a cent.
    ///
    /// Asserted against `TuningSettings.frequency(ofMIDINote:)` — the model's own
    /// arithmetic — rather than against twelve numbers typed into the test, because
    /// `TuningTests` has already checked that arithmetic against the published
    /// table. Chaining the two that way is what makes this a measurement of the
    /// engine rather than a second transcription to get wrong.
    func testEveryPitchClassOfTheSynthesizerIsTunedAsTheSettingSays() {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                for note in Self.octave {
                    let expected = tuning.frequency(ofMIDINote: note)
                    let measured = synthFrequency(of: note, tuning: tuning)
                    XCTAssertEqual(
                        cents(measured, from: expected), 0, accuracy: 0.2,
                        "\(temperament) at \(reference): "
                            + "\(Self.pitchClassNames[note % 12]) came out at \(measured) Hz, "
                            + "\(expected) Hz expected "
                            + "(\(cents(measured, from: expected)) cents off)"
                    )
                }
            }
        }
    }

    /// And the difference is audible rather than merely arithmetic: Werckmeister III
    /// moves ten of the twelve pitch classes by a measurable amount and leaves two
    /// exactly where equal temperament had them.
    ///
    /// **Two, not one, and that is Werckmeister's table rather than an accident of
    /// the anchor.** A is unmoved because the reference pitch pins it. F♯ is unmoved
    /// because Werckmeister III happens to place it at the same deviation as A
    /// (−11.730 cents from equal, the only pair in the table that coincide), so
    /// anchoring on A lands F♯ on its equal-tempered pitch too. Asserting the count
    /// is what stops this test passing if the table were ever flattened.
    ///
    /// The discrimination guard for the synthesizer. A test that only compared
    /// measurements against a model both sides share would still pass if the engine
    /// ignored the table and the model described equal temperament.
    func testWerckmeisterIIIMovesTheSynthesizerAwayFromEqualTemperament() {
        let equal = TuningSettings(temperament: .equal)
        let well = TuningSettings(temperament: .werckmeisterIII)
        var moved = 0

        for note in Self.octave {
            let shift = cents(
                synthFrequency(of: note, tuning: well),
                from: synthFrequency(of: note, tuning: equal)
            )
            let expected = well.offsetsInCentsFromEqual[note % 12]
            XCTAssertEqual(
                shift, expected, accuracy: 0.3,
                "\(Self.pitchClassNames[note % 12]) moved \(shift) cents; "
                    + "Werckmeister III moves it \(expected)"
            )
            if abs(expected) > 0.5 { moved += 1 }
        }

        XCTAssertEqual(
            moved, 10,
            "Werckmeister III should move ten pitch classes and leave A and F♯ where equal "
                + "temperament had them; it moved \(moved)"
        )
    }

    /// A=415 lowers the whole synthesizer by 101.3 cents and by the same amount on
    /// every pitch class.
    func testTheReferencePitchLowersTheWholeSynthesizer() {
        let at440 = TuningSettings(referencePitch: .a440)
        let at415 = TuningSettings(referencePitch: .a415)
        let expected = 1200 * log2(415.0 / 440.0)

        for note in Self.octave {
            let shift = cents(
                synthFrequency(of: note, tuning: at415),
                from: synthFrequency(of: note, tuning: at440)
            )
            XCTAssertEqual(
                shift, expected, accuracy: 0.2,
                "\(Self.pitchClassNames[note % 12]) moved \(shift) cents rather than \(expected)"
            )
        }
    }

    // MARK: The sampler

    private func samplerFrequency(
        of note: Int,
        tuning: TuningSettings,
        offsetCents: Double = 0,
        instrument: AvailableInstrument? = nil
    ) throws -> Double {
        let available = try instrument
            ?? SFZFixtures.pitchedInstrument(in: root, sampleRate: samplerRate)
        let harness = try SampledVoiceHarness(
            available,
            sampleRate: samplerRate,
            customization: InstrumentCustomization(tuningOffsetCents: offsetCents),
            tuning: tuning
        )
        harness.noteOn(note)
        let samples = harness.render(seconds: 0.5)
        harness.noteOff(note)
        return Self.sineFrequency(
            Array(samples[Int(0.05 * samplerRate)...]), sampleRate: samplerRate
        )
    }

    /// **REQ-006 on a pitched sampled instrument, pitch class by pitch class.**
    ///
    /// The sampler reaches the same frequencies by an entirely different route —
    /// it has no 440 in it at all, only a distance from a recorded key centre — so
    /// this is the assertion that says one setting means one thing across both
    /// engine kinds rather than two things that happen to be named the same.
    func testEveryPitchClassOfAPitchedSampledInstrumentIsTunedAsTheSettingSays() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: samplerRate)
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                for note in Self.octave {
                    let expected = tuning.frequency(ofMIDINote: note)
                    let measured = try samplerFrequency(
                        of: note, tuning: tuning, instrument: pitched
                    )
                    XCTAssertEqual(
                        cents(measured, from: expected), 0, accuracy: 0.3,
                        "\(temperament) at \(reference): "
                            + "\(Self.pitchClassNames[note % 12]) came out at \(measured) Hz, "
                            + "\(expected) Hz expected"
                    )
                }
            }
        }
    }

    /// **P65-4's composition rule, measured.** A per-instrument tuning offset and
    /// the program's temperament multiply: the note lands at the temperament's
    /// frequency shifted by exactly the offset's cents, with the offset keeping its
    /// own meaning and the table keeping its own.
    ///
    /// Both signs of offset and both temperaments, so this cannot pass by one of
    /// the two being ignored in a direction that happens to cancel.
    func testThePerInstrumentOffsetComposesWithTheProgramsTuning() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: samplerRate)

        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                for offset in [-37.0, 18.5, 100.0] {
                    // Three pitch classes with three different temperament
                    // offsets: C is the most moved, F♯ the least, A the anchor.
                    for note in [60, 66, 69] {
                        let expected = tuning.frequency(ofMIDINote: note)
                            * pow(2, offset / 1200)
                        let measured = try samplerFrequency(
                            of: note, tuning: tuning,
                            offsetCents: offset, instrument: pitched
                        )
                        XCTAssertEqual(
                            cents(measured, from: expected), 0, accuracy: 0.3,
                            "\(temperament) at \(reference) with a \(offset)-cent offset: "
                                + "\(Self.pitchClassNames[note % 12]) came out at "
                                + "\(measured) Hz, \(expected) Hz expected — the two are not "
                                + "composing"
                        )
                    }
                }
            }
        }
    }

    /// Neither bounds the other: the offset keeps its full ±100 cents at a
    /// non-default tuning, and the tuning keeps its full shift at a maximal offset.
    ///
    /// The clamp on the customization's ratio is ±100 cents by design
    /// (`sample_voice_set_customization`), and a composition that ran the two
    /// through that one clamp would silently cap the pair at 100 cents total. This
    /// is the test that would catch it: 100 cents of offset on top of a 101-cent
    /// reference shift is 201 cents, and a clamped implementation would read 100.
    func testNeitherTheOffsetNorTheTuningClampsTheOther() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: samplerRate)
        let plain = try samplerFrequency(
            of: 69, tuning: .standard, offsetCents: 0, instrument: pitched
        )
        let both = try samplerFrequency(
            of: 69, tuning: TuningSettings(referencePitch: .a415),
            offsetCents: -100, instrument: pitched
        )
        let shift = cents(both, from: plain)
        XCTAssertEqual(
            shift, 1200 * log2(415.0 / 440.0) - 100, accuracy: 0.5,
            "A=415 and a −100-cent offset together should move A down about 201 cents; "
                + "they moved it \(shift) — one of them is clamping the other"
        )
    }

    /// **An unpitched instrument in a retuned ensemble is unchanged** — not
    /// approximately, but byte for byte.
    ///
    /// The exemption is the capability model's, the same one that zeroes a
    /// per-instrument tuning offset on an instrument whose samples are pinned to the
    /// pitch they were recorded at. The fixture's sample is a sine rather than a
    /// constant precisely so this claim is falsifiable: a constant resampled at any
    /// rate is the same constant, and the test would pass over one whatever the
    /// engine did.
    func testAnUnpitchedInstrumentIsNotRetuned() throws {
        let unpitched = try SFZFixtures.unpitchedToneInstrument(in: root, sampleRate: samplerRate)
        let provider = try SampledInstrumentVoiceProvider(available: unpitched)
        XCTAssertFalse(
            provider.canBeRetuned,
            "The fixture is supposed to be unpitched; the capability model disagrees"
        )

        func render(_ tuning: TuningSettings) throws -> [Float] {
            let harness = try SampledVoiceHarness(
                unpitched, sampleRate: samplerRate, tuning: tuning
            )
            harness.noteOn(60)
            return harness.render(seconds: 0.4)
        }

        let plain = try render(.standard)
        let retuned = try render(
            TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        )
        XCTAssertEqual(
            plain, retuned,
            "An unpitched instrument was retuned; its samples are pinned to their recorded pitch"
        )

        // And the pitch really is readable, so the comparison above had something
        // to compare: the sample is a 440 Hz sine whatever key is played.
        let measured = Self.sineFrequency(
            Array(plain[Int(0.05 * samplerRate)...]), sampleRate: samplerRate
        )
        XCTAssertEqual(
            measured, 440, accuracy: 2,
            "The unpitched fixture has no readable pitch, so it proves nothing"
        )
    }

    /// A mixed ensemble retunes its pitched lines only — the same two instruments,
    /// in one program, through the real engine.
    func testAMixedEnsembleRetunesItsPitchedLinesOnly() throws {
        let pitched = try SFZFixtures.pitchedInstrument(in: root, sampleRate: samplerRate)
        let unpitched = try SFZFixtures.unpitchedToneInstrument(in: root, sampleRate: samplerRate)
        // `melodyOverAccompaniment` rather than `twoLineFixture`: every note of it
        // is inside both fixtures' key range (48…96), so both lines actually sound.
        // The two-line fixture's lower part is an A2, below the fixtures' lowest
        // key, and a silent line would make the claim below unfalsifiable.
        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        XCTAssertEqual(timeline.lines.count, 2)

        let pitchedProvider = try SampledInstrumentVoiceProvider(available: pitched)
        let unpitchedProvider = try SampledInstrumentVoiceProvider(available: unpitched)
        let assignment = LineVoiceAssignment(
            providersByLine: [
                timeline.lines[0].id: pitchedProvider,
                timeline.lines[1].id: unpitchedProvider
            ]
        )

        /// One line at a time, so each line's own contribution is isolated — mute
        /// is a hard zero on the line's gain, as `BypassRecipeRenderTests` relies
        /// on.
        func render(
            _ tuning: TuningSettings, audible: Int
        ) throws -> PlaybackEngine.RenderedAudio {
            try PlaybackEngine.renderTimelineOffline(
                timeline, sampleRate: samplerRate, voices: assignment, tuning: tuning
            ) { engine in
                for index in 0..<2 where index != audible {
                    engine.mixer(forLineAt: index)?.isMuted = true
                }
            }
        }

        let retuned = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        let pitchedPlain = try render(.standard, audible: 0)
        let pitchedTuned = try render(retuned, audible: 0)
        let unpitchedPlain = try render(.standard, audible: 1)
        let unpitchedTuned = try render(retuned, audible: 1)

        // Both lines sound, or the two comparisons below would be about silence.
        XCTAssertGreaterThan(pitchedPlain.rms(), 0.001, "the pitched line rendered nothing")
        XCTAssertGreaterThan(unpitchedPlain.rms(), 0.001, "the unpitched line rendered nothing")

        XCTAssertNotEqual(
            pitchedPlain.canonicalData(), pitchedTuned.canonicalData(),
            "The pitched line was not retuned"
        )
        XCTAssertEqual(
            unpitchedPlain.canonicalData(), unpitchedTuned.canonicalData(),
            "The unpitched line was retuned; it should have been left alone"
        )
    }

    /// Keyswitch and velocity-layer selection are unchanged apart from pitch: the
    /// same note at the same velocity still chooses the same layer in a retuned
    /// program.
    ///
    /// An invariant #75 states explicitly, and one a rate multiplier could plausibly
    /// break if it had been folded into the region search instead of into the
    /// slot's rate.
    func testVelocityLayerSelectionIsUnchangedByTuning() throws {
        let layered = try SFZFixtures.pitchedLayeredInstrument(in: root, sampleRate: samplerRate)
        let retuned = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)

        for velocity in [20, 63, 64, 127] {
            func level(_ tuning: TuningSettings) throws -> Float {
                let harness = try SampledVoiceHarness(
                    layered, sampleRate: samplerRate, tuning: tuning
                )
                return harness.level(ofNote: 69, velocity: velocity, after: 0.1)
            }
            let plain = try level(.standard)
            let tuned = try level(retuned)
            XCTAssertEqual(
                Double(tuned), Double(plain), accuracy: Double(plain) * 0.05 + 0.001,
                "Velocity \(velocity) chose a different layer once the program was retuned"
            )
        }
    }

    // MARK: The default, and the whole graph

    /// The default tuning changes nothing at all about a render — the same bytes as
    /// the path that never mentions tuning.
    ///
    /// **What this proves and what it cannot.** REQ-006's clause is bit-identity
    /// against *pre-feature* output, and no test inside one build can render a
    /// previous commit; that comparison is made against the merge base by digest and
    /// recorded in the pull request. What this pins, and what a future change could
    /// break, is the property that makes it hold: the default path through the new
    /// parameter is byte-for-byte the unparameterised path, because the table is
    /// exactly the identity (`TuningTests`) and multiplying by exactly 1.0 is the
    /// identity.
    func testTheDefaultTuningRendersTheSameBytesAsNotMentioningTuningAtAll() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "tuning-default", musicXML: MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        let timeline = PerformanceRealizer().realize(score, settings: .standard)

        let untouched = try PlaybackEngine.renderTimelineOffline(timeline, sampleRate: sampleRate)
        let defaulted = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: sampleRate, tuning: .standard
        )
        XCTAssertEqual(
            untouched.canonicalData(), defaulted.canonicalData(),
            "Passing the default tuning changed the render, so the default is not the identity"
        )

        // The vacuity guard: this fixture *is* sensitive to tuning.
        let retuned = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: sampleRate,
            tuning: TuningSettings(temperament: .werckmeisterIII)
        )
        XCTAssertNotEqual(
            untouched.canonicalData(), retuned.canonicalData(),
            "A non-default tuning left no trace, so the comparison above proves nothing"
        )
    }

    /// A tuning is deterministic: the same program rendered twice is the same audio.
    func testARetunedProgramRendersIdenticallyTwice() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "tuning-determinism",
            musicXML: MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        let timeline = PerformanceRealizer().realize(score, settings: .standard)
        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)

        let first = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: sampleRate, tuning: tuning
        )
        let second = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: sampleRate, tuning: tuning
        )
        XCTAssertEqual(first.canonicalData(), second.canonicalData())
    }

    /// …and independent of how the host chops the buffer, which is what says the
    /// table is read at note-on rather than somewhere that depends on block
    /// boundaries.
    func testARetunedProgramRendersIdenticallyAtAnyBufferSize() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "tuning-blocks", musicXML: MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        let timeline = PerformanceRealizer().realize(score, settings: .standard)
        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)

        func render(inBlocksOf frames: Int64) throws -> Data {
            let engine = PlaybackEngine()
            try engine.setRenderMode(.offline(sampleRate: sampleRate))
            try engine.setTuning(tuning)
            try engine.load(timeline: timeline)
            engine.play()
            let total = try XCTUnwrap(engine.loadedProgram).totalFrames
            var left: [Float] = []
            var right: [Float] = []
            var remaining = total
            while remaining > 0 {
                let chunk = try engine.renderOffline(frameCount: min(frames, remaining))
                left.append(contentsOf: chunk.left)
                right.append(contentsOf: chunk.right)
                remaining -= Int64(chunk.frameCount)
                if chunk.frameCount == 0 { break }
            }
            return PlaybackEngine.RenderedAudio(sampleRate: sampleRate, left: left, right: right)
                .canonicalData()
        }

        XCTAssertEqual(try render(inBlocksOf: 64), try render(inBlocksOf: 4096))
    }

    /// The engine reports the tuning it was actually given, and a value already in
    /// force costs no rebuild.
    func testTheEngineReportsItsTuningAndIgnoresARepeat() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "tuning-engine", musicXML: AudioRenderFixtures.twoLineFixture()
        )
        let timeline = PerformanceRealizer().realize(score, settings: .literal)
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: sampleRate))
        try engine.load(timeline: timeline)

        XCTAssertEqual(engine.tuning, .standard)
        let programBefore = try XCTUnwrap(engine.loadedProgram)
        XCTAssertEqual(programBefore.tuning, .standard)

        try engine.setTuning(.standard)
        XCTAssertTrue(
            engine.loadedProgram === programBefore,
            "Setting the tuning it already had rebuilt the program"
        )

        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        try engine.setTuning(tuning)
        XCTAssertEqual(engine.tuning, tuning)
        let programAfter = try XCTUnwrap(engine.loadedProgram)
        XCTAssertFalse(
            programAfter === programBefore,
            "A tuning change has to rebuild the program; voices read the table when built"
        )
        XCTAssertEqual(programAfter.tuning, tuning)
    }

    /// A tuning change keeps the playhead and the mix, the way a sound change does.
    ///
    /// The playhead is read after a render on either side, because a seek lands when
    /// the render thread applies it rather than when it is asked for — so a test that
    /// read the position straight after the call would be measuring the request, not
    /// the playhead.
    func testATuningChangeKeepsThePlayheadAndTheMix() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "tuning-carry", musicXML: MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        let timeline = PerformanceRealizer().realize(score, settings: .standard)
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: sampleRate))
        try engine.load(timeline: timeline)

        engine.mixer(forLineAt: 0)?.gain = 0.25
        engine.mixer(forLineAt: 0)?.pan = -0.75
        engine.mixer(forLineAt: 1)?.isMuted = true

        engine.seek(toMicroseconds: 1_500_000)
        engine.play()
        _ = try engine.renderOffline(frameCount: 8192)
        let before = engine.playbackPositionMicroseconds
        XCTAssertGreaterThan(before, 1_400_000, "the seek never landed, so nothing is carried")

        try engine.setTuning(TuningSettings(temperament: .werckmeisterIII))

        _ = try engine.renderOffline(frameCount: 8192)
        XCTAssertEqual(
            engine.playbackPositionMicroseconds, before, accuracy: 400_000,
            "the playhead did not survive the rebuild a tuning change costs"
        )
        XCTAssertEqual(engine.mixer(forLineAt: 0)?.gain, 0.25)
        XCTAssertEqual(engine.mixer(forLineAt: 0)?.pan, -0.75)
        XCTAssertEqual(engine.mixer(forLineAt: 1)?.isMuted, true)
        XCTAssertEqual(engine.transportState, .playing, "the transport stopped rather than resumed")
    }
}
