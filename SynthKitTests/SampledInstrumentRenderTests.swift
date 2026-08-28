import XCTest
@testable import SynthKit

/// Issue #23: "Each curated library loads and its instruments sound correct
/// across their mapped ranges", "offline render of an instrument line is
/// deterministic across runs", and the failure behaviour for missing or corrupt
/// samples.
///
/// **Every claim here is a measurement of rendered audio.** The fixtures are
/// built so that each sample is a distinct constant level (see `SFZFixtures`),
/// so "velocity 100 chose the loud layer" is answered by the number that came
/// out of the render callback rather than by asking the player what it selected.
/// The one exception is pitch, where the sample is a sine and the test measures
/// the frequency.
///
/// The fixtures are generated, not downloaded: the curated set is 3.2 GB and
/// lives in the app container, so CI stays hermetic and the real libraries are
/// covered by the manual smoke and by `CuratedInstrumentAssetTests` when they
/// are present.
final class SampledInstrumentRenderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try SFZFixtures.makeLibraryDirectory()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Key mapping and pitch

    /// A region maps across its key range and transposes from its keycentre.
    ///
    /// The sample is A440 with `pitch_keycenter=69`, so the key played is the
    /// pitch that must come out: 69 gives 440 Hz, 81 an octave above it.
    func testAKeyPlaysAtItsOwnPitchFromTheSamplesKeycentre() throws {
        let instrument = try SFZFixtures.pitchedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        for (note, expected) in [(69, 440.0), (81, 880.0), (62, 440.0 * pow(2, -7.0 / 12))] {
            harness.reset()
            harness.noteOn(note)
            let samples = harness.render(seconds: 0.3)
            let measured = SampledVoiceHarness.frequency(of: samples, sampleRate: harness.sampleRate)
            harness.noteOff(note)
            _ = harness.render(seconds: 0.05)

            XCTAssertEqual(
                measured, expected, accuracy: expected * 0.01,
                "Key \(note) should sound at \(expected) Hz, not \(measured) Hz."
            )
        }
    }

    /// A key outside every region's range sounds nothing, and says so.
    ///
    /// Silence is the right audio, but a line assigned an instrument that
    /// cannot reach its part should be visible rather than mysterious — so the
    /// voice counts it.
    func testAKeyOutsideTheSampledRangeIsSilentAndCounted() throws {
        let instrument = try SFZFixtures.pitchedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        harness.noteOn(30)
        let samples = harness.render(seconds: 0.2)
        XCTAssertEqual(SampledVoiceHarness.peak(samples), 0, "An unmapped key must be silent.")
        XCTAssertEqual(
            harness.telemetry.unmappedNotes, 1,
            "A note that reached no region has to be counted, or a line assigned an instrument "
                + "that cannot play its part fails invisibly."
        )
        XCTAssertEqual(harness.telemetry.stolenSlots, 0)
    }

    /// A dense, pedalled passage does not run out of slots.
    ///
    /// `SAMPLE_VOICE_MAX_SLOTS` is 128 because a pedalled piano line holds far
    /// more notes than it plays. This is the check that the number is big
    /// enough for real writing rather than a hope: forty notes held under the
    /// pedal, each with its own release layer to follow.
    func testADensePedalledPassageNeverRunsOutOfSlots() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.3, seconds: 4.0), to: root.appending(path: "note.wav")
        )
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.1, seconds: 1.0), to: root.appending(path: "release.wav")
        )
        // Forty playable keys, each with a release layer to follow it, so the
        // pedalled passage below really does ask for eighty slots at once.
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=2 amp_veltrack=0 pitch_keytrack=0
            <region> sample=note.wav lokey=40 hikey=80 pitch_keycenter=60

            <group> trigger=release ampeg_attack=0 ampeg_release=1 amp_veltrack=0
              pitch_keytrack=0
            <region> sample=release.wav lokey=40 hikey=80 pitch_keycenter=60
            """,
            in: root, instrumentName: "Dense"
        )
        let harness = try SampledVoiceHarness(instrument)

        harness.setSustainPedal(true)
        for note in 40..<80 {
            harness.noteOn(note, velocity: 90)
            _ = harness.render(seconds: 0.01)
            harness.noteOff(note)
        }
        harness.setSustainPedal(false)
        _ = harness.render(seconds: 0.5)

        XCTAssertGreaterThanOrEqual(
            harness.telemetry.peakSlots, 40,
            "Forty held notes should have been sounding at once; only "
                + "\(harness.telemetry.peakSlots) were."
        )
        XCTAssertEqual(harness.telemetry.unmappedNotes, 0)
        XCTAssertEqual(
            harness.telemetry.stolenSlots, 0,
            "The voice had to steal a sounding slot, so 128 is not enough for this passage."
        )
    }

    /// `pitch_keytrack=0` pins a sample to its recorded pitch. Salamander's
    /// hammer noise relies on this: a thud does not transpose with the key.
    func testPitchKeytrackZeroPinsTheSampleToItsRecordedPitch() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 300, seconds: 0.6), to: root.appending(path: "fixed.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=fixed.wav lokey=40 hikey=90 pitch_keycenter=60
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument)

        for note in [50, 60, 80] {
            harness.reset()
            harness.noteOn(note)
            let measured = SampledVoiceHarness.frequency(
                of: harness.render(seconds: 0.3), sampleRate: harness.sampleRate
            )
            harness.noteOff(note)
            _ = harness.render(seconds: 0.02)
            XCTAssertEqual(measured, 300, accuracy: 6, "Key \(note) should not transpose.")
        }
    }

    // MARK: - Velocity layers

    /// Three sampled dynamics on one key, each selected by its own velocity
    /// window. This is the claim issue #23 spot-checks on Salamander, whose
    /// sixteen layers work exactly this way.
    func testVelocitySelectsTheMatchingSampledLayer() throws {
        let instrument = try SFZFixtures.velocityLayeredInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        let soft = harness.level(ofNote: 60, velocity: 20)
        let mid = harness.level(ofNote: 60, velocity: 60)
        let loud = harness.level(ofNote: 60, velocity: 110)

        XCTAssertEqual(soft, 0.10, accuracy: 0.01)
        XCTAssertEqual(mid, 0.40, accuracy: 0.01)
        XCTAssertEqual(loud, 0.80, accuracy: 0.02)
    }

    /// `amp_veltrack` scales loudness with velocity where a library has no
    /// sampled layers — which is most of the curated set outside Salamander.
    func testAmpVeltrackScalesLoudnessWithVelocity() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5), to: root.appending(path: "flat.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=100 pitch_keytrack=0
            <region> sample=flat.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument)

        let quiet = harness.level(ofNote: 60, velocity: 32)
        let full = harness.level(ofNote: 60, velocity: 127)

        // amp_veltrack=100 makes amplitude follow velocity squared.
        XCTAssertEqual(Double(full), 0.5, accuracy: 0.02)
        XCTAssertEqual(Double(quiet), 0.5 * pow(32.0 / 127.0, 2), accuracy: 0.01)
    }

    /// `volume` is in decibels, and +6 dB is twice the amplitude. VSCO 2 writes
    /// `volume=12` on its quiet layers, so getting the unit wrong would make a
    /// whole library four times too loud.
    func testVolumeIsAppliedInDecibels() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.2), to: root.appending(path: "flat.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=flat.wav lokey=60 hikey=60 pitch_keycenter=60 volume=6
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument)
        XCTAssertEqual(Double(harness.level(ofNote: 60)), 0.4, accuracy: 0.01)
    }

    // MARK: - Round robins

    /// `seq_length`/`seq_position` cycles the alternates in order, so a
    /// repeated note is not the identical sample every time. VSCO 2's short
    /// articulations depend on this.
    func testRoundRobinsCycleInOrder() throws {
        let instrument = try SFZFixtures.sequencedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        let levels = (0..<6).map { _ in harness.level(ofNote: 60) }
        for (index, level) in levels.enumerated() {
            let expected: Float = [0.10, 0.40, 0.70][index % 3]
            XCTAssertEqual(
                level, expected, accuracy: 0.01,
                "Repetition \(index + 1) should play round robin \(index % 3 + 1)."
            )
        }
    }

    /// `lorand`/`hirand` picks an alternate at random — and, because the draw
    /// is seeded, picks the *same* alternate on every run. Two voices with the
    /// same seed must agree note for note.
    func testRandomRoundRobinsAreSeededAndThereforeReproducible() throws {
        let instrument = try SFZFixtures.randomisedInstrument(in: root)

        let first = try SampledVoiceHarness(instrument, renderSeed: 12345)
        let second = try SampledVoiceHarness(instrument, renderSeed: 12345)
        let different = try SampledVoiceHarness(instrument, renderSeed: 999)

        let a = (0..<24).map { _ in first.level(ofNote: 60) }
        let b = (0..<24).map { _ in second.level(ofNote: 60) }
        let c = (0..<24).map { _ in different.level(ofNote: 60) }

        XCTAssertEqual(a, b, "The same seed must make the same choices.")
        XCTAssertNotEqual(
            a, c, "A different seed should vary; if it does not, the draw is not being used."
        )

        // Both alternates must actually come up, or the "random" is a constant.
        XCTAssertTrue(a.contains { abs($0 - 0.20) < 0.01 })
        XCTAssertTrue(a.contains { abs($0 - 0.60) < 0.01 })
    }

    /// `reset` returns the seeded sequence to its start, so seeking does not
    /// change which round robin a passage plays. Without this, an export from
    /// bar 40 would not match a live listen from bar 40.
    func testResetRewindsTheSeededSequence() throws {
        let instrument = try SFZFixtures.randomisedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument, renderSeed: 4242)

        let before = (0..<12).map { _ in harness.level(ofNote: 60) }
        harness.reset()
        let after = (0..<12).map { _ in harness.level(ofNote: 60) }

        XCTAssertEqual(before, after)
    }

    // MARK: - Loops

    /// A sample with `smpl` loop points and no SFZ opcode loops, per SFZ 1.0.
    ///
    /// The fixture's loop body is a different level from its head, so a render
    /// running well past the end of the sample proves the loop by still
    /// producing the body's level where an unlooped sample would be silent.
    func testASampleWithFileLoopPointsSustainsIndefinitely() throws {
        let instrument = try SFZFixtures.loopedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        harness.noteOn(60)
        // The sample is 0.2 s long; render five times that.
        let samples = harness.render(seconds: 1.0)
        harness.noteOff(60)

        let tail = SampledVoiceHarness.meanAbsolute(samples.suffix(2000))
        XCTAssertEqual(
            tail, 0.2, accuracy: 0.02,
            "A looped sample must still be sounding its loop body long after the file ends."
        )
    }

    /// Without loop points the sample stops when it runs out, rather than
    /// looping or reading past the end of the mapping.
    func testAnUnloopedSampleStopsAtItsEnd() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5, seconds: 0.1), to: root.appending(path: "short.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=short.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument)

        harness.noteOn(60)
        let samples = harness.render(seconds: 0.5)
        XCTAssertEqual(
            SampledVoiceHarness.peak(samples.suffix(4000)), 0, accuracy: 1e-6,
            "An unlooped sample must go silent when it runs out."
        )
    }

    // MARK: - Release triggers

    /// `trigger=release` starts a second sample when the note ends, and
    /// `rt_decay` makes it quieter the longer the note was held.
    ///
    /// Issue #23 spot-checks release samples on the harpsichord. There is no
    /// harpsichord in the delivered catalog (INS001's owner-ruled REQ-020
    /// shortfall), so the real-asset check moved to Salamander Grand Piano,
    /// whose string resonances and hammer noise are exactly this mechanism at
    /// 6 to 9 dB per second.
    func testAReleaseTriggerFiresOnNoteOffAndDecaysWithHoldTime() throws {
        let instrument = try SFZFixtures.releaseTriggeredInstrument(
            in: root, releaseDecayDBPerSecond: 6
        )

        func releaseLevel(afterHolding seconds: Double) throws -> Float {
            let harness = try SampledVoiceHarness(instrument)
            harness.noteOn(60, velocity: 100)
            _ = harness.render(seconds: seconds)
            harness.noteOff(60)
            // Far enough past the note's own 10 ms release that only the
            // release sample is left.
            let tail = harness.render(seconds: 0.2)
            return SampledVoiceHarness.meanAbsolute(tail.suffix(2000))
        }

        let short = try releaseLevel(afterHolding: 0.05)
        let long = try releaseLevel(afterHolding: 2.0)

        XCTAssertGreaterThan(short, 0.1, "The release sample must sound at all.")
        // Two seconds at 6 dB/s is 12 dB down: a quarter of the amplitude.
        XCTAssertEqual(Double(long / short), pow(10.0, -12.0 / 20.0), accuracy: 0.08)
    }

    /// The release trigger fires when the damper actually falls, which with the
    /// pedal down is when the pedal lifts — not when the key comes up.
    func testTheSustainPedalHoldsNotesAndDelaysTheirReleaseTrigger() throws {
        // `rt_decay=0` here so the level after the pedal lifts is the release
        // layer's own, undimmed by hold time — the decay itself is measured in
        // the test above.
        let instrument = try SFZFixtures.releaseTriggeredInstrument(
            in: root, releaseDecayDBPerSecond: 0
        )
        let harness = try SampledVoiceHarness(instrument)

        harness.setSustainPedal(true)
        harness.noteOn(60)
        _ = harness.render(seconds: 0.1)
        harness.noteOff(60)

        // The note layer is 0.5 and the release layer is 0.2, so the level
        // alone says which of the two is sounding.
        let pedalled = harness.render(seconds: 0.2)
        XCTAssertEqual(
            SampledVoiceHarness.meanAbsolute(pedalled.suffix(2000)), 0.5, accuracy: 0.02,
            "A note released under the pedal must keep sounding at full level."
        )

        harness.setSustainPedal(false)
        let afterPedal = harness.render(seconds: 0.3)
        XCTAssertEqual(
            SampledVoiceHarness.meanAbsolute(afterPedal.suffix(2000)), 0.2, accuracy: 0.03,
            "Lifting the pedal must release the note and leave only its release layer."
        )
    }

    /// `ampeg_release` fades the note rather than cutting it off.
    func testTheAmplitudeEnvelopeReleaseFadesRatherThanCuts() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5, seconds: 4.0), to: root.appending(path: "long.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.5 amp_veltrack=0 pitch_keytrack=0
            <region> sample=long.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument)

        harness.noteOn(60)
        _ = harness.render(seconds: 0.2)
        harness.noteOff(60)
        let tail = harness.render(seconds: 0.6)

        let early = SampledVoiceHarness.meanAbsolute(tail.prefix(1000))
        let middle = SampledVoiceHarness.meanAbsolute(tail[8000..<9000])
        let end = SampledVoiceHarness.meanAbsolute(tail.suffix(1000))

        XCTAssertGreaterThan(early, 0.4)
        XCTAssertLessThan(middle, early, "The release must be falling, not a step.")
        XCTAssertLessThan(end, 0.01, "The release must reach silence.")
    }

    // MARK: - Keyswitches

    /// A keyswitched instrument plays one articulation, not all of them at
    /// once, and a note in the switch range changes which.
    func testAKeyswitchSelectsOneArticulation() throws {
        let instrument = try SFZFixtures.keyswitchedInstrument(in: root)
        let harness = try SampledVoiceHarness(instrument)

        XCTAssertEqual(
            harness.level(ofNote: 60), 0.30, accuracy: 0.01,
            "The default switch (c1) selects articulation A alone."
        )

        // c#1 = 25 is the second switch.
        harness.noteOn(25, velocity: 100)
        XCTAssertEqual(
            SampledVoiceHarness.peak(harness.render(seconds: 0.05)), 0,
            "A keyswitch selects an articulation; it does not sound."
        )
        harness.noteOff(25)

        XCTAssertEqual(
            harness.level(ofNote: 60), 0.70, accuracy: 0.01,
            "After the switch, articulation B plays."
        )
    }

    // MARK: - Sample formats

    /// Every encoding and channel count the curated set contains, plus a chunk
    /// before the audio and a rate that is not the render rate.
    ///
    /// The set has 16- and 24-bit PCM and 32-bit float, mono and stereo, at
    /// 44.1 and 48 kHz, and 455 of its files carry a `junk` chunk between the
    /// header and the audio. Each of those is a way to read the wrong bytes.
    func testEveryEncodingInTheCuratedSetReadsBackAtTheRightLevel() throws {
        let cases: [(String, SFZFixtures.Encoding, Int, Double, Bool)] = [
            ("pcm16-mono", .pcm16, 1, 44_100, false),
            ("pcm16-stereo-junk", .pcm16, 2, 44_100, true),
            ("pcm24-stereo", .pcm24, 2, 44_100, false),
            ("pcm32-mono", .pcm32, 1, 44_100, false),
            ("float32-stereo", .float32, 2, 48_000, false)
        ]

        for (name, encoding, channels, rate, junk) in cases {
            let directory = try SFZFixtures.makeLibraryDirectory(name)
            defer { try? FileManager.default.removeItem(at: directory) }

            try SFZFixtures.writeWave(
                SFZFixtures.constant(0.5, seconds: 1.0, sampleRate: rate),
                to: directory.appending(path: "sample.wav"),
                sampleRate: rate,
                channels: channels,
                encoding: encoding,
                extraChunkBeforeData: junk
            )
            let instrument = try SFZFixtures.writeInstrument(
                """
                <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
                <region> sample=sample.wav lokey=60 hikey=60 pitch_keycenter=60
                """,
                in: directory
            )
            let harness = try SampledVoiceHarness(instrument, sampleRate: 44_100)
            XCTAssertEqual(
                Double(harness.level(ofNote: 60)), 0.5, accuracy: 0.02,
                "\(name) did not read back at its recorded level."
            )
        }
    }

    /// A 48 kHz sample in a 44.1 kHz render is resampled, not transposed.
    ///
    /// Etherealwinds ships 48 kHz files; playing them without the rate ratio
    /// would put the whole harp 1.6 semitones sharp.
    func testASampleAtAnotherRateIsResampledRatherThanTransposed() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 440, seconds: 1.0, sampleRate: 48_000),
            to: root.appending(path: "a440-48k.wav"),
            sampleRate: 48_000
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0
            <region> sample=a440-48k.wav lokey=69 hikey=69 pitch_keycenter=69
            """,
            in: root
        )
        let harness = try SampledVoiceHarness(instrument, sampleRate: 44_100)
        harness.noteOn(69)
        let measured = SampledVoiceHarness.frequency(
            of: harness.render(seconds: 0.4), sampleRate: 44_100
        )
        XCTAssertEqual(measured, 440, accuracy: 5)
    }

    // MARK: - Failure behaviour

    /// Issue #23: "Missing/corrupt sample files at load: instrument marked
    /// unavailable with a clear reason."
    ///
    /// One missing sample is not the whole instrument, so the rest still plays
    /// and the missing one is reported by name.
    func testAMissingSampleIsReportedAndTheRestOfTheInstrumentPlays() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5), to: root.appending(path: "present.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=present.wav lokey=60 hikey=60 pitch_keycenter=60
            <region> sample=gone.wav lokey=62 hikey=62 pitch_keycenter=62
            """,
            in: root
        )

        let loaded = try SampledInstrument(instrument)
        XCTAssertEqual(loaded.features.unplayableSamples.map(\.path), ["gone.wav"])
        XCTAssertFalse(
            loaded.features.unplayableSamples[0].reason.isEmpty,
            "A missing sample has to say why it is missing."
        )

        let harness = try SampledVoiceHarness(instrument)
        XCTAssertEqual(Double(harness.level(ofNote: 60)), 0.5, accuracy: 0.02)
        XCTAssertEqual(harness.level(ofNote: 62), 0, "The missing region cannot sound.")
    }

    /// When nothing is left to play, the instrument is unavailable — with the
    /// reason and the re-download path INS001 owns.
    func testAnInstrumentWithNoReadableSamplesIsUnavailableWithAReason() throws {
        let instrument = try SFZFixtures.writeInstrument(
            "<region> sample=gone.wav lokey=60 hikey=60", in: root, instrumentName: "Broken"
        )

        XCTAssertThrowsError(try SampledInstrument(instrument)) { error in
            guard let failure = error as? SampledInstrument.LoadError else {
                return XCTFail("Expected a LoadError, got \(error).")
            }
            XCTAssertTrue(failure.description.contains("Broken"))
            XCTAssertTrue(failure.recoverySuggestion.contains("Re-download"))
        }
    }

    /// An SFZ cannot name a file outside the library it belongs to.
    ///
    /// The curated files are pinned by digest so this is not a live threat, but
    /// an SFZ is third-party text that names files to open, and a `..` in one
    /// must never become a read outside the installed library. Held by
    /// construction rather than by the catalog continuing to be trustworthy.
    func testASamplePathCannotEscapeTheInstalledLibrary() throws {
        let outside = root.deletingLastPathComponent()
            .appending(path: "outside-\(UUID().uuidString).wav")
        try SFZFixtures.writeWave(SFZFixtures.constant(0.9), to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.3), to: root.appending(path: "inside.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=inside.wav lokey=60 hikey=60 pitch_keycenter=60
            <region> sample=../\(outside.lastPathComponent) lokey=62 hikey=62 pitch_keycenter=62
            """,
            in: root, instrumentName: "Escaping"
        )

        let loaded = try SampledInstrument(instrument)
        XCTAssertEqual(loaded.features.unplayableSamples.count, 1)
        XCTAssertTrue(
            loaded.features.unplayableSamples[0].reason.contains("outside"),
            "Got: \(loaded.features.unplayableSamples[0].reason)"
        )

        let harness = try SampledVoiceHarness(instrument)
        XCTAssertEqual(Double(harness.level(ofNote: 60)), 0.3, accuracy: 0.02)
        XCTAssertEqual(harness.level(ofNote: 62), 0, "The escaping region must not sound.")
    }

    /// A corrupt file is a load failure with a reason, not a crash and not
    /// noise on the audio thread.
    func testACorruptSampleFileIsRejectedWithAReason() throws {
        try Data("this is not a wave file at all, not even a little bit of one".utf8)
            .write(to: root.appending(path: "corrupt.wav"))
        let instrument = try SFZFixtures.writeInstrument(
            "<region> sample=corrupt.wav lokey=60 hikey=60", in: root, instrumentName: "Corrupt"
        )

        XCTAssertThrowsError(try SampledInstrument(instrument)) { error in
            XCTAssertTrue("\(error)".contains("Corrupt"))
        }
    }

    /// Issue #23: "a playing line whose asset disappears degrades to
    /// silence-with-flag, not a crash."
    ///
    /// What actually happens is better than silence and is worth being precise
    /// about: the samples are mapped, and POSIX keeps a mapping valid after the
    /// directory entry goes, so the note that is already sounding finishes. The
    /// flag arrives on the next load, where the instrument becomes unavailable
    /// with a reason and INS001's re-download path. Neither step crashes, which
    /// is the property the criterion is really about.
    func testAnAssetDeletedDuringPlaybackDoesNotCrashAndIsFlaggedOnReload() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5, seconds: 4.0), to: root.appending(path: "vanishing.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=vanishing.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root, instrumentName: "Vanishing"
        )

        let harness = try SampledVoiceHarness(instrument)
        harness.noteOn(60)
        _ = harness.render(seconds: 0.1)

        try FileManager.default.removeItem(at: root.appending(path: "vanishing.wav"))

        let afterDeletion = harness.render(seconds: 0.5)
        XCTAssertEqual(
            SampledVoiceHarness.meanAbsolute(afterDeletion.suffix(2000)), 0.5, accuracy: 0.02,
            "The sounding note reads a mapping, which outlives the directory entry."
        )
        harness.noteOff(60)
        _ = harness.render(seconds: 0.1)

        // The flag: loading it again cannot find the file, and says so.
        XCTAssertThrowsError(try SampledInstrument(instrument)) { error in
            guard let failure = error as? SampledInstrument.LoadError else {
                return XCTFail("Expected a LoadError, got \(error).")
            }
            XCTAssertTrue(failure.description.contains("Vanishing"))
            XCTAssertTrue(failure.recoverySuggestion.contains("Re-download"))
        }
    }

    /// An SFZ that names an unsupported opcode still plays, and reports it.
    func testAnUnsupportedOpcodeDoesNotStopAnInstrumentSounding() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.5), to: root.appending(path: "flat.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_dynamic=1 cutoff=500 pan=-50
              ampeg_attack=0 ampeg_release=0.01 amp_veltrack=0 pitch_keytrack=0
            <region> sample=flat.wav lokey=60 hikey=60 pitch_keycenter=60
            """,
            in: root
        )

        let loaded = try SampledInstrument(instrument)
        XCTAssertEqual(
            Set(loaded.features.unsupported.map(\.name)), ["ampeg_dynamic", "cutoff", "pan"]
        )

        let harness = try SampledVoiceHarness(instrument)
        XCTAssertEqual(Double(harness.level(ofNote: 60)), 0.5, accuracy: 0.02)
    }

    // MARK: - The INS003 surface

    /// What INS003 gates customization on, measured from the files rather than
    /// taken from the catalog's editorial note.
    func testFeaturesReportWhatTheSamplesActuallyOffer() throws {
        let layered = try SampledInstrument(
            try SFZFixtures.velocityLayeredInstrument(in: root)
        )
        XCTAssertEqual(layered.features.velocityLayerCount, 3)
        XCTAssertEqual(layered.features.roundRobinDepth, 1)
        XCTAssertFalse(layered.features.hasReleaseTriggers)
        XCTAssertFalse(layered.features.hasSustainLoops)
        XCTAssertEqual(layered.features.playableKeyRange, 60...60)
        XCTAssertEqual(layered.features.sampleCount, 3)

        let sequenced = try SampledInstrument(
            try SFZFixtures.sequencedInstrument(in: try SFZFixtures.makeLibraryDirectory("seq"))
        )
        XCTAssertEqual(sequenced.features.roundRobinDepth, 3)
        XCTAssertEqual(sequenced.features.velocityLayerCount, 1)

        let looped = try SampledInstrument(
            try SFZFixtures.loopedInstrument(in: try SFZFixtures.makeLibraryDirectory("loop"))
        )
        XCTAssertTrue(looped.features.hasSustainLoops)

        let released = try SampledInstrument(
            try SFZFixtures.releaseTriggeredInstrument(
                in: try SFZFixtures.makeLibraryDirectory("rel")
            )
        )
        XCTAssertTrue(released.features.hasReleaseTriggers)
        XCTAssertGreaterThan(
            released.features.releaseTailSeconds, 0.9,
            "The tail has to cover the release sample, or an export truncates it."
        )
    }

    /// The instrument is mapped, not read: address space is large and resident
    /// memory is a fraction of it. This is the shape of the REQ-013 memory
    /// claim, checked on a fixture so it is a property of the design rather
    /// than of one machine's page cache.
    func testSamplesAreMappedWithOnlyTheirAttacksResident() throws {
        // Twelve seconds of 44.1 kHz mono 16-bit: about 1 MB, four times the
        // 256 kB attack window.
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.3, seconds: 12.0), to: root.appending(path: "long.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            "<region> sample=long.wav lokey=60 hikey=60 pitch_keycenter=60", in: root
        )
        let loaded = try SampledInstrument(instrument)

        XCTAssertGreaterThan(loaded.features.mappedByteCount, 1_000_000)
        XCTAssertLessThanOrEqual(
            loaded.features.residentByteCount,
            Int64(SampleWaveform.attackWarmByteCount),
            "Loading an instrument must not fault in the whole sample."
        )
        XCTAssertGreaterThan(
            loaded.features.residentByteCount, 0,
            "The attack must be resident, or the first note reads from disk."
        )
    }
}
