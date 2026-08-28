import AVFoundation
import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// One patch, one voice, and a keyboard — the editor's audition.
///
/// **Why this is not `PlaybackEngine`.** That engine plays a *program*: a
/// timeline compiled into scheduled frames, walked by a transport. Auditioning
/// a sound under construction has none of those things. There is no piece, no
/// tempo, no measure, and the notes arrive when the owner presses a key rather
/// than at a frame worked out in advance. Bending the transport around that
/// would mean giving the render engine a live-note path it has no other reason
/// to have, and would make the editor's simplest requirement — press a key,
/// hear the sound — depend on the most complicated object in the project.
///
/// So this is the smaller thing instead: an `AVAudioEngine` with one source
/// node, one `SynthPatchVoiceProvider` voice behind it, and the same live
/// channel the editor pushes parameter changes through. The audio thread runs
/// one C call, exactly as the transport's does.
///
/// The graph stays connected while the editor is open and renders silence
/// between notes. That is deliberate: starting the hardware on the first key
/// press would put a device start-up in front of the note, and the note is the
/// thing being judged.
///
/// Owned by one thread at a time, the same contract `PlaybackEngine` states:
/// the editor drives it from the main actor, which is also where the
/// configuration notification arrives. `Sendable` so it can be held by a model
/// that is, not so two threads may share one.
public final class SoundAuditionEngine: @unchecked Sendable {
    /// Where a failure to make any sound is reported, so the editor can say so
    /// rather than looking broken.
    public enum AuditionError: Error, CustomStringConvertible {
        case couldNotStart(reason: String)

        public var description: String {
            switch self {
            case .couldNotStart(let reason):
                return "Synth could not start the audio output for auditioning: \(reason)"
            }
        }
    }

    /// The channel the voice follows. Publishing a patch here is what makes a
    /// parameter move audible without rebuilding anything.
    public let live: SynthPatchLiveVoices

    private let avEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var voice: LineVoiceInstance?
    private var configurationObserver: NSObjectProtocol?

    /// Notes the owner is currently holding down, so the graph can be rebuilt
    /// under them without leaving one stuck on.
    private var heldNotes: Set<Int> = []

    public private(set) var isRunning = false

    /// Set when the engine could not start. The editor still edits; it just
    /// cannot be heard, and says so.
    public private(set) var failureDescription: String?

    public init(live: SynthPatchLiveVoices) {
        self.live = live
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        avEngine.stop()
        voice?.release()
    }

    /// The rate the audition is running at, for a caller that wants to say so.
    public var sampleRate: Double {
        let rate = avEngine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 48_000
    }

    // MARK: Lifetime

    /// Build the graph and start the hardware. Idempotent.
    public func start() throws {
        guard !isRunning else { return }

        buildGraph()
        avEngine.prepare()
        do {
            try avEngine.start()
        } catch {
            let reason = (error as NSError).localizedDescription
            failureDescription = AuditionError.couldNotStart(reason: reason).description
            throw AuditionError.couldNotStart(reason: reason)
        }

        failureDescription = nil
        isRunning = true
        beginObservingConfiguration()
    }

    /// Release every held note and stop the hardware.
    ///
    /// Releasing first rather than tearing the graph down under a sounding
    /// note: the note ends the way the patch says it ends, and nothing is left
    /// holding a key down in a voice that is about to be rebuilt.
    public func stop() {
        allNotesOff()
        avEngine.stop()
        isRunning = false
    }

    // MARK: The keyboard

    /// Press a key. `velocity` is MIDI's 1…127.
    @discardableResult
    public func noteOn(_ midiNoteNumber: Int, velocity: Int = 96) -> Bool {
        heldNotes.insert(midiNoteNumber)
        return live.post(.noteOn(note: midiNoteNumber, velocity: velocity))
    }

    @discardableResult
    public func noteOff(_ midiNoteNumber: Int) -> Bool {
        heldNotes.remove(midiNoteNumber)
        return live.post(.noteOff(note: midiNoteNumber))
    }

    @discardableResult
    public func setSustainPedal(_ isDown: Bool) -> Bool {
        live.post(.sustainPedal(isDown: isDown))
    }

    @discardableResult
    public func allNotesOff() -> Bool {
        heldNotes.removeAll()
        return live.post(.allNotesOff)
    }

    /// Notes currently held, so the on-screen keyboard can show them lit.
    public var soundingNotes: Set<Int> { heldNotes }

    // MARK: Graph

    private func buildGraph() {
        if let existing = sourceNode {
            avEngine.detach(existing)
            sourceNode = nil
        }
        voice?.release()

        let rate = sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

        // Built from the live channel, so it starts out rendering whatever the
        // editor currently has rather than whatever it had when this engine was
        // created.
        let built = SynthPatchVoiceProvider(live: live).makeVoice(sampleRate: rate)
        voice = built
        let state = OpaquePointer(built.vtable.state!)

        // The whole Swift presence on this engine's audio thread. One captured
        // pointer, no ARC traffic, one call into C — the same shape as
        // `PlaybackEngine`'s trampoline, and held to the same rule by
        // `RealtimeSafetyTests`.
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            var silence: Int32 = 0
            let status = synth_patch_voice_render_stereo(
                state,
                audioBufferList,
                Int32(frameCount),
                &silence
            )
            isSilence.pointee = ObjCBool(silence != 0)
            return status
        }

        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: format)
        sourceNode = node
    }

    private func beginObservingConfiguration() {
        guard configurationObserver == nil else { return }

        // The hardware changing underneath an AVAudioEngine tears its graph
        // down. Rebuilding turns "the audition went silent and nobody said why"
        // into "the audition kept working at the new device's rate". The patch
        // survives because the voice is rebuilt from the live channel, which is
        // where the owner's edits actually live.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }

        // Anything held before the switch cannot be held after it: the voice
        // those keys are down on is about to be freed.
        heldNotes.removeAll()

        buildGraph()
        avEngine.prepare()
        do {
            try avEngine.start()
            failureDescription = nil
        } catch {
            isRunning = false
            failureDescription = AuditionError
                .couldNotStart(reason: (error as NSError).localizedDescription)
                .description
        }
    }
}
