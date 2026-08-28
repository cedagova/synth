import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// A sound that can render one line of a performance.
///
/// **This is the surface the synthesizer implements, and increment 005's
/// sampled instruments will implement next.** Increment 002 shipped a fixed
/// built-in voice here so playback was audible before the synth existed; AD7
/// says increment 003 replaces it, and `SynthPatchVoiceProvider` is that
/// replacement. Nothing else in the engine changed when it did — which was the
/// point of drawing the boundary here.
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
