import XCTest
@testable import SynthKit

/// Issue #23's whole-pipeline claims: "Implementation of the PLY003 line-voice
/// interface, so assignment, mixing, presets, and export work unchanged over
/// instruments", and "offline render of an instrument line is deterministic
/// across runs".
///
/// These go through `PlaybackEngine` rather than the voice harness on purpose.
/// A claim about determinism, about a mixer strip, or about one line being a
/// sampled instrument while another is a synth patch is a claim about the whole
/// graph, and the voice on its own cannot answer any of them.
final class SampledInstrumentPipelineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try SFZFixtures.makeLibraryDirectory("pipeline")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// An instrument that covers the whole two-line fixture: A2 in the bass and
    /// A5 on top, with round robins so a determinism failure would be audible
    /// rather than theoretical.
    private func wideInstrument() throws -> AvailableInstrument {
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 220, seconds: 2.0), to: root.appending(path: "a3-1.wav")
        )
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 220, seconds: 2.0, amplitude: 0.35),
            to: root.appending(path: "a3-2.wav")
        )
        return try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0.005 ampeg_release=0.2 amp_veltrack=60
              lokey=21 hikey=108 pitch_keycenter=57
            <region> sample=a3-1.wav lorand=0 hirand=0.5
            <region> sample=a3-2.wav lorand=0.5 hirand=1
            """,
            in: root, instrumentName: "Wide"
        )
    }

    // MARK: - Determinism

    /// REQ-012 and REQ-026: two offline renders of the same instrument line are
    /// byte-identical.
    ///
    /// The fixture varies at random between two samples on every note, so this
    /// is not the trivial case: without a seeded draw the two renders would
    /// differ on the notes that happened to choose differently, and a test that
    /// only compared RMS would never notice.
    func testTwoOfflineRendersOfAnInstrumentLineAreByteIdentical() throws {
        let instrument = try wideInstrument()
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        func render() throws -> Data {
            let provider = try SampledInstrumentVoiceProvider(available: instrument)
            return try PlaybackEngine.renderTimelineOffline(
                timeline, sampleRate: 44_100, voiceProvider: provider
            ).canonicalData()
        }

        let first = try render()
        let second = try render()

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(
            first, second,
            "Two renders of the same instrument line differ, so the round-robin draw is not seeded."
        )
    }

    /// A different seed produces a different performance — otherwise the seed
    /// is not reaching the draw and the test above proves nothing.
    func testADifferentSeedProducesADifferentPerformance() throws {
        let instrument = try wideInstrument()
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        func render(seed: UInt64) throws -> Data {
            let provider = try SampledInstrumentVoiceProvider(
                available: instrument, renderSeed: seed
            )
            return try PlaybackEngine.renderTimelineOffline(
                timeline, sampleRate: 44_100, voiceProvider: provider
            ).canonicalData()
        }

        XCTAssertNotEqual(try render(seed: 1), try render(seed: 2))
    }

    // MARK: - Per-line assignment

    /// REQ-006: one line on a sampled instrument, another on a synth patch, in
    /// the same program.
    ///
    /// The point is not that it sounds nice; it is that nothing in
    /// `RenderProgram`, `PlaybackEngine` or the mixer had to learn what a
    /// sample is. If a special case had leaked into the engine, this is where
    /// it would show up.
    func testASampledLineAndASynthLinePlayInTheSameProgram() throws {
        let instrument = try wideInstrument()
        let provider = try SampledInstrumentVoiceProvider(available: instrument)
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let sampledLine = timeline.lines[0].id
        let assignment = LineVoiceAssignment { lineID -> LineVoiceProvider in
            lineID == sampledLine ? provider : SynthPatchVoiceProvider()
        }

        let mixed = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: assignment
        )
        XCTAssertGreaterThan(mixed.rms(), 0.001, "Both lines must be audible.")

        // Muting the sampled line has to change the mix, which is only true if
        // the engine is treating it as an ordinary line.
        let muted = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: assignment
        ) { engine in
            engine.mixer(forLineAt: 0)?.isMuted = true
        }
        XCTAssertNotEqual(mixed.canonicalData(), muted.canonicalData())
        XCTAssertLessThan(muted.rms(), mixed.rms())
    }

    /// The engine owns level: doubling a line's gain doubles what comes out.
    ///
    /// `SynthLineVoice` says a voice must not apply any level of its own, and a
    /// sampler is where that rule is easiest to break — a `volume` opcode is
    /// right there. This checks the contract from the outside.
    func testTheEngineOwnsAnInstrumentLinesGain() throws {
        let instrument = try wideInstrument()
        let provider = try SampledInstrumentVoiceProvider(available: instrument)
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let assignment = LineVoiceAssignment.uniform(provider)

        let unity = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: assignment
        )
        let quiet = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: assignment
        ) { engine in
            engine.mixer(forLineAt: 0)?.gain = 0.5
            engine.mixer(forLineAt: 1)?.gain = 0.5
        }

        XCTAssertEqual(quiet.rms(), unity.rms() / 2, accuracy: unity.rms() * 0.02)
    }

    /// The release tail an instrument declares is what the program renders
    /// past its last note.
    ///
    /// `RenderProgram` reads `releaseTailSeconds` from the provider, so an
    /// instrument with a ten-second release — Etherealwinds writes exactly
    /// that — must make the program longer, or an export cuts the harp off.
    func testTheInstrumentsOwnReleaseTailExtendsTheProgram() throws {
        try SFZFixtures.writeWave(
            SFZFixtures.constant(0.4, seconds: 1.0), to: root.appending(path: "long.wav")
        )
        let instrument = try SFZFixtures.writeInstrument(
            """
            <group> ampeg_attack=0 ampeg_release=6 amp_veltrack=0
            <region> sample=long.wav lokey=21 hikey=108 pitch_keycenter=57
            """,
            in: root, instrumentName: "LongTail"
        )
        let provider = try SampledInstrumentVoiceProvider(available: instrument)
        XCTAssertEqual(provider.releaseTailSeconds, 6, accuracy: 0.01)

        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let long = try RenderProgram(
            timeline: timeline, sampleRate: 44_100, voices: .uniform(provider)
        )
        let short = try RenderProgram(
            timeline: timeline, sampleRate: 44_100, voices: .uniform(SynthPatchVoiceProvider())
        )
        XCTAssertGreaterThan(long.totalFrames, short.totalFrames)
    }

    // MARK: - Sharing

    /// Two lines assigned the same instrument share one copy of the samples.
    ///
    /// The orchestral reference has eighteen lines and several are the same
    /// section; a copy per line would map the same samples several times over,
    /// which is the difference between the memory footprint this leaf claims
    /// and one several times larger.
    func testTwoLinesOnTheSameInstrumentShareOneCopyOfTheSamples() throws {
        let available = try wideInstrument()

        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }
        try SchemaMigrator.migrate(database, appVersion: "test")
        let library = SampledInstrumentLibrary(
            store: InstrumentAssetStore(
                database: database, assetsRootURL: container.assetsURL, catalog: []
            )
        )

        let first = try library.instrument(for: available)
        let second = try library.instrument(for: available)
        XCTAssertTrue(first === second, "The library must share one loaded instrument.")

        let footprint = library.memoryFootprint()
        XCTAssertEqual(footprint.mapped, first.features.mappedByteCount)
        XCTAssertGreaterThan(footprint.resident, 0)

        // Two providers over one instrument: two voices, one copy of the
        // samples, which is what an eighteen-line score depends on.
        let providers = [
            SampledInstrumentVoiceProvider(instrument: first),
            SampledInstrumentVoiceProvider(instrument: second)
        ]
        XCTAssertEqual(providers[0].identifier, providers[1].identifier)
        XCTAssertEqual(library.memoryFootprint().mapped, footprint.mapped)
    }

    // MARK: - Real-time budget

    /// Rendering ten times as much audio through a sampled instrument must not
    /// cost ten times as many allocations.
    ///
    /// The dynamic half of the real-time guard, run against the sampler for the
    /// same reason `RealtimeSafetyTests` runs it against the synthesizer: a
    /// source scan cannot see an allocation the compiler emitted, and a memory-
    /// mapped player is where one would be easiest to introduce.
    func testRenderingASampledInstrumentDoesNotAllocatePerBlock() throws {
        let instrument = try wideInstrument()
        let provider = try SampledInstrumentVoiceProvider(available: instrument)
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let engine = PlaybackEngine(voiceProvider: provider)
        try engine.setRenderMode(.offline(sampleRate: 44_100))
        try engine.load(timeline: timeline)
        engine.play()

        // Warm up: first-touch page faults and lazy graph setup are one-off
        // costs and would otherwise be charged to the short run.
        _ = try engine.renderOffline(frameCount: 44_100)

        func allocationsRendering(frames: Int64) throws -> Int {
            let before = Self.liveAllocationCount()
            _ = try engine.renderOffline(frameCount: frames)
            return Self.liveAllocationCount() - before
        }

        let short = try allocationsRendering(frames: 44_100)
        let long = try allocationsRendering(frames: 441_000)

        let blocksShort = 44_100 / Int(RenderProgram.maximumFrameCount)
        let blocksLong = 441_000 / Int(RenderProgram.maximumFrameCount)
        let perBlock = Double(long - short) / Double(blocksLong - blocksShort)

        XCTAssertLessThan(
            perBlock, 0.25,
            "Rendering a sampled instrument cost \(perBlock) allocations per render block."
        )
    }

    private static func liveAllocationCount() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return Int(statistics.blocks_in_use)
    }
}
