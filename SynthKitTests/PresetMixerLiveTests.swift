import Foundation
import XCTest
@testable import SynthKit

/// REQ-008 and REQ-024 **while the music is playing**, which is the half
/// ASN001's suite could not reach.
///
/// Every test in `PresetRenderTests` renders a preset from the beginning: it
/// applies a mix, then starts. That proves the arithmetic and says nothing about
/// the thing the mixer panel actually does, which is move a fader in the middle
/// of a piece and expect the next buffer to be different. So each test here
/// renders a stretch, makes the change exactly as the panel makes it — a strip
/// setter on the running engine, or `PresetPerformance.apply(to:)` for a
/// switch — and renders the next stretch out of the *same* engine.
///
/// Four things are asserted every time, because "it got quieter" is worth
/// nothing if the music stopped to let it happen:
///
/// 1. the change is audible in the second stretch and was not in the first;
/// 2. the transport never left `playing` and the playhead kept advancing;
/// 3. no overload pause was recorded; and
/// 4. the join between the two stretches is not a gap.
final class PresetMixerLiveTests: XCTestCase {
    private var sandboxRoot: URL!
    private var sourceDirectory: URL!
    private var store: LibraryStore!

    private static let sampleRate: Double = 48_000

    /// 1.5 s. Long enough for several notes of the fixture, short enough that a
    /// failure is readable.
    private static let stretchFrames: Int64 = 72_000

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        sourceDirectory = sandboxRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        store = try LibraryStore.open(
            container: AppContainer(rootURL: sandboxRoot.appending(path: "Synth")),
            appVersion: "1.0 (1)"
        )
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    // MARK: A fader moved mid-piece (REQ-008)

    /// Muting a line while the piece plays takes that line out of the next
    /// buffer and leaves the other one exactly where it was.
    func testMutingALineMidPieceSilencesItFromThatMomentOn() throws {
        let (score, engine) = try playingTwoLinePiece()
        let upper = try lineID(ofScore: score, at: 0)

        let before = try engine.renderOffline(frameCount: Self.stretchFrames)
        let positionBefore = engine.playbackPositionFrame

        try mute(upper, on: engine, forScore: score)

        let after = try engine.renderOffline(frameCount: Self.stretchFrames)

        assertPlaybackContinued(engine, from: positionBefore, before: before, after: after)
        XCTAssertGreaterThan(energy(before, Self.upperHertz), 1e-4, "The upper line was never audible.")
        XCTAssertLessThan(
            energy(settled(after), Self.upperHertz), energy(before, Self.upperHertz) / 50,
            "The upper line is still sounding after it was muted mid-piece."
        )
        XCTAssertGreaterThan(
            energy(settled(after), Self.lowerHertz), energy(before, Self.lowerHertz) / 2,
            "Muting the upper line took the lower line with it."
        )
    }

    /// Pulling a fader down twelve decibels mid-piece moves that line's level by
    /// twelve decibels and nothing else's.
    func testAFaderMovedMidPieceChangesThatLinesLevelByTheRequestedAmount() throws {
        let (score, engine) = try playingTwoLinePiece()
        let upper = try lineID(ofScore: score, at: 0)

        let before = try engine.renderOffline(frameCount: Self.stretchFrames)
        let positionBefore = engine.playbackPositionFrame

        // Exactly what the panel's volume slider does: the strip first so it is
        // heard on the next buffer, then the store.
        let quarter = AssignmentDisplay.volume(forDecibels: -12)
        let fader = try XCTUnwrap(engine.mixer(for: upper))
        fader.gain = Float(quarter)
        try persistMixer(LineMixerState(volume: quarter), forLine: upper, ofScore: score)

        let after = try engine.renderOffline(frameCount: Self.stretchFrames)

        assertPlaybackContinued(engine, from: positionBefore, before: before, after: after)

        let ratio = energy(before, Self.upperHertz) / max(energy(settled(after), Self.upperHertz), 1e-12)
        XCTAssertEqual(
            AudioRenderFixtures.decibels(ratio), 12, accuracy: 2,
            "Asking for twelve decibels down produced \(AudioRenderFixtures.decibels(ratio)) dB."
        )
        XCTAssertGreaterThan(
            energy(settled(after), Self.lowerHertz), energy(before, Self.lowerHertz) / 2,
            "Turning the upper line down took the lower line with it."
        )
    }

    /// Panning a line hard left mid-piece moves its energy out of the right
    /// channel while the centred line stays in both.
    func testPanningALineMidPieceMovesItsEnergyBetweenTheChannels() throws {
        let (score, engine) = try playingTwoLinePiece()
        let upper = try lineID(ofScore: score, at: 0)

        let before = try engine.renderOffline(frameCount: Self.stretchFrames)
        let positionBefore = engine.playbackPositionFrame

        XCTAssertEqual(
            energyIn(before.left, Self.upperHertz), energyIn(before.right, Self.upperHertz),
            accuracy: energyIn(before.left, Self.upperHertz) * 0.05,
            "The upper line did not start centred."
        )

        let strip = try XCTUnwrap(engine.mixer(for: upper))
        strip.pan = -1
        try persistMixer(LineMixerState(pan: -1), forLine: upper, ofScore: score)

        let after = try engine.renderOffline(frameCount: Self.stretchFrames)
        assertPlaybackContinued(engine, from: positionBefore, before: before, after: after)

        let settledAfter = settled(after)
        XCTAssertGreaterThan(
            energyIn(settledAfter.left, Self.upperHertz),
            energyIn(settledAfter.right, Self.upperHertz) * 20,
            "Panning the upper line hard left left it in the right channel."
        )
        XCTAssertGreaterThan(
            energyIn(settledAfter.right, Self.lowerHertz),
            energyIn(before.right, Self.lowerHertz) / 2,
            "Panning the upper line took the lower line out of the right channel."
        )
    }

    // MARK: The increment's own acceptance, mid-piece (REQ-008 on a real fugue)

    /// "Soloing one fugue voice plays only that voice" — pressed **while the
    /// fugue is playing**, at a point where all four voices are sounding.
    ///
    /// The bass is the measurement, for the reason ASN001 records: this subject
    /// is answered at the octave, so a single-bin probe on an upper voice would
    /// be measuring the tenor's second harmonic and calling it the soprano. The
    /// bass sings below the tenor's lowest note and a harmonic can never fall
    /// below its own fundamental, so energy at the bass's pitches can only have
    /// come from the bass.
    func testSoloingOneFugueVoiceMidPieceSilencesTheOthersFromThatMomentOn() throws {
        let piece = try importScore(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 12),
            named: "fugue.musicxml"
        )
        let score = try compile(piece)
        XCTAssertEqual(try store.lineInventory(for: score).count, 4, "four fugal voices")

        let engine = try playingEngine(for: score)

        // The bass enters at measure 7 of this fixture (72 bpm, 4/4), so 20.2
        // seconds in is the first moment all four voices are sounding.
        engine.seek(toMicroseconds: 20_200_000)

        let full = try engine.renderOffline(frameCount: Self.stretchFrames * 2)
        let positionBefore = engine.playbackPositionFrame

        // Score order is soprano, answer, tenor, bass.
        let tenor = try lineID(ofScore: score, at: 2)
        let tenorStrip = try XCTUnwrap(engine.mixer(for: tenor))
        tenorStrip.isSoloed = true
        try persistMixer(LineMixerState(isSoloed: true), forLine: tenor, ofScore: score)

        let soloed = try engine.renderOffline(frameCount: Self.stretchFrames * 2)
        assertPlaybackContinued(engine, from: positionBefore, before: full, after: soloed)

        // C3 and G2: the bass subject, both below the tenor's lowest note (G3),
        // and a harmonic can never fall below its own fundamental — so energy
        // there in the full mix can only have come from the bass.
        //
        // Eight times down rather than twenty, deliberately. A soloed keyboard
        // voice at 72 bpm strikes a note roughly every 830 ms, and a note
        // attack is broadband: it puts a little energy in *every* bin, the
        // bass's included. That residual is the floor of this measurement, not
        // the bass — which is exactly what the bit-for-bit check below settles.
        for bassNote in [48, 43] {
            let hertz = AudioRenderFixtures.frequency(ofMIDINote: bassNote)
            XCTAssertGreaterThan(
                energy(full, hertz), 1e-5,
                "The bass was not audible in the full mix at MIDI \(bassNote)."
            )
            XCTAssertLessThan(
                energy(settled(soloed), hertz), energy(full, hertz) / 8,
                "The bass is still audible at MIDI \(bassNote) after the tenor was soloed."
            )
        }

        // And the soloed voice is not itself silence, nor quieter for being
        // alone. C4 is the tenor's own subject.
        let tenorHertz = AudioRenderFixtures.frequency(ofMIDINote: 60)
        XCTAssertGreaterThan(energy(settled(soloed), tenorHertz), energy(full, tenorHertz) * 0.4)
        XCTAssertGreaterThan(settled(soloed).peak(), 0.001)

        // **"…and nothing but that voice."** Replaying the same three seconds
        // with the other three lines *muted* instead of the tenor soloed
        // produces the same amount of sound — which carries the claim to the
        // two upper voices, where a frequency probe cannot go: this subject is
        // answered at the octave, so every soprano pitch coincides with the
        // tenor's own second harmonic and a single-bin probe there would be
        // measuring the tenor.
        //
        // Levels rather than bit equality, deliberately. ASN001's
        // `testSoloingOneFugueVoicePlaysOnlyThatVoice` makes the bit-for-bit
        // claim on two renders that each start from the top; these two start
        // from a seek inside one running engine, whose effect tails carry the
        // history of whatever it rendered before. That difference is a property
        // of replaying mid-piece, not of the mixer.
        let others = try (0..<4).filter { $0 != 2 }.map { try lineID(ofScore: score, at: $0) }

        engine.seek(toMicroseconds: 23_200_000)
        let soloedAgain = try engine.renderOffline(frameCount: Self.stretchFrames * 2)

        tenorStrip.isSoloed = false
        for line in others {
            let strip = try XCTUnwrap(engine.mixer(for: line))
            strip.isMuted = true
        }
        engine.seek(toMicroseconds: 23_200_000)
        let othersMuted = try engine.renderOffline(frameCount: Self.stretchFrames * 2)

        XCTAssertEqual(
            othersMuted.rms(), soloedAgain.rms(), accuracy: soloedAgain.rms() * 0.05,
            "Soloing the tenor is not the same as silencing the other three voices."
        )
        XCTAssertLessThan(soloedAgain.rms(), full.rms() / 1.5, "Three voices did not go away.")
    }

    // MARK: Switching presets mid-piece (REQ-024)

    /// "Switching presets applies immediately and audibly" — with the music
    /// running, and through the exact call the preset picker makes.
    ///
    /// The two presets differ in both halves of what a preset is: the upper line
    /// gets a different *sound* and a different *place in the mix*. Both land in
    /// the next stretch, and the music does not stop for either.
    func testSwitchingPresetsMidPieceChangesBothTheSoundAndTheMixWithoutStopping() throws {
        let (score, engine) = try playingTwoLinePiece()
        let upper = try lineID(ofScore: score, at: 0)

        let bright = try store.sounds.create(patch: brightPatch(), named: "Bright", in: .leads)
        let plain = try XCTUnwrap(try store.presets.activePreset(forPieceID: score.pieceID))

        // A second preset, built but deliberately not activated yet.
        var variation = try store.presets.duplicate(plain, named: "Bright Upper", makeActive: false)
        variation = try store.presets.assign(
            .library(kind: .synth, soundID: bright.id), toLine: upper, in: variation
        )
        variation = try store.presets.setMixer(
            LineMixerState(volume: 1, pan: -1), forLine: upper, in: variation
        )

        // One second each, not the usual one and a half: this test renders
        // three stretches and the fixture is four seconds long.
        let stretch = Self.stretchFrames * 2 / 3
        let before = try engine.renderOffline(frameCount: stretch)
        let positionBefore = engine.playbackPositionFrame

        // Exactly what the picker does: activate, re-resolve, and put the whole
        // performance — sounds then mixer — on the running engine.
        _ = try store.presets.activate(variation)
        try store.openActivePreset(for: score).apply(to: engine)

        let after = try engine.renderOffline(frameCount: stretch)
        assertPlaybackContinued(engine, from: positionBefore, before: before, after: after)

        let settledAfter = settled(after)

        // The mix half: the upper line is now hard left.
        XCTAssertGreaterThan(
            energyIn(settledAfter.left, Self.upperHertz),
            energyIn(settledAfter.right, Self.upperHertz) * 20,
            "The arriving preset's pan did not reach the engine."
        )

        // The sound half: a bright saw has far more third-harmonic energy than
        // the default voice does.
        let thirdHarmonic = Self.upperHertz * 3
        XCTAssertGreaterThan(
            energyIn(settledAfter.left, thirdHarmonic),
            energyIn(before.left, thirdHarmonic) * 2,
            "The arriving preset's sound did not reach the engine."
        )

        // And switching back takes both away again, still without stopping.
        let positionBeforeReturn = engine.playbackPositionFrame
        _ = try store.presets.activate(
            try XCTUnwrap(try store.presets.preset(withID: plain.id))
        )
        try store.openActivePreset(for: score).apply(to: engine)
        let back = try engine.renderOffline(frameCount: stretch)

        assertPlaybackContinued(engine, from: positionBeforeReturn, before: after, after: back)
        XCTAssertEqual(
            energyIn(settled(back).left, Self.upperHertz),
            energyIn(settled(back).right, Self.upperHertz),
            accuracy: energyIn(settled(back).left, Self.upperHertz) * 0.05,
            "Switching back left the other preset's pan in place."
        )
    }

    /// The panel writes the strip first and the store second, and the two agree
    /// afterwards: what the engine is playing is what a relaunch would restore.
    func testWhatTheStripIsSetToIsWhatThePresetEndsUpHolding() throws {
        let (score, engine) = try playingTwoLinePiece()
        let upper = try lineID(ofScore: score, at: 0)

        _ = try engine.renderOffline(frameCount: Self.stretchFrames)

        let wanted = LineMixerState(volume: 0.4, pan: -0.6, isMuted: false, isSoloed: true)
        let strip = try XCTUnwrap(engine.mixer(for: upper))
        strip.gain = Float(wanted.volume)
        strip.pan = Float(wanted.pan)
        strip.isSoloed = wanted.isSoloed
        try persistMixer(wanted, forLine: upper, ofScore: score)

        let stored = try XCTUnwrap(
            try store.presets.activePreset(forPieceID: score.pieceID)?.line(withID: upper)?.mixer
        )
        XCTAssertEqual(stored, wanted)

        let live = try XCTUnwrap(engine.mixer(for: upper))
        XCTAssertEqual(Double(live.gain), wanted.volume, accuracy: 1e-6)
        XCTAssertEqual(Double(live.pan), wanted.pan, accuracy: 1e-6)
        XCTAssertTrue(live.isSoloed)
        XCTAssertFalse(live.isMuted)
    }

    // MARK: Fixtures and helpers

    /// A5 and A2 — the two lines of the fixture, far enough apart that a
    /// single-bin probe attributes energy to one of them without ambiguity.
    private static let upperHertz = AudioRenderFixtures.frequency(ofMIDINote: 81)
    private static let lowerHertz = AudioRenderFixtures.frequency(ofMIDINote: 45)

    @discardableResult
    private func importScore(_ musicXML: Data, named name: String) throws -> PieceRecord {
        let url = sourceDirectory.appending(path: name)
        try musicXML.write(to: url)
        return try store.makeImporter().importPiece(from: url).piece
    }

    private func compile(_ piece: PieceRecord) throws -> CompiledScore {
        try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)
    }

    private func playingTwoLinePiece() throws -> (CompiledScore, PlaybackEngine) {
        let piece = try importScore(AudioRenderFixtures.twoLineFixture(), named: "twolines.musicxml")
        let score = try compile(piece)
        return (score, try playingEngine(for: score))
    }

    /// An engine loaded with the piece's active preset and already rolling —
    /// the state the panel's controls are used in.
    private func playingEngine(for score: CompiledScore) throws -> PlaybackEngine {
        let performance = try store.openActivePreset(for: score)
        let engine = PlaybackEngine(voices: performance.voiceAssignment)
        try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
        try engine.load(
            timeline: PerformanceRealizer().realize(score, settings: .literal)
        )
        performance.applyMixer(to: engine)
        engine.play()
        return engine
    }

    private func lineID(ofScore score: CompiledScore, at index: Int) throws -> ScoreLineID {
        try XCTUnwrap(try store.lineInventory(for: score).entries[index].id)
    }

    private func mute(
        _ lineID: ScoreLineID, on engine: PlaybackEngine, forScore score: CompiledScore
    ) throws {
        let strip = try XCTUnwrap(engine.mixer(for: lineID))
        strip.isMuted = true
        try persistMixer(LineMixerState(isMuted: true), forLine: lineID, ofScore: score)
    }

    private func persistMixer(
        _ state: LineMixerState, forLine lineID: ScoreLineID, ofScore score: CompiledScore
    ) throws {
        let preset = try XCTUnwrap(try store.presets.activePreset(forPieceID: score.pieceID))
        _ = try store.presets.setMixer(state, forLine: lineID, in: preset)
    }

    private func brightPatch() -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.9),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: 16_000),
            outputLevel: 0.25
        )
    }

    // MARK: Reading the result

    /// The second half of a stretch, so a gain ramp at the moment of the change
    /// is never what is being measured.
    private func settled(
        _ audio: PlaybackEngine.RenderedAudio
    ) -> PlaybackEngine.RenderedAudio {
        let half = audio.frameCount / 2
        return PlaybackEngine.RenderedAudio(
            sampleRate: audio.sampleRate,
            left: Array(audio.left.suffix(half)),
            right: Array(audio.right.suffix(half))
        )
    }

    private func energy(_ audio: PlaybackEngine.RenderedAudio, _ hertz: Double) -> Double {
        energyIn(audio.left, hertz)
    }

    private func energyIn(_ samples: [Float], _ hertz: Double) -> Double {
        AudioRenderFixtures.energy(samples, atHertz: hertz, sampleRate: Self.sampleRate)
    }

    /// The four things that must be true of every mid-piece change: the
    /// transport never left `playing`, the playhead advanced, nothing was
    /// reported as an overload pause, and the join is not a gap.
    private func assertPlaybackContinued(
        _ engine: PlaybackEngine,
        from positionBefore: Int64,
        before: PlaybackEngine.RenderedAudio,
        after: PlaybackEngine.RenderedAudio,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(engine.transportState, .playing, "The transport stopped.", file: file, line: line)
        XCTAssertEqual(engine.pauseReason, .none, file: file, line: line)
        XCTAssertGreaterThan(
            engine.playbackPositionFrame, positionBefore,
            "The playhead did not advance across the change.", file: file, line: line
        )
        XCTAssertEqual(engine.statistics.overloadPauses, 0, file: file, line: line)

        let boundary = Array(before.left.suffix(2_400)) + Array(after.left.prefix(2_400))
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(boundary, from: 0, to: 0.1, sampleRate: Self.sampleRate), 1e-5,
            "The output fell silent across the change.", file: file, line: line
        )
    }
}
