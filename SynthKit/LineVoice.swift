import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// A sound that can render one line of a performance.
///
/// **This is the surface increment 003's synthesizer and increment 005's
/// sampled instruments implement.** Increment 002 ships one implementation,
/// `DefaultSynthVoiceProvider`, so playback is audible before the real synth
/// exists (AD7). Nothing else in the engine changes when that voice is
/// replaced.
///
/// The split is deliberate. A provider is an ordinary Swift value used on the
/// control thread: it decides what a sound *is*, and allocates whatever that
/// sound needs. What it hands back is a `LineVoiceInstance` wrapping a C
/// vtable (`SynthLineVoice`), and that vtable is all the render thread ever
/// touches. A Swift protocol cannot be called from the audio thread without
/// risking ARC traffic on the witness, so the boundary is drawn here rather
/// than left to the implementor's discipline.
///
/// An implementor's obligations are stated on `SynthLineVoice` in
/// `SynthAudioCore.h`; the two that matter most are that no callback may
/// allocate or lock, and that `render` overwrites its buffer without applying
/// any level of its own — gain, pan, mute and solo belong to the engine.
public protocol LineVoiceProvider: Sendable {
    /// Stable identity for this sound, so a preset in increment 004 can name it.
    var identifier: String { get }

    /// Human-readable name for a mixer strip or a preset picker.
    var displayName: String { get }

    /// Build one voice. Called once per line, on the control thread, before
    /// rendering starts. Allocate everything the voice will ever need here.
    func makeVoice(sampleRate: Double) -> LineVoiceInstance
}

/// One line's voice: the C vtable the render thread calls, plus the control-
/// thread teardown that releases whatever backs it.
///
/// `release` is called exactly once, after the engine holding this voice has
/// stopped and been destroyed. Holding it as a closure keeps `LineVoiceInstance`
/// agnostic about how a provider chose to allocate its state — a C struct, a
/// Swift buffer, or a memory-mapped sample set in increment 005.
public struct LineVoiceInstance: @unchecked Sendable {
    public let vtable: SynthLineVoice
    public let release: @Sendable () -> Void

    public init(vtable: SynthLineVoice, release: @escaping @Sendable () -> Void) {
        self.vtable = vtable
        self.release = release
    }
}

/// The built-in fixed voice (AD7).
///
/// Three sine partials through a linear ADSR, with the sustain pedal holding
/// released notes. It is intentionally not configurable: it exists so that this
/// increment can prove the engine plays a score, and increment 003 deletes it
/// from the default path by supplying a real synthesizer through the same
/// interface.
public struct DefaultSynthVoiceProvider: LineVoiceProvider {
    public init() {}

    public var identifier: String { "builtin.default-synth" }
    public var displayName: String { "Built-in Voice" }

    public func makeVoice(sampleRate: Double) -> LineVoiceInstance {
        // Sized by the C core so the layout stays private to it.
        let byteCount = synth_default_voice_state_size()
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Int64>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        // `SynthDefaultVoiceState` is incomplete in the public header on
        // purpose — its layout is the render core's business — so it crosses
        // into Swift as an opaque pointer.
        var vtable = SynthLineVoice()
        synth_default_voice_init(OpaquePointer(raw), &vtable, sampleRate)

        // The pointer crosses into the teardown closure as an integer because a
        // raw pointer is not `Sendable`. Ownership is unambiguous — this voice
        // is the only thing that ever holds it, and `release` runs exactly once
        // after the engine using it has been destroyed.
        let address = UInt(bitPattern: raw)
        return LineVoiceInstance(vtable: vtable, release: {
            UnsafeMutableRawPointer(bitPattern: address)?.deallocate()
        })
    }
}
