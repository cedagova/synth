import XCTest
@testable import SynthKit

/// Issue #56 (STG001): per-line depth in the render core.
///
/// Every claim is a measurement of rendered audio, following the mixer suite's
/// rule: a flag read back from the control surface proves nothing about what
/// the render thread did.
final class DepthRenderTests: XCTestCase {
    private static let upperHertz = AudioRenderFixtures.frequency(ofMIDINote: 81)

    private func render(
        voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider(),
        configure: @escaping (PlaybackEngine) -> Void = { _ in }
    ) throws -> PlaybackEngine.RenderedAudio {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        return try PlaybackEngine.renderTimelineOffline(
            timeline, voiceProvider: voiceProvider, configure: configure
        )
    }

    /// A harmonically rich patch, so the air-absorption claim has real high
    /// end to measure. The default voice is too mellow at 7 kHz to separate
    /// filtering from the noise floor.
    private func brightProvider() throws -> LineVoiceProvider {
        let entry = try XCTUnwrap(ShippedSoundCollection.standard.sound(withID: "shipped.bright-lead"))
        guard case .synth(let patch) = entry.content else {
            XCTFail("bright-lead is not a synth patch"); throw XCTSkip("unreachable")
        }
        return SynthPatchVoiceProvider(patch: patch)
    }

    /// The front of the stage is the pre-depth engine, bit for bit: explicitly
    /// setting depth to zero must change nothing at all.
    func testDepthZeroIsBitIdenticalToAnUntouchedEngine() throws {
        let untouched = try render()
        let explicitZero = try render {
            $0.mixer(forLineAt: 0)?.depth = 0
            $0.mixer(forLineAt: 1)?.depth = 0
        }
        XCTAssertEqual(
            untouched.canonicalData(), explicitZero.canonicalData(),
            "Depth 0 must be inert; the depth path leaked into a neutral render."
        )
    }

    /// A far line is attenuated and darkened, not merely different: the
    /// fundamental falls by roughly the distance attenuation, while a high
    /// harmonic falls much further (air absorption). That band asymmetry is
    /// what distinguishes distance from a fader.
    func testAFarLineIsQuieterAndDarkerThanANearOne() throws {
        // The lower line is muted in both renders so the band measurement is
        // the upper line alone; mute is an exact zero in the mix.
        let near = try render(voiceProvider: try brightProvider()) {
            $0.mixer(forLineAt: 1)?.isMuted = true
        }
        let far = try render(voiceProvider: try brightProvider()) {
            $0.mixer(forLineAt: 1)?.isMuted = true
            $0.mixer(forLineAt: 0)?.depth = 1
        }

        XCTAssertNotEqual(near.canonicalData(), far.canonicalData())
        XCTAssertLessThan(far.rms(), near.rms(), "Distance must attenuate the line.")

        // The upper line is A5 (880 Hz); its 8th harmonic (~7 kHz) sits where
        // the air-absorption lowpass bites hard while the fundamental barely
        // notices it.
        func energies(_ audio: PlaybackEngine.RenderedAudio) -> (fundamental: Double, high: Double) {
            (
                AudioRenderFixtures.energy(
                    audio.left, atHertz: Self.upperHertz, sampleRate: audio.sampleRate
                ),
                AudioRenderFixtures.energy(
                    audio.left, atHertz: Self.upperHertz * 8, sampleRate: audio.sampleRate
                )
            )
        }
        let nearBands = energies(near)
        let farBands = energies(far)

        XCTAssertGreaterThan(nearBands.high, 0, "The fixture has no high-band energy to measure.")
        XCTAssertGreaterThan(
            farBands.fundamental, nearBands.fundamental * 0.35,
            "The fundamental should survive distance roughly at the attenuation factor."
        )
        XCTAssertLessThan(
            farBands.high, nearBands.high * 0.4,
            "A far line must lose far more high end than the plain distance attenuation."
        )
    }

    /// Depth leans the line into the shared room even when every explicit send
    /// is zero. The proof is stereo decorrelation: both fixture lines are
    /// centred, so a roomless render is left==right bit for bit, and the only
    /// thing that can pull the channels apart is the room's stereo spread.
    func testDepthEngagesTheSharedRoom() throws {
        let near = try render()
        let far = try render {
            $0.mixer(forLineAt: 0)?.depth = 1
            $0.mixer(forLineAt: 1)?.depth = 1
        }

        XCTAssertEqual(
            near.left, near.right,
            "Centred lines with no room must render identical channels."
        )
        XCTAssertNotEqual(
            far.left, far.right,
            "Depth engaged no room: the far render is still perfectly mono."
        )

        let difference = zip(far.left, far.right).map { $0 - $1 }
        var total = 0.0
        for sample in difference { total += Double(sample) * Double(sample) }
        let differenceRMS = (total / Double(max(1, difference.count))).squareRoot()
        XCTAssertGreaterThan(
            differenceRMS, 1e-5,
            "The room's stereo return is too small to be the audible space REQ-001 needs."
        )
    }

    private func chunkedRender(
        _ timeline: PerformanceTimeline,
        blockFrames: Int64,
        configure: (PlaybackEngine) -> Void
    ) throws -> PlaybackEngine.RenderedAudio {
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)
        configure(engine)
        engine.play()
        let total = try XCTUnwrap(engine.loadedProgram?.totalFrames)
        var left: [Float] = []
        var right: [Float] = []
        var remaining = total
        while remaining > 0 {
            let chunk = try engine.renderOffline(frameCount: min(blockFrames, remaining))
            left.append(contentsOf: chunk.left)
            right.append(contentsOf: chunk.right)
            remaining -= Int64(chunk.frameCount)
            if chunk.frameCount == 0 { break }
        }
        return PlaybackEngine.RenderedAudio(sampleRate: 48_000, left: left, right: right)
    }

    /// The depth path must not reintroduce buffer-size dependence: its filter
    /// state is continuous across sub-blocks.
    func testDepthRenderingIsIndependentOfTheHostBufferSize() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let configure: (PlaybackEngine) -> Void = {
            $0.mixer(forLineAt: 0)?.depth = 0.7
            $0.mixer(forLineAt: 1)?.depth = 0.3
        }
        let small = try chunkedRender(timeline, blockFrames: 64, configure: configure)
        let large = try chunkedRender(timeline, blockFrames: 4096, configure: configure)
        XCTAssertEqual(small.canonicalData(), large.canonicalData())
    }

    /// The review's regression: a note followed by a long rest drives the
    /// depth filter through its denormal decay, where a chunk-boundary flush
    /// once made the flush frame depend on the host buffer size.
    func testBufferSizeIndependenceSurvivesSilenceAtFullDepth() throws {
        let xml = ScoreXML.Score(
            workTitle: "Note Into Silence",
            composer: "Fixture",
            parts: [
                ScoreXML.Part(
                    id: "P1",
                    name: "Solo",
                    measures: [
                        ScoreXML.Measure(
                            number: "1",
                            items: [
                                .attributes(ScoreXML.Attributes(
                                    divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                                )),
                                .direction(ScoreXML.Direction(
                                    words: "Andante", sound: ["tempo": "120"]
                                )),
                                .note(ScoreXML.Note(pitch: "A5", duration: 4, type: "quarter")),
                                .note(ScoreXML.Note(pitch: nil, duration: 12, type: "half"))
                            ]
                        ),
                        ScoreXML.Measure(
                            number: "2",
                            items: [.note(ScoreXML.Note(pitch: nil, duration: 16, type: "whole"))]
                        )
                    ]
                )
            ]
        ).data()
        let timeline = try AudioRenderFixtures.timeline(xml)
        let configure: (PlaybackEngine) -> Void = { $0.mixer(forLineAt: 0)?.depth = 1 }

        let small = try chunkedRender(timeline, blockFrames: 64, configure: configure)
        let large = try chunkedRender(timeline, blockFrames: 4096, configure: configure)
        XCTAssertEqual(
            small.canonicalData(), large.canonicalData(),
            "The depth filter's silence decay must not depend on chunk boundaries."
        )
    }

    /// Two renders with identical depth settings are byte-identical.
    func testDepthRenderingIsDeterministic() throws {
        let first = try render { $0.mixer(forLineAt: 0)?.depth = 0.6 }
        let second = try render { $0.mixer(forLineAt: 0)?.depth = 0.6 }
        XCTAssertEqual(first.canonicalData(), second.canonicalData())
    }
}
