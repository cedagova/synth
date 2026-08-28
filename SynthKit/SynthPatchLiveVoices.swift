import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// The control thread's end of live editing: one patch, and every rendering
/// voice currently built from it.
///
/// **This is what makes REQ-018 possible without stopping the music.** SYN001
/// drew the boundary at "changing a sound means building a new voice", which is
/// correct for choosing a sound and wrong for editing one — building a voice
/// means rebuilding the render program, and rebuilding the render program means
/// playback stops. So a voice gained a parameter-update path
/// (`synth_patch_voice_publish`), and this is the object that owns it.
///
/// What it holds is deliberately small: the current patch, and the addresses of
/// the voice states built from it. Everything else — sanitising, working out
/// coefficients, publishing without tearing — is the render core's.
///
/// **Threading.** Every method here is control-thread work and every one of
/// them takes the same lock. That lock is never touched by the render thread:
/// what crosses to the audio side is one atomic exchange per voice, inside
/// `synth_patch_voice_publish`. The lock exists for a different race — a voice
/// being released (a `RenderProgram` deinit, which can land on any thread)
/// while an edit is being pushed into it — and serialising registration,
/// release and publication against each other is what stops a publish reaching
/// freed storage.
public final class SynthPatchLiveVoices: @unchecked Sendable {
    /// What happened to one `apply`.
    ///
    /// A refusal is not a failure of the edit — the patch is still the
    /// library's and still this channel's — it means one voice belongs to a
    /// graph that has since been rebuilt at another sample rate and must be
    /// replaced rather than updated. Reported rather than swallowed, so a
    /// caller can rebuild instead of silently going out of sync with what is
    /// being heard.
    public struct Result: Equatable, Sendable {
        /// Voices the patch was staged into.
        public let accepted: Int
        /// Voices that refused it because their sample rate no longer matches.
        public let refused: Int

        public var isComplete: Bool { refused == 0 }
        public var reachedAnyVoice: Bool { accepted > 0 }
    }

    private let lock = NSLock()
    private var patch: SynthPatch
    /// Voice state address → the rate that voice was prepared at.
    private var voices: [UInt: Double] = [:]

    public init(patch: SynthPatch = .defaultVoice) {
        self.patch = patch
    }

    /// The sound every voice on this channel is currently rendering.
    ///
    /// Read when a voice is *built*, not only when one is updated, so a graph
    /// rebuilt for a device change comes back playing the edited sound rather
    /// than the one the provider was constructed with. That is the difference
    /// between an edit surviving a device switch and an edit being silently
    /// undone by one.
    public var currentPatch: SynthPatch {
        lock.lock()
        defer { lock.unlock() }
        return patch
    }

    /// How many voices this channel is currently driving.
    public var voiceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return voices.count
    }

    /// Make `patch` the sound, and push it into every voice already rendering.
    ///
    /// Returns without waiting for anything. Each voice takes the new patch up
    /// at its next render block — within one buffer — and keeps its notes,
    /// phases and effect tails while it does.
    @discardableResult
    public func apply(_ patch: SynthPatch) -> Result {
        lock.lock()
        defer { lock.unlock() }

        self.patch = patch
        return publishLocked(patch)
    }

    /// The smallest number of published patches any one voice has taken up.
    ///
    /// The *smallest*, so this answers "has the edit reached every voice that
    /// is playing" rather than "did some voice somewhere notice". Zero when
    /// there are no voices at all.
    public var adoptionsTakenUp: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !voices.isEmpty else { return 0 }
        return voices.keys.reduce(Int64.max) { lowest, address in
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return lowest }
            return min(lowest, synth_patch_voice_adoptions(OpaquePointer(pointer)))
        }
    }

    // MARK: Voice registration

    /// A voice built from this channel. Called by `SynthPatchVoiceProvider`.
    func register(state: UnsafeMutableRawPointer, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        voices[UInt(bitPattern: state)] = sampleRate
    }

    /// The voice's storage is about to be freed.
    func unregister(state: UnsafeMutableRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        voices.removeValue(forKey: UInt(bitPattern: state))
    }

    // MARK: Test notes

    /// Play, release, hold or silence a note on every voice on this channel.
    ///
    /// The editor's on-screen keyboard, and nothing else: a piece's notes come
    /// from its timeline through the render engine. Returns false when a queue
    /// was full, which a caller should report — a note-off that never arrives
    /// is a note that never stops.
    /// How many events have been posted through this channel.
    ///
    /// The counterpart to `adoptionsTakenUp`, and for the same reason: it lets
    /// a caller prove that one key press produced exactly one note-on rather
    /// than assume it. An on-screen key has two activation paths, and "the
    /// note sounded" is not the same claim as "the note sounded once".
    public var postedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }

    private var posted = 0

    @discardableResult
    public func post(_ event: LiveEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        posted += 1
        var delivered = true
        for address in voices.keys {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { continue }
            let accepted = synth_patch_voice_post_event(
                OpaquePointer(pointer), event.kind, event.note, event.velocity
            )
            if accepted == 0 { delivered = false }
        }
        return delivered
    }

    /// One thing to do to a sounding voice.
    public enum LiveEvent: Equatable, Sendable {
        /// MIDI note number and 1…127 velocity.
        case noteOn(note: Int, velocity: Int)
        case noteOff(note: Int)
        case sustainPedal(isDown: Bool)
        /// Release everything. What closing the editor does.
        case allNotesOff

        var kind: Int32 {
            switch self {
            case .noteOn: return synth_patch_live_event_note_on()
            case .noteOff: return synth_patch_live_event_note_off()
            case .sustainPedal: return synth_patch_live_event_pedal()
            case .allNotesOff: return synth_patch_live_event_all_off()
            }
        }

        var note: Int32 {
            switch self {
            case .noteOn(let note, _), .noteOff(let note): return Int32(note)
            case .sustainPedal, .allNotesOff: return 0
            }
        }

        var velocity: Int32 {
            switch self {
            case .noteOn(_, let velocity): return Int32(velocity)
            case .sustainPedal(let isDown): return isDown ? 1 : 0
            case .noteOff, .allNotesOff: return 0
            }
        }
    }

    // MARK: Internals

    private func publishLocked(_ patch: SynthPatch) -> Result {
        var configuration = patch.renderConfiguration
        var accepted = 0
        var refused = 0

        for (address, sampleRate) in voices {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { continue }
            let staged = synth_patch_voice_publish(
                OpaquePointer(pointer), &configuration, sampleRate
            )
            if staged != 0 { accepted += 1 } else { refused += 1 }
        }

        return Result(accepted: accepted, refused: refused)
    }
}
