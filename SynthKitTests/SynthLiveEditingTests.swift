import XCTest
@testable import SynthKit
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Issue #19: "With a piece playing through the sound under edit, moving its
/// filter cutoff is audible while playback continues uninterrupted."
///
/// Two halves, and the second is the one that is easy to fake. Proving the
/// cutoff moved is a spectrum measurement and takes one assertion. Proving
/// playback *continued* takes a different kind of measurement entirely: a
/// rebuilt voice would also change the spectrum, and would also pass any test
/// that only looked at the two ends. So every assertion here about a parameter
/// change is paired with one about the audio across the moment it happened —
/// the level never drops out, the reverb tail is still ringing, the notes that
/// were sounding are still sounding, and the transport never left `playing`.
final class SynthLiveEditingTests: XCTestCase {

    // MARK: The voice

    /// A saw through a filter, which is the shape every cutoff claim needs:
    /// plenty of harmonics for the filter to have an opinion about.
    private func sawPatch(cutoffHertz: Double) -> SynthPatch {
        SynthPatch(
            identifier: "test.live",
            name: "Live",
            oscillators: [
                SynthPatch.Oscillator(type: .analog, analogShape: .saw, level: 1.0),
                SynthPatch.Oscillator(),
                SynthPatch.Oscillator()
            ],
            filter: SynthPatch.Filter(
                isEnabled: true, type: .lowpass, poles: 4,
                cutoffHertz: cutoffHertz, resonance: 0, keyTracking: 0
            ),
            amplitudeEnvelope: SynthPatch.Envelope(
                attackSeconds: 0.005, decaySeconds: 0.01,
                sustainLevel: 1.0, releaseSeconds: 0.2, curve: 0
            ),
            outputLevel: 0.5
        )
    }

    /// Brightness: how much energy sits in the harmonics a low-pass filter is
    /// there to remove.
    private func upperHarmonicEnergy(_ samples: [Float], fundamental: Double) -> Double {
        AudioRenderFixtures
            .harmonicEnergies(samples, fundamental: fundamental, count: 12, sampleRate: 48_000)
            .dropFirst(4)
            .reduce(0, +)
    }

    // MARK: - The headline claim, at the voice

    /// Moving the cutoff while a note is sounding changes the sound, and the
    /// note keeps sounding while it happens.
    func testMovingTheCutoffMidNoteIsAudibleAndTheNoteDoesNotStop() throws {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)
        let fundamental = AudioRenderFixtures.frequency(ofMIDINote: 45)   // A2, 110 Hz

        harness.noteOn(45, velocity: 100)
        let bright = harness.render(seconds: 0.5)

        let result = live.apply(sawPatch(cutoffHertz: 300))
        XCTAssertTrue(result.isComplete, "The voice refused the edit: \(result)")
        XCTAssertEqual(result.accepted, 1)

        let dark = harness.render(seconds: 0.5)

        // 1. It is audible.
        let before = upperHarmonicEnergy(bright, fundamental: fundamental)
        let after = upperHarmonicEnergy(dark, fundamental: fundamental)
        XCTAssertGreaterThan(
            AudioRenderFixtures.decibels(before / max(after, 1e-12)), 20,
            "Closing the cutoff from 12 kHz to 300 Hz removed less than 20 dB of upper harmonics: "
                + "\(before) → \(after)."
        )

        // 2. The note is still sounding, at a comparable level. A rebuilt voice
        //    would have restarted the envelope; a stopped one would be silent.
        let sustained = AudioRenderFixtures.rms(dark, from: 0.3, to: 0.5, sampleRate: 48_000)
        XCTAssertGreaterThan(sustained, 0.01, "The note stopped when the cutoff moved.")

        // 3. Nothing dropped out across the moment of the edit. The quietest
        //    short window either side of the boundary is still audibly loud —
        //    which a re-triggered envelope or a cleared voice could not be.
        let boundary = Array(bright.suffix(4_800)) + Array(dark.prefix(4_800))
        let quietest = AudioRenderFixtures.rmsEnvelope(boundary).min() ?? 0
        XCTAssertGreaterThan(
            quietest, 0.005,
            "The output dropped to \(quietest) across the edit; playback was interrupted."
        )

        // 4. The fundamental — which the filter barely touches at 300 Hz — is
        //    still there. The note did not merely survive, it is the same note.
        let fundamentalAfter = AudioRenderFixtures
            .energy(dark, atHertz: fundamental, sampleRate: 48_000)
        XCTAssertGreaterThan(fundamentalAfter, 0.01)
    }

    /// The render thread takes up the published patch, rather than the control
    /// thread merely believing it did.
    func testAPublishedPatchIsOnlyCountedOnceItHasBeenRendered() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 8_000))
        let harness = SynthVoiceHarness(live: live)

        XCTAssertEqual(live.adoptionsTakenUp, 0)

        live.apply(sawPatch(cutoffHertz: 400))
        XCTAssertEqual(live.adoptionsTakenUp, 0, "Publishing alone must not count as adoption.")

        _ = harness.render(seconds: 0.02)
        XCTAssertEqual(live.adoptionsTakenUp, 1)

        // Several edits between two blocks cost the intermediate values, not a
        // torn patch: the voice takes up the newest and only the newest.
        live.apply(sawPatch(cutoffHertz: 900))
        live.apply(sawPatch(cutoffHertz: 1_100))
        live.apply(sawPatch(cutoffHertz: 1_300))
        _ = harness.render(seconds: 0.02)
        XCTAssertEqual(live.adoptionsTakenUp, 2)
    }

    /// A knob nobody moved costs nothing: rendering without an edit never
    /// touches the config at all.
    func testRenderingWithoutAnEditAdoptsNothing() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 8_000))
        let harness = SynthVoiceHarness(live: live)
        _ = harness.render(seconds: 0.2)
        XCTAssertEqual(live.adoptionsTakenUp, 0)
    }

    /// A dragged knob is hundreds of edits, and the result has to be the
    /// destination rather than whichever one happened to land on a boundary.
    func testASweepEndsWhereTheOwnerLeftIt() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)
        harness.noteOn(45, velocity: 100)
        _ = harness.render(seconds: 0.2)

        // 200 steps down, rendering a little between each, the way a drag
        // interleaves with the audio callback.
        for step in 0..<200 {
            let cutoff = 12_000 * pow(300.0 / 12_000.0, Double(step + 1) / 200)
            live.apply(sawPatch(cutoffHertz: cutoff))
            _ = harness.render(seconds: 0.001)
        }

        let settled = harness.render(seconds: 0.3)
        let fundamental = AudioRenderFixtures.frequency(ofMIDINote: 45)
        let sweptEnergy = upperHarmonicEnergy(settled, fundamental: fundamental)

        let reference = SynthVoiceHarness(patch: sawPatch(cutoffHertz: 300))
        reference.noteOn(45, velocity: 100)
        _ = reference.render(seconds: 0.2)
        let referenceEnergy = upperHarmonicEnergy(
            reference.render(seconds: 0.3), fundamental: fundamental)

        XCTAssertEqual(
            AudioRenderFixtures.decibels(sweptEnergy / max(referenceEnergy, 1e-12)), 0,
            accuracy: 3,
            "A sweep to 300 Hz did not land where a voice built at 300 Hz sits."
        )

        // And it never went quiet on the way.
        XCTAssertGreaterThan(AudioRenderFixtures.rmsEnvelope(settled).min() ?? 0, 0.005)
    }

    // MARK: Effect state survives an edit

    /// A reverb tail is a second of audio the voice has not played yet. An edit
    /// that cleared it would be a click and a swallowed tail, so this checks
    /// the tail is still ringing after the sound has changed underneath it.
    func testAnEditDoesNotClearTheEffectTail() {
        var patch = sawPatch(cutoffHertz: 6_000)
        patch.reverb = SynthPatch.Reverb(
            isEnabled: true, roomSize: 0.9, dampening: 0.2, mix: 0.9, preDelaySeconds: 0.02)

        let live = SynthPatchLiveVoices(patch: patch)
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(60, velocity: 110)
        _ = harness.render(seconds: 0.4)
        harness.noteOff(60)
        _ = harness.render(seconds: 0.3)

        // The note has been released; everything still audible is the room.
        let beforeEdit = harness.render(seconds: 0.1)
        let tailBefore = AudioRenderFixtures.rms(beforeEdit, from: 0, to: 0.1, sampleRate: 48_000)
        XCTAssertGreaterThan(tailBefore, 0.001, "There was no tail to preserve.")

        var edited = patch
        edited.filter.cutoffHertz = 400
        live.apply(edited)

        let afterEdit = harness.render(seconds: 0.1)
        let tailAfter = AudioRenderFixtures.rms(afterEdit, from: 0, to: 0.1, sampleRate: 48_000)

        // Still ringing, and still decaying rather than restarting from zero.
        XCTAssertGreaterThan(
            tailAfter, tailBefore * 0.2,
            "The reverb tail collapsed from \(tailBefore) to \(tailAfter) when the patch changed."
        )
    }

    // MARK: Parameters that used to be fixed at note-on

    /// Detune was resolved once when the note started. An editor has to be able
    /// to move it while the note is held, or the control does nothing until the
    /// owner plays another one.
    func testDetuningAnOscillatorMovesANoteThatIsAlreadySounding() {
        var patch = sawPatch(cutoffHertz: 16_000)
        patch.oscillators[0] = SynthPatch.Oscillator(
            type: .analog, analogShape: .sine, level: 1.0)

        let live = SynthPatchLiveVoices(patch: patch)
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(69, velocity: 100)                  // A4, 440 Hz
        _ = harness.render(seconds: 0.3)

        var detuned = patch
        detuned.oscillators[0].detuneSemitones = 12        // an octave up
        live.apply(detuned)

        let after = harness.render(seconds: 0.3)
        let at440 = AudioRenderFixtures.energy(after, atHertz: 440, sampleRate: 48_000)
        let at880 = AudioRenderFixtures.energy(after, atHertz: 880, sampleRate: 48_000)

        XCTAssertGreaterThan(
            AudioRenderFixtures.decibels(at880 / max(at440, 1e-12)), 20,
            "The held note did not move to 880 Hz: 440 Hz had \(at440), 880 Hz had \(at880)."
        )
    }

    /// The velocity exponent was the other one fixed at note-on.
    func testVelocitySensitivityAppliesToANoteThatIsAlreadySounding() {
        let patch = sawPatch(cutoffHertz: 16_000)
        let live = SynthPatchLiveVoices(patch: patch)
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(60, velocity: 40)                   // quiet, so the exponent bites
        let before = harness.render(seconds: 0.3)

        var sensitive = patch
        sensitive.velocitySensitivity = 4.0
        live.apply(sensitive)
        let after = harness.render(seconds: 0.3)

        let levelBefore = AudioRenderFixtures.rms(before, from: 0.1, to: 0.3, sampleRate: 48_000)
        let levelAfter = AudioRenderFixtures.rms(after, from: 0.1, to: 0.3, sampleRate: 48_000)
        XCTAssertLessThan(
            levelAfter, levelBefore * 0.6,
            "Raising the velocity exponent did not make a soft held note softer."
        )
        XCTAssertGreaterThan(levelAfter, 0, "The note stopped instead.")
    }

    /// Everything else was already re-read every control block. This is the one
    /// assertion that says so for a representative parameter of each kind, so a
    /// future change that starts caching one of them fails here.
    func testTheEffectMixOscillatorLevelAndOutputLevelAreAllLiveOnAHeldNote() {
        let patch = sawPatch(cutoffHertz: 16_000)
        let live = SynthPatchLiveVoices(patch: patch)
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(60, velocity: 100)
        let before = harness.render(seconds: 0.25)

        var quieter = patch
        quieter.outputLevel = 0.05
        quieter.oscillators[0].level = 0.5
        live.apply(quieter)
        let after = harness.render(seconds: 0.25)

        let levelBefore = AudioRenderFixtures.rms(before, from: 0.05, to: 0.25, sampleRate: 48_000)
        let levelAfter = AudioRenderFixtures.rms(after, from: 0.05, to: 0.25, sampleRate: 48_000)
        XCTAssertLessThan(levelAfter, levelBefore * 0.2)
        XCTAssertGreaterThan(levelAfter, 0)
    }

    // MARK: Test notes

    /// Press a key with no piece behind it and hear the sound. REQ-016's
    /// audition half, at the layer that produces the audio.
    func testANoteQueuedFromTheControlThreadSounds() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)

        let silence = harness.render(seconds: 0.1)
        XCTAssertEqual(AudioRenderFixtures.peak(silence), 0, "Something was audible before any note.")

        XCTAssertTrue(live.post(.noteOn(note: 64, velocity: 100)))
        let sounding = harness.render(seconds: 0.3)

        let fundamental = AudioRenderFixtures.frequency(ofMIDINote: 64)
        XCTAssertGreaterThan(
            AudioRenderFixtures.energy(sounding, atHertz: fundamental, sampleRate: 48_000), 0.01,
            "A queued test note produced no energy at its own pitch."
        )
    }

    func testAQueuedNoteOffReleasesTheNote() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)

        live.post(.noteOn(note: 64, velocity: 100))
        _ = harness.render(seconds: 0.3)
        live.post(.noteOff(note: 64))

        let released = harness.render(seconds: 1.0)
        XCTAssertLessThan(
            AudioRenderFixtures.rms(released, from: 0.6, to: 1.0, sampleRate: 48_000), 1e-4,
            "The note did not stop when its key came up."
        )
    }

    /// The pedal, and the panic. Closing the editor must not leave a note on.
    func testTheSustainPedalHoldsAndAllNotesOffReleasesEverything() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)

        live.post(.sustainPedal(isDown: true))
        live.post(.noteOn(note: 60, velocity: 100))
        live.post(.noteOn(note: 64, velocity: 100))
        live.post(.noteOn(note: 67, velocity: 100))
        _ = harness.render(seconds: 0.2)

        live.post(.noteOff(note: 60))
        live.post(.noteOff(note: 64))
        live.post(.noteOff(note: 67))
        let held = harness.render(seconds: 0.3)
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(held, from: 0.1, to: 0.3, sampleRate: 48_000), 0.01,
            "The pedal did not hold the chord."
        )

        live.post(.allNotesOff)
        let silenced = harness.render(seconds: 1.0)
        XCTAssertLessThan(
            AudioRenderFixtures.rms(silenced, from: 0.6, to: 1.0, sampleRate: 48_000), 1e-4,
            "Everything-off left something sounding."
        )
    }

    /// The queue is bounded, and a full one says so rather than dropping a
    /// note-off in silence — because a dropped note-off is a stuck note.
    func testAFullEventQueueIsReportedRatherThanSwallowed() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let harness = SynthVoiceHarness(live: live)

        var refusals = 0
        for note in 0..<400 where !live.post(.noteOn(note: 40 + (note % 40), velocity: 80)) {
            refusals += 1
        }
        XCTAssertGreaterThan(refusals, 0, "An unbounded queue is not a queue.")

        // And it recovers: once the render thread has drained it, it takes more.
        _ = harness.render(seconds: 0.02)
        XCTAssertTrue(live.post(.noteOn(note: 72, velocity: 100)))
    }

    // MARK: Registration and lifetime

    func testAVoiceIsRegisteredWhileItExistsAndGoneAfterItIsReleased() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 1_000))
        XCTAssertEqual(live.voiceCount, 0)

        var harness: SynthVoiceHarness? = SynthVoiceHarness(live: live)
        XCTAssertEqual(live.voiceCount, 1)
        XCTAssertEqual(live.apply(sawPatch(cutoffHertz: 900)).accepted, 1)

        harness = nil
        XCTAssertNil(harness)
        XCTAssertEqual(live.voiceCount, 0)

        // An edit with nothing listening is not an error; it is the ordinary
        // case of editing while nothing is playing, and the patch is still kept.
        let result = live.apply(sawPatch(cutoffHertz: 800))
        XCTAssertEqual(result, SynthPatchLiveVoices.Result(accepted: 0, refused: 0))
        XCTAssertEqual(live.currentPatch.filter.cutoffHertz, 800)
    }

    /// A voice built after the edit starts out playing the edited sound, so a
    /// graph rebuilt for a device change does not quietly undo the owner's work.
    func testAVoiceBuiltAfterAnEditStartsFromTheEditedPatch() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        live.apply(sawPatch(cutoffHertz: 300))

        let harness = SynthVoiceHarness(live: live)
        harness.noteOn(45, velocity: 100)
        let samples = harness.render(seconds: 0.4)

        let fundamental = AudioRenderFixtures.frequency(ofMIDINote: 45)
        let reference = SynthVoiceHarness(patch: sawPatch(cutoffHertz: 300))
        reference.noteOn(45, velocity: 100)
        let referenceSamples = reference.render(seconds: 0.4)

        XCTAssertEqual(
            upperHarmonicEnergy(samples, fundamental: fundamental),
            upperHarmonicEnergy(referenceSamples, fundamental: fundamental),
            accuracy: 1e-6,
            "A newly built voice did not start from the channel's current patch."
        )
        // Nothing was adopted, because there was nothing left to adopt: the
        // patch was already the one the voice was constructed with.
        XCTAssertEqual(live.adoptionsTakenUp, 0)
    }

    /// A voice whose graph has been rebuilt at another rate refuses the edit
    /// rather than rendering geometry that belongs to a rate it is not at.
    func testAnEditIsRefusedByAVoicePreparedAtAnotherSampleRate() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 5_000))
        let instance = SynthPatchVoiceProvider(live: live).makeVoice(sampleRate: 48_000)
        defer { instance.release() }

        // The engine re-prepares a voice when the device rate changes. Doing it
        // behind the channel's back is exactly the state this guards against.
        var vtable = instance.vtable
        vtable.prepare(vtable.state, 96_000)

        let result = live.apply(sawPatch(cutoffHertz: 400))
        XCTAssertEqual(result.refused, 1)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertFalse(result.isComplete)

        // …and the patch is still kept, so the caller can rebuild from it.
        XCTAssertEqual(live.currentPatch.filter.cutoffHertz, 400)
    }

    // MARK: Auditioning a voice on its own

    /// The audition path puts the same mono signal in both channels, and
    /// touches only the buffers it was given.
    func testTheStereoAuditionRenderFillsBothChannelsIdentically() {
        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let instance = SynthPatchVoiceProvider(live: live).makeVoice(sampleRate: 48_000)
        defer { instance.release() }
        let state = OpaquePointer(instance.vtable.state!)

        live.post(.noteOn(note: 60, velocity: 100))

        let frames = 512
        var left = [Float](repeating: .nan, count: frames)
        var right = [Float](repeating: .nan, count: frames)
        var silence: Int32 = 1

        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                var list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: leftBuffer.baseAddress)
                list[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: rightBuffer.baseAddress)

                let status = synth_patch_voice_render_stereo(
                    state, list.unsafeMutablePointer, Int32(frames), &silence)
                XCTAssertEqual(status, 0)
            }
        }

        XCTAssertEqual(silence, 0)
        XCTAssertEqual(left, right, "The two channels of the audition are not the same signal.")
        XCTAssertGreaterThan(AudioRenderFixtures.peak(left), 0, "The audition rendered silence.")
    }

    // MARK: - Through the whole engine

    /// The acceptance criterion as worded, at the layer the owner hears: a
    /// piece playing through the sound under edit, the cutoff moved, and
    /// playback carrying on across it.
    ///
    /// Rendered offline so the measurement is exact and repeatable — the same
    /// engine, the same program, the same voices as live playback, with the
    /// clock replaced. What is asserted is not only that the audio changed but
    /// that it changed *underneath a transport that never stopped*.
    func testMovingTheCutoffDuringPlaybackIsAudibleAndPlaybackContinues() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let engine = PlaybackEngine(voiceProvider: SynthPatchVoiceProvider(live: live))
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)
        engine.play()

        let bright = try engine.renderOffline(frameCount: 48_000)
        XCTAssertEqual(engine.transportState, .playing)
        let positionBefore = engine.playbackPositionFrame

        let result = live.apply(sawPatch(cutoffHertz: 250))
        XCTAssertTrue(result.isComplete, "\(result.refused) of the piece's voices refused the edit.")
        XCTAssertEqual(result.accepted, timeline.lines.count)

        let dark = try engine.renderOffline(frameCount: 48_000)

        // 1. Playback continued: the transport never left `playing`, the
        //    playhead kept advancing, and nothing was reported as a pause.
        XCTAssertEqual(engine.transportState, .playing)
        XCTAssertEqual(engine.pauseReason, .none)
        XCTAssertGreaterThan(engine.playbackPositionFrame, positionBefore)
        XCTAssertEqual(engine.statistics.overloadPauses, 0)

        // 2. Every voice took the edit up.
        XCTAssertEqual(live.adoptionsTakenUp, 1)

        // 3. It is audible: the second before the edit is much brighter than
        //    the second after it.
        let brightEnergy = self.energyAboveTwoKilohertz(bright.left)
        let darkEnergy = self.energyAboveTwoKilohertz(dark.left)
        XCTAssertGreaterThan(
            AudioRenderFixtures.decibels(brightEnergy / max(darkEnergy, 1e-12)), 12,
            "Closing the cutoff to 250 Hz removed \(brightEnergy) → \(darkEnergy) above 2 kHz."
        )

        // 4. And the music did not stop to let it happen. The join between the
        //    two renders is not a gap.
        let boundary = Array(bright.left.suffix(2_400)) + Array(dark.left.prefix(2_400))
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(boundary, from: 0, to: 0.1, sampleRate: 48_000), 1e-4,
            "The output fell silent across the edit."
        )
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(dark.left, from: 0.5, to: 1.0, sampleRate: 48_000), 1e-4,
            "The piece went quiet after the edit."
        )
    }

    /// Energy above 2 kHz, sampled at eight probes — the band a 250 Hz
    /// four-pole low-pass is there to remove.
    private func energyAboveTwoKilohertz(_ samples: [Float]) -> Double {
        stride(from: 2_000.0, through: 9_000.0, by: 1_000.0).reduce(0.0) { total, hertz in
            total + AudioRenderFixtures.energy(samples, atHertz: hertz, sampleRate: 48_000)
        }
    }

    /// Editing while nothing is playing still changes the sound — the edit is
    /// kept on the channel and the next voice built starts from it. The issue's
    /// "editing during playback stop degrades gracefully with edits still
    /// persisted to the patch".
    func testAnEditMadeWhileStoppedIsHeardWhenPlaybackStartsAgain() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let live = SynthPatchLiveVoices(patch: sawPatch(cutoffHertz: 12_000))
        let engine = PlaybackEngine(voiceProvider: SynthPatchVoiceProvider(live: live))
        try engine.setRenderMode(.offline(sampleRate: 48_000))
        try engine.load(timeline: timeline)

        // Stopped. Nothing is rendering, so nothing adopts — and the edit is
        // still kept.
        live.apply(sawPatch(cutoffHertz: 250))
        XCTAssertEqual(live.adoptionsTakenUp, 0)
        XCTAssertEqual(live.currentPatch.filter.cutoffHertz, 250)

        engine.play()
        let audio = try engine.renderOffline(frameCount: 48_000)

        // The voices were built before the edit, so they adopt it on their
        // first block rather than starting from the old patch.
        XCTAssertEqual(live.adoptionsTakenUp, 1)

        let reference = PlaybackEngine(
            voiceProvider: SynthPatchVoiceProvider(patch: sawPatch(cutoffHertz: 250)))
        try reference.setRenderMode(.offline(sampleRate: 48_000))
        try reference.load(timeline: timeline)
        reference.play()
        let referenceAudio = try reference.renderOffline(frameCount: 48_000)

        XCTAssertEqual(
            AudioRenderFixtures.decibels(
                energyAboveTwoKilohertz(audio.left)
                    / max(energyAboveTwoKilohertz(referenceAudio.left), 1e-12)),
            0, accuracy: 1,
            "An edit made while stopped did not produce the sound it asked for."
        )
    }
}

/// Issue #19: the two things a test keyboard has to get right, at the layer
/// that owns them.
///
/// The editor's on-screen key has two activation paths — a `Button`, which is
/// what the keyboard and VoiceOver reach, and a drag gesture, which is what
/// gives press-and-hold. A pointer click runs both, and driving the running app
/// showed that striking the note twice. The view arbitrates between them, but
/// the *authority* on whether a key is already down is here, in the audition
/// engine, because this is where a note-on becomes audible.
@MainActor
final class SoundAuditionKeyboardTests: XCTestCase {
    private func makeEngine() -> (SoundAuditionEngine, SynthPatchLiveVoices) {
        let live = SynthPatchLiveVoices(patch: .defaultVoice)
        return (SoundAuditionEngine(live: live), live)
    }

    /// One press, one release, nothing left holding — and exactly two events.
    func testOnePressAndReleaseStrikesTheNoteExactlyOnce() {
        let (engine, live) = makeEngine()

        XCTAssertTrue(engine.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.soundingNotes, [60])
        XCTAssertEqual(live.postedEventCount, 1)

        XCTAssertTrue(engine.noteOff(60))
        XCTAssertTrue(engine.soundingNotes.isEmpty)
        XCTAssertEqual(live.postedEventCount, 2)
    }

    /// The failure the view was showing: two activation paths, one key.
    func testAKeyAlreadyDownIsNotStruckAgain() {
        let (engine, live) = makeEngine()

        XCTAssertTrue(engine.noteOn(60, velocity: 100))
        XCTAssertFalse(engine.noteOn(60, velocity: 100), "The second press should be refused.")
        XCTAssertEqual(live.postedEventCount, 1, "A held key was struck twice.")
        XCTAssertEqual(engine.soundingNotes, [60])
    }

    /// A stray release cannot cut a note nobody pressed — which is what a
    /// trailing release from the wrong activation path would otherwise be.
    func testReleasingAKeyThatIsNotHeldDoesNothing() {
        let (engine, live) = makeEngine()

        XCTAssertFalse(engine.noteOff(60))
        XCTAssertEqual(live.postedEventCount, 0)

        engine.noteOn(60)
        engine.noteOff(60)
        XCTAssertFalse(engine.noteOff(60), "A second release should be refused.")
        XCTAssertEqual(live.postedEventCount, 2)
    }

    func testAllNotesOffClearsEveryHeldKey() {
        let (engine, live) = makeEngine()

        for note in [48, 60, 64, 67] { engine.noteOn(note) }
        XCTAssertEqual(engine.soundingNotes, [48, 60, 64, 67])

        engine.allNotesOff()
        XCTAssertTrue(engine.soundingNotes.isEmpty)
        XCTAssertEqual(live.postedEventCount, 5)

        // …and the keys are free to be pressed again afterwards.
        XCTAssertTrue(engine.noteOn(60))
    }
}

/// Issue #19, from review: re-enabling an effect must not replay what was left
/// in its buffer.
///
/// `isEnabled` is a live parameter now, and installing a published patch
/// deliberately does not clear the effect buffers — that is what stops an
/// ordinary parameter move from clicking, and `testAnEditDoesNotClearTheEffect\
/// Tail` is the test of it. The `false → true` transition is the exception: a
/// disabled effect stops being written but keeps its contents, so switching a
/// delay back on would otherwise return audio from whenever it was last on.
final class SynthEffectResumeTests: XCTestCase {
    private func loudDelayPatch(delayEnabled: Bool) -> SynthPatch {
        var patch = SynthPatch(
            identifier: "test.resume",
            name: "Resume",
            oscillators: [
                SynthPatch.Oscillator(type: .analog, analogShape: .saw, level: 1.0),
                SynthPatch.Oscillator(),
                SynthPatch.Oscillator()
            ],
            amplitudeEnvelope: SynthPatch.Envelope(
                attackSeconds: 0.001, decaySeconds: 0.01,
                sustainLevel: 1.0, releaseSeconds: 0.01, curve: 0),
            outputLevel: 0.5
        )
        patch.delay = SynthPatch.Delay(
            isEnabled: delayEnabled, timeSeconds: 0.3,
            feedback: 0.0, mix: 1.0, dampening: 0.0)
        return patch
    }

    func testSwitchingADelayBackOnDoesNotReplayItsOldBuffer() {
        let live = SynthPatchLiveVoices(patch: loudDelayPatch(delayEnabled: true))
        let harness = SynthVoiceHarness(live: live)

        // Fill the delay line with a loud note, then let it fall silent.
        harness.noteOn(60, velocity: 120)
        _ = harness.render(seconds: 0.1)
        harness.noteOff(60)
        _ = harness.render(seconds: 0.05)

        // Off. The line stops being written and keeps whatever is in it.
        live.apply(loudDelayPatch(delayEnabled: false))
        let whileOff = harness.render(seconds: 0.5)
        XCTAssertLessThan(
            AudioRenderFixtures.peak(whileOff), 0.02,
            "A disabled delay should not be audible at all."
        )

        // Back on, with nothing playing. Anything audible now is a ghost.
        live.apply(loudDelayPatch(delayEnabled: true))
        let afterResume = harness.render(seconds: 0.6)

        XCTAssertLessThan(
            AudioRenderFixtures.peak(afterResume), 1e-4,
            "Re-enabling the delay replayed \(AudioRenderFixtures.peak(afterResume)) of audio "
                + "from before it was switched off."
        )
    }

    /// The same for the reverb, whose buffers are the largest and whose ghost
    /// would be the longest.
    func testSwitchingAReverbBackOnDoesNotReplayItsOldBuffer() {
        func patch(reverbEnabled: Bool) -> SynthPatch {
            var patch = loudDelayPatch(delayEnabled: false)
            patch.reverb = SynthPatch.Reverb(
                isEnabled: reverbEnabled, roomSize: 0.9,
                dampening: 0.1, mix: 1.0, preDelaySeconds: 0.05)
            return patch
        }

        let live = SynthPatchLiveVoices(patch: patch(reverbEnabled: true))
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(60, velocity: 120)
        _ = harness.render(seconds: 0.1)
        harness.noteOff(60)
        _ = harness.render(seconds: 0.05)

        live.apply(patch(reverbEnabled: false))
        _ = harness.render(seconds: 0.3)

        live.apply(patch(reverbEnabled: true))
        let afterResume = harness.render(seconds: 0.5)

        XCTAssertLessThan(
            AudioRenderFixtures.peak(afterResume), 1e-4,
            "Re-enabling the reverb replayed audio from before it was switched off."
        )
    }

    /// …and the narrowness matters: an ordinary parameter move on an effect
    /// that stays on must still leave its tail alone.
    func testAnEffectThatStaysOnKeepsItsTailAcrossAParameterChange() {
        var patch = loudDelayPatch(delayEnabled: true)
        patch.delay.feedback = 0.6

        let live = SynthPatchLiveVoices(patch: patch)
        let harness = SynthVoiceHarness(live: live)

        harness.noteOn(60, velocity: 120)
        _ = harness.render(seconds: 0.1)
        harness.noteOff(60)
        _ = harness.render(seconds: 0.05)

        // Move the mix — the effect stays enabled throughout.
        var quieter = patch
        quieter.delay.mix = 0.8
        live.apply(quieter)

        let tail = harness.render(seconds: 0.5)
        XCTAssertGreaterThan(
            AudioRenderFixtures.peak(tail), 0.01,
            "Changing a delay's mix cleared its line; only enabling it should."
        )
    }
}
