import Foundation
import XCTest
@testable import SynthKit

/// Issue #20's audible claims, proved as measurements of rendered audio.
///
/// Every assertion here reads the buffer the engine produced. "This line plays
/// a different sound" is a change in harmonic content at that line's own pitch;
/// "the piece still plays with the same timbre after the sound was deleted" is
/// bit equality; "soloing a fugue voice plays only that voice" is energy at the
/// other voices' pitches falling to nothing. A test that asserted on the preset
/// struct instead would agree with a model that never reached the engine.
final class PresetRenderTests: XCTestCase {
    private var sandboxRoot: URL!
    private var sourceDirectory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        sourceDirectory = sandboxRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    // MARK: Fixtures

    /// Upper line is A5 (880 Hz), lower is A2 (110 Hz) — far enough apart that
    /// a single-bin probe attributes energy to one line without ambiguity.
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

    private func timeline(_ score: CompiledScore) -> PerformanceTimeline {
        PerformanceRealizer().realize(score, settings: .literal)
    }

    /// The two-line piece, imported so it has presets.
    private func twoLinePiece() throws -> (PieceRecord, CompiledScore) {
        let piece = try importScore(AudioRenderFixtures.twoLineFixture(), named: "twolines.musicxml")
        return (piece, try compile(piece))
    }

    /// Renders whatever the store's active preset currently says, through the
    /// same graph real-time playback uses.
    private func renderActivePreset(_ score: CompiledScore) throws -> PlaybackEngine.RenderedAudio {
        let performance = try store.openActivePreset(for: score)
        return try PlaybackEngine.renderTimelineOffline(
            timeline(score),
            voices: performance.voiceAssignment()
        ) { engine in
            performance.applyMixer(to: engine)
        }
    }

    /// A sound that is unmistakably not the default voice: a bright saw with
    /// the filter wide open, so its upper harmonics are large.
    private func brightPatch(cutoff: Double = 16_000) -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.9),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: cutoff),
            outputLevel: 0.25
        )
    }

    // MARK: Per-line assignment is audible (REQ-006)

    /// Changing one line's sound changes that line in the mix and leaves the
    /// other line exactly where it was.
    ///
    /// The second half is the one that matters: a program that applied the new
    /// sound to *every* line would pass the first assertion on its own.
    func testAssigningASoundToOneLineChangesOnlyThatLine() throws {
        let (_, score) = try twoLinePiece()
        let before = try renderActivePreset(score)

        let bright = try store.sounds.create(patch: brightPatch(), named: "Bright", in: .leads)
        let preset = try store.activePreset(for: score)
        let upperLine = preset.lines[0].lineID
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: bright.id), toLine: upperLine, in: preset
        )

        let after = try renderActivePreset(score)

        // The upper line's third harmonic is where a saw and the default voice
        // differ most audibly.
        let upperThirdBefore = AudioRenderFixtures.energy(
            before.left, atHertz: Self.upperHertz * 3, sampleRate: before.sampleRate
        )
        let upperThirdAfter = AudioRenderFixtures.energy(
            after.left, atHertz: Self.upperHertz * 3, sampleRate: after.sampleRate
        )
        XCTAssertGreaterThan(
            upperThirdAfter, upperThirdBefore * 2,
            "Assigning a bright saw to the upper line did not change what that line sounds like "
                + "(\(upperThirdBefore) → \(upperThirdAfter))."
        )

        let lowerBefore = AudioRenderFixtures.energy(
            before.left, atHertz: Self.lowerHertz, sampleRate: before.sampleRate
        )
        let lowerAfter = AudioRenderFixtures.energy(
            after.left, atHertz: Self.lowerHertz, sampleRate: after.sampleRate
        )
        XCTAssertGreaterThan(lowerBefore, 1e-5, "The lower line is not audible at all.")
        XCTAssertEqual(
            lowerAfter, lowerBefore, accuracy: lowerBefore * 0.02,
            "Assigning a sound to the upper line changed the lower line too."
        )
    }

    /// Two lines on two different sounds really are two different sounds, not
    /// the last one assigned applied to both.
    func testTwoLinesOnTwoSoundsRenderAsTwoSounds() throws {
        let (_, score) = try twoLinePiece()
        let bright = try store.sounds.create(patch: brightPatch(), named: "Bright", in: .leads)
        let dark = try store.sounds.create(
            patch: brightPatch(cutoff: 200), named: "Dark", in: .pads
        )

        var preset = try store.activePreset(for: score)
        preset = try store.presets.assign(
            .library(kind: .synth, soundID: bright.id), toLine: preset.lines[0].lineID, in: preset
        )
        preset = try store.presets.assign(
            .library(kind: .synth, soundID: dark.id), toLine: preset.lines[1].lineID, in: preset
        )

        let mixed = try renderActivePreset(score)

        // Both on the bright sound, for comparison.
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: bright.id), toLine: preset.lines[1].lineID, in: preset
        )
        let uniform = try renderActivePreset(score)

        let lowerHarmonicMixed = AudioRenderFixtures.energy(
            mixed.left, atHertz: Self.lowerHertz * 5, sampleRate: mixed.sampleRate
        )
        let lowerHarmonicUniform = AudioRenderFixtures.energy(
            uniform.left, atHertz: Self.lowerHertz * 5, sampleRate: uniform.sampleRate
        )
        XCTAssertGreaterThan(
            lowerHarmonicUniform, lowerHarmonicMixed * 2,
            "The lower line sounded the same whether it was assigned the dark sound or the "
                + "bright one, so the assignment is not per line."
        )
        XCTAssertNotEqual(mixed.canonicalData(), uniform.canonicalData())
    }

    // MARK: Live references (REQ-029, first half)

    /// "Editing a user sound changes playback of every preset referencing it."
    func testEditingAnAssignedSoundChangesWhatThePresetPlays() throws {
        let (_, score) = try twoLinePiece()
        let sound = try store.sounds.create(
            patch: brightPatch(cutoff: 400), named: "Follows Me", in: .pads
        )
        let preset = try store.activePreset(for: score)
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: sound.id), toLine: preset.lines[0].lineID, in: preset
        )

        let closed = try renderActivePreset(score)

        // Only the sound changes. The preset is not touched at all.
        let revisionBefore = try XCTUnwrap(
            try store.presets.activePreset(forPieceID: score.pieceID)
        ).revision
        _ = try store.sounds.update(sound, patch: brightPatch(cutoff: 16_000))
        let revisionAfter = try XCTUnwrap(
            try store.presets.activePreset(forPieceID: score.pieceID)
        ).revision
        XCTAssertEqual(revisionBefore, revisionAfter, "Editing a sound must not rewrite the preset")

        let opened = try renderActivePreset(score)

        let closedHarmonic = AudioRenderFixtures.energy(
            closed.left, atHertz: Self.upperHertz * 3, sampleRate: closed.sampleRate
        )
        let openedHarmonic = AudioRenderFixtures.energy(
            opened.left, atHertz: Self.upperHertz * 3, sampleRate: opened.sampleRate
        )
        XCTAssertGreaterThan(
            openedHarmonic, closedHarmonic * 2,
            "Opening the filter of an assigned sound was not heard through the preset "
                + "(\(closedHarmonic) → \(openedHarmonic))."
        )
    }

    // MARK: Embed on delete (REQ-029, acceptance)

    /// "Delete an in-use sound after confirming; the piece still plays with the
    /// same timbre."
    ///
    /// Bit equality, not similarity. The embedded copy is the same patch
    /// rendered by the same engine, so anything less than identical output
    /// would mean something was lost in the copy.
    func testAfterDeletingAnInUseSoundThePiecePlaysBitForBitIdentically() throws {
        let (_, score) = try twoLinePiece()
        let doomed = try store.sounds.create(
            patch: brightPatch(cutoff: 3_500), named: "Doomed", in: .leads
        )
        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: doomed.id), toLine: line, in: preset
        )

        let beforeDeletion = try renderActivePreset(score)

        // The warning the owner sees is built from this.
        let usage = try store.presets.usage(ofSoundID: doomed.id)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.lineIDs, [line])

        try store.sounds.delete(doomed)

        let afterDeletion = try renderActivePreset(score)

        XCTAssertEqual(
            beforeDeletion.canonicalData(), afterDeletion.canonicalData(),
            "Deleting the sound changed what the piece sounds like; the embedded copy is not "
                + "the sound as it was."
        )
        XCTAssertGreaterThan(afterDeletion.peak(), 0.001, "…and it is not silence either.")

        // And the preset says so.
        let performance = try store.openActivePreset(for: score)
        XCTAssertEqual(performance.embeddedLines.map(\.lineID), [line])
    }

    /// A reference that resolves to nothing plays the default voice — audibly,
    /// not as silence.
    func testAVanishedSoundRendersAsTheDefaultVoiceRatherThanSilence() throws {
        let (_, score) = try twoLinePiece()
        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID

        // What the default voice sounds like on that line, for comparison.
        let reference = try renderActivePreset(score)

        _ = try store.presets.assign(
            .library(kind: .synth, soundID: "user.never-existed"), toLine: line, in: preset
        )
        let fallback = try renderActivePreset(score)

        XCTAssertEqual(
            reference.canonicalData(), fallback.canonicalData(),
            "A missing sound must fall back to exactly the default voice."
        )
        XCTAssertTrue(try store.openActivePreset(for: score).hasMissingSound,
                      "…and must say that it did.")
    }

    // MARK: Mixer state reaches the engine's busses (REQ-008)

    func testPresetMuteSilencesExactlyThatLine() throws {
        let (_, score) = try twoLinePiece()
        let full = try renderActivePreset(score)

        let preset = try store.activePreset(for: score)
        _ = try store.presets.setMixer(
            LineMixerState(isMuted: true), forLine: preset.lines[0].lineID, in: preset
        )
        let muted = try renderActivePreset(score)

        let upperFull = AudioRenderFixtures.energy(
            full.left, atHertz: Self.upperHertz, sampleRate: full.sampleRate
        )
        let upperMuted = AudioRenderFixtures.energy(
            muted.left, atHertz: Self.upperHertz, sampleRate: muted.sampleRate
        )
        let lowerFull = AudioRenderFixtures.energy(
            full.left, atHertz: Self.lowerHertz, sampleRate: full.sampleRate
        )
        let lowerMuted = AudioRenderFixtures.energy(
            muted.left, atHertz: Self.lowerHertz, sampleRate: muted.sampleRate
        )

        XCTAssertGreaterThan(upperFull, 1e-4)
        XCTAssertLessThan(upperMuted, upperFull / 1000, "The muted line is still audible.")
        XCTAssertEqual(lowerMuted, lowerFull, accuracy: lowerFull * 0.02)
    }

    func testPresetSoloIsExactlyTheSameAsMutingEveryOtherLine() throws {
        let (_, score) = try twoLinePiece()
        let preset = try store.activePreset(for: score)

        _ = try store.presets.setMixer(
            LineMixerState(isSoloed: true), forLine: preset.lines[1].lineID, in: preset
        )
        let soloed = try renderActivePreset(score)

        let current = try XCTUnwrap(try store.presets.activePreset(forPieceID: score.pieceID))
        var reset = try store.presets.setMixer(
            .neutral, forLine: preset.lines[1].lineID, in: current
        )
        reset = try store.presets.setMixer(
            LineMixerState(isMuted: true), forLine: preset.lines[0].lineID, in: reset
        )
        let othersMuted = try renderActivePreset(score)

        XCTAssertEqual(
            soloed.canonicalData(), othersMuted.canonicalData(),
            "A soloed preset line must silence the others exactly."
        )
        XCTAssertGreaterThan(soloed.peak(), 0.001)
    }

    func testPresetVolumeScalesExactlyThatLine() throws {
        let (_, score) = try twoLinePiece()
        let full = try renderActivePreset(score)

        let preset = try store.activePreset(for: score)
        _ = try store.presets.setMixer(
            LineMixerState(volume: 0.25), forLine: preset.lines[0].lineID, in: preset
        )
        let quieter = try renderActivePreset(score)

        let upperFull = AudioRenderFixtures.energy(
            full.left, atHertz: Self.upperHertz, sampleRate: full.sampleRate
        )
        let upperQuiet = AudioRenderFixtures.energy(
            quieter.left, atHertz: Self.upperHertz, sampleRate: quieter.sampleRate
        )
        XCTAssertEqual(
            upperQuiet, upperFull * 0.25, accuracy: upperFull * 0.02,
            "A stored volume of 0.25 must be a quarter of the line's level, "
                + "not an approximation of one."
        )
    }

    func testPresetPanMovesTheLineBetweenTheChannels() throws {
        let (_, score) = try twoLinePiece()
        let preset = try store.activePreset(for: score)
        _ = try store.presets.setMixer(
            LineMixerState(pan: -1), forLine: preset.lines[0].lineID, in: preset
        )
        let hardLeft = try renderActivePreset(score)

        let left = AudioRenderFixtures.energy(
            hardLeft.left, atHertz: Self.upperHertz, sampleRate: hardLeft.sampleRate
        )
        let right = AudioRenderFixtures.energy(
            hardLeft.right, atHertz: Self.upperHertz, sampleRate: hardLeft.sampleRate
        )
        XCTAssertGreaterThan(left, 1e-4)
        XCTAssertLessThan(right, left / 100, "A hard-left line is still coming out of the right.")
    }

    /// Mixer state stored in a preset comes back after a relaunch and is still
    /// audible — the persistence half of REQ-008 and REQ-025 together.
    func testMixerStateSurvivesARelaunchAndIsStillApplied() throws {
        let (piece, score) = try twoLinePiece()
        let preset = try store.activePreset(for: score)
        _ = try store.presets.setMixer(
            LineMixerState(volume: 0.25, pan: -1), forLine: preset.lines[0].lineID, in: preset
        )
        let before = try renderActivePreset(score)

        store.close()
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        let reloaded = try compile(try XCTUnwrap(try store.pieces.piece(withID: piece.id)))
        let after = try renderActivePreset(reloaded)

        XCTAssertEqual(
            before.canonicalData(), after.canonicalData(),
            "The piece did not come back sounding the way the owner left it."
        )
    }

    /// Switching presets applies immediately, including turning a previous
    /// preset's mute back off (REQ-024).
    func testSwitchingPresetsAppliesTheNewMixerStateImmediately() throws {
        let (_, score) = try twoLinePiece()
        let plain = try store.activePreset(for: score)
        let plainAudio = try renderActivePreset(score)

        var muted = try store.presets.duplicate(plain, named: "Upper Muted", makeActive: true)
        muted = try store.presets.setMixer(
            LineMixerState(isMuted: true), forLine: plain.lines[0].lineID, in: muted
        )
        let mutedAudio = try renderActivePreset(score)
        XCTAssertNotEqual(plainAudio.canonicalData(), mutedAudio.canonicalData())

        _ = try store.presets.activate(
            try XCTUnwrap(try store.presets.preset(withID: plain.id))
        )
        let backAgain = try renderActivePreset(score)

        XCTAssertEqual(
            plainAudio.canonicalData(), backAgain.canonicalData(),
            "Switching back left the other preset's mute in place."
        )
    }

    // MARK: The increment's own acceptance (REQ-008 on a real fugue)

    /// "Soloing one fugue voice plays only that voice."
    ///
    /// Eight measures, so all four entries have happened. Two independent
    /// measurements, because on a fugue neither alone is sufficient:
    ///
    /// * **The bass disappears.** The bass sings below the tenor's lowest note,
    ///   and a harmonic can never fall below its own fundamental, so energy at
    ///   the bass's pitches can only have come from the bass.
    /// * **The result is bit-for-bit a render with every other line muted.**
    ///   Muting removes exactly one line (`testPresetMuteSilencesExactlyThatLine`
    ///   and PLY003's own suite), so this says "and nothing but that voice"
    ///   about the two upper voices as well.
    ///
    /// The upper voices are deliberately *not* probed by frequency: this
    /// subject is answered at the octave, so every soprano pitch coincides with
    /// the tenor's own second harmonic. A single-bin probe there would be
    /// measuring the tenor and calling it the soprano.
    func testSoloingOneFugueVoicePlaysOnlyThatVoice() throws {
        let piece = try importScore(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 8), named: "fugue.musicxml"
        )
        let score = try compile(piece)
        XCTAssertEqual(try store.lineInventory(for: score).count, 4, "four fugal voices")

        let full = try renderActivePreset(score)

        // Score order is soprano, answer, tenor, bass.
        let preset = try store.activePreset(for: score)
        let tenor = preset.lines[2].lineID
        _ = try store.presets.setMixer(LineMixerState(isSoloed: true), forLine: tenor, in: preset)
        let soloed = try renderActivePreset(score)

        func energy(_ audio: PlaybackEngine.RenderedAudio, _ midiNote: Int) -> Double {
            AudioRenderFixtures.energy(
                audio.left,
                atHertz: AudioRenderFixtures.frequency(ofMIDINote: midiNote),
                sampleRate: audio.sampleRate
            )
        }

        // The bass subject: C3 and G2, both below the tenor's lowest note (G3).
        for bassNote in [48, 43] {
            XCTAssertGreaterThan(energy(full, bassNote), 1e-5,
                                 "The bass is not audible in the full mix at MIDI \(bassNote).")
            XCTAssertLessThan(
                energy(soloed, bassNote), energy(full, bassNote) / 20,
                "The bass is still audible at MIDI \(bassNote) while the tenor is soloed."
            )
        }

        // The tenor itself is not quieter for being soloed.
        XCTAssertGreaterThan(energy(soloed, 60), energy(full, 60) * 0.5)

        // …and nothing but the tenor is left.
        let current = try XCTUnwrap(try store.presets.activePreset(forPieceID: score.pieceID))
        var muted = try store.presets.setMixer(.neutral, forLine: tenor, in: current)
        for line in [preset.lines[0], preset.lines[1], preset.lines[3]] {
            muted = try store.presets.setMixer(
                LineMixerState(isMuted: true), forLine: line.lineID, in: muted
            )
        }
        let othersMuted = try renderActivePreset(score)

        XCTAssertEqual(
            soloed.canonicalData(), othersMuted.canonicalData(),
            "Soloing the tenor is not the same as silencing the other three voices."
        )
        XCTAssertGreaterThan(soloed.peak(), 0.001, "…and the tenor is not silence.")
        XCTAssertNotEqual(full.canonicalData(), soloed.canonicalData())
    }

    // MARK: Changing an assignment on a running engine

    /// `setVoices` replaces the sounds on an engine that already has a
    /// timeline, and the result is the same as having built it that way.
    func testChangingTheAssignmentOnALoadedEngineMatchesBuildingItThatWay() throws {
        let (_, score) = try twoLinePiece()
        let bright = try store.sounds.create(patch: brightPatch(), named: "Bright", in: .leads)
        let preset = try store.activePreset(for: score)
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: bright.id), toLine: preset.lines[0].lineID, in: preset
        )
        let target = try store.openActivePreset(for: score)
        let realized = timeline(score)

        let builtThatWay = try PlaybackEngine.renderTimelineOffline(
            realized, voices: target.voiceAssignment()
        ) { $0.play() }

        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: realized)
        try target.apply(to: engine)
        engine.play()
        let switched = try engine.renderOffline(
            frameCount: try XCTUnwrap(engine.loadedProgram).totalFrames
        )

        XCTAssertEqual(
            builtThatWay.canonicalData(), switched.canonicalData(),
            "Applying a preset to a loaded engine must produce the same audio as loading it "
                + "with that preset in the first place."
        )
    }

    // MARK: A rebuild keeps the mix (REQ-008 with REQ-015)

    /// Changing one line's sound must not throw the owner's mix away.
    ///
    /// A rebuild allocates a fresh C engine whose strips start at unity,
    /// centred and unmuted. Before this increment nothing ever set them to
    /// anything else, so that reset was invisible; now that volume, pan, mute
    /// and solo are owner state it would be a plain defect — and `setVoices` is
    /// public, so the obvious ASN002 call ("the owner picked another sound for
    /// line 3") would have hit it.
    func testChangingOneLinesSoundKeepsTheMixOnEveryOtherLine() throws {
        let (_, score) = try twoLinePiece()
        let bright = try store.sounds.create(patch: brightPatch(), named: "Bright", in: .leads)
        let performance = try store.openActivePreset(for: score)
        let lower = performance.lines[1].lineID

        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline(score))

        // A mix set directly on the busses, as ASN002 will while dragging.
        let strip = try XCTUnwrap(engine.mixer(for: lower))
        strip.gain = 0.3
        strip.pan = 0.8
        strip.isMuted = true
        engine.masterGain = 0.7

        // Change only the upper line's sound.
        var providers: [ScoreLineID: any LineVoiceProvider] = [:]
        providers[performance.lines[0].lineID] = SynthPatchVoiceProvider(patch: bright.patch)
        try engine.setVoices(LineVoiceAssignment(providersByLine: providers))

        let after = try XCTUnwrap(engine.mixer(for: lower))
        XCTAssertEqual(after.gain, 0.3, accuracy: 1e-6, "The line's volume was reset.")
        XCTAssertEqual(after.pan, 0.8, accuracy: 1e-6, "The line's pan was reset.")
        XCTAssertTrue(after.isMuted, "The line's mute was dropped.")
        XCTAssertEqual(engine.masterGain, 0.7, accuracy: 1e-6, "The master gain was reset.")
    }

    /// The same guarantee on the path a device change takes (REQ-015). Entering
    /// offline rendering rebuilds through exactly the code an output switch
    /// does, so this exercises that recovery without needing hardware to leave
    /// the room.
    func testTheMixSurvivesTheRebuildADeviceChangePerforms() throws {
        let (_, score) = try twoLinePiece()
        let performance = try store.openActivePreset(for: score)
        let upper = performance.lines[0].lineID

        let engine = PlaybackEngine()
        try engine.load(timeline: timeline(score))
        let strip = try XCTUnwrap(engine.mixer(for: upper))
        strip.gain = 0.15
        strip.isSoloed = true

        try engine.setRenderMode(.offline(sampleRate: 44_100))

        let after = try XCTUnwrap(engine.mixer(for: upper))
        XCTAssertEqual(after.gain, 0.15, accuracy: 1e-6)
        XCTAssertTrue(after.isSoloed)
        XCTAssertEqual(engine.loadedProgram?.sampleRate, 44_100, "The rebuild did happen.")
    }

    // MARK: The new real-time load profile (REQ-013)

    /// The dropout guardrail against the load **this leaf introduces**: the
    /// orchestral reference with every line on a *different* shipped sound.
    ///
    /// PLY003's and SYN001's guardrails already cover eighteen lines through
    /// one patch, and this change does not regress them. What they cannot cover
    /// is the profile that only becomes reachable now: eighteen simultaneous
    /// voices each running a different effect chain, which is strictly more
    /// per-block work than eighteen copies of one. Opt in with
    /// `SYNTH_REALTIME_GUARDRAIL=1`, like the others, because it takes as long
    /// as the piece does.
    func testTheOrchestralReferencePlaysDropoutFreeWithADifferentSoundPerLine() throws {
        try XCTSkipIf(
            !AudioRenderFixtures.hasOutputDevice,
            "No audio output device on this machine (expected on a headless CI runner)."
        )
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SYNTH_REALTIME_GUARDRAIL"] != "1",
            "Set SYNTH_REALTIME_GUARDRAIL=1 to run the full-length real-time guardrail."
        )

        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(), settings: .standard
        )
        let palette = ShippedSoundCollection.standard.sounds
        // Round-robin, so a line's sound is fixed but no two adjacent lines
        // share one and every shipped effect chain is in the mix.
        let byLine = Dictionary(
            uniqueKeysWithValues: timeline.lines.enumerated().map { index, line in
                (
                    line.id,
                    SynthPatchVoiceProvider(patch: palette[index % palette.count].patch)
                        as any LineVoiceProvider
                )
            }
        )

        let expectedSeconds = Double(timeline.totalMicroseconds) / 1_000_000
        let engine = PlaybackEngine(voices: LineVoiceAssignment(providersByLine: byLine))
        try engine.load(timeline: timeline)
        try engine.start()
        engine.resetStatistics()
        engine.play()

        let started = Date()
        while Date().timeIntervalSince(started) < 5, engine.transportState != .playing {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(engine.transportState, .playing, "Playback never started.")

        while engine.transportState == .playing,
              Date().timeIntervalSince(started) < expectedSeconds + 15 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let statistics = engine.statistics
        let reason = engine.pauseReason
        engine.stopEngine()

        print("""
            Dropout guardrail — orchestral reference, one sound per line
              lines:            \(timeline.lines.count)
              distinct sounds:  \(Set(byLine.values.map(\.identifier)).count)
              events:           \(timeline.eventCount)
              timeline length:  \(String(format: "%.1f", expectedSeconds)) s
              wall clock:       \(String(format: "%.1f", elapsed)) s
              rendered blocks:  \(statistics.renderedBlocks)
              overload blocks:  \(statistics.overloadBlocks) \
            (\(String(format: "%.4f", statistics.overloadRatio * 100))%)
              overload pauses:  \(statistics.overloadPauses)
              peak level:       \(String(format: "%.3f", statistics.peakLevel))
              ended because:    \(reason)
            """)

        XCTAssertEqual(reason, .reachedEnd, "Playback stopped for \(reason).")
        XCTAssertEqual(statistics.overloadPauses, 0, "The engine degraded to a pause under load.")
        XCTAssertLessThan(
            statistics.overloadRatio, 0.001,
            "\(statistics.overloadBlocks) of \(statistics.renderedBlocks) blocks missed their deadline."
        )
    }
}
