import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Renders one line with one downloaded instrument.
///
/// The sampler's implementation of PLY003's line-voice interface, and the
/// second one to exist: `SynthPatchVoiceProvider` is the synthesizer's. The
/// engine, the transport, the mixer, the offline render path and export are
/// identical for both, and the only difference is which vtable a line gets —
/// which is the property AD6 and PLY003 were drawn to give this leaf, and the
/// reason nothing in `PlaybackEngine`, `RenderProgram` or the preset code needed
/// to learn what a sample is.
///
/// **The instrument is shared and the voice is not.** A provider holds one
/// `SampledInstrument` — the parsed regions and the sample mappings — and every
/// voice it makes reads that same table. Two violin lines therefore cost one
/// copy of the samples and two small voice states, which is what makes an
/// 18-line orchestral score affordable at all.
public struct SampledInstrumentVoiceProvider: LineVoiceProvider {
    /// The loaded instrument. Held so it outlives every voice over it: a voice
    /// reads its region table and its sample mappings directly, and both go
    /// when the last reference does.
    public let instrument: SampledInstrument

    /// How the owner asked for this instrument to be played (INS003, REQ-021).
    ///
    /// Already bounded by `InstrumentCapabilities.bounded` at every call site
    /// that builds one from a stored variant, so a control the instrument
    /// cannot honestly support is neutral here rather than merely greyed out in
    /// the editor.
    public let customization: InstrumentCustomization

    /// The channel that pushes a later edit of this customization into the
    /// voices already rendering, or nil for a fixed provider.
    ///
    /// **The sampler's half of REQ-018.** A provider with no channel is what an
    /// offline render wants: a frozen sound that cannot change under it. A
    /// provider with one is what the app wants while a piece plays, because
    /// moving a tone control then reaches the notes that are already sounding
    /// rather than waiting for the program to be rebuilt — and rebuilding the
    /// program stops the music.
    public let live: SampledInstrumentLiveVoices?

    /// Seeds this provider's round-robin and random region selection.
    ///
    /// **This is what makes a sampler deterministic** (REQ-012, REQ-026, and
    /// AD5's "determinism by construction"). A library that varies repeated
    /// notes has to choose, and a choice made from an unseeded generator would
    /// make two offline renders of the same piece differ — quietly, and only
    /// on the notes that repeat. The seed travels with the provider, the voice
    /// returns to it on `reset`, and the engine delivers note-ons in timeline
    /// order, so the sequence of choices is a function of the music and this
    /// number alone.
    public let renderSeed: UInt64

    /// Load the instrument and build a provider for it.
    ///
    /// - Parameters:
    ///   - available: what INS001's asset store says is installed.
    ///   - articulation: one of `available`'s alternate SFZ files, or nil for
    ///     its entry point. Choosing between them is INS003's surface; this
    ///     parameter is how it will reach in.
    ///   - renderSeed: defaults to a value derived from the instrument's
    ///     identity, so the same instrument always varies the same way. Pass a
    ///     piece's own realization seed to make two pieces differ.
    public init(
        available: AvailableInstrument,
        articulation: URL? = nil,
        renderSeed: UInt64? = nil,
        customization: InstrumentCustomization = .asRecorded,
        live: SampledInstrumentLiveVoices? = nil
    ) throws {
        let loaded = try SampledInstrument(available, sfzURL: articulation)
        self.init(
            instrument: loaded,
            renderSeed: renderSeed,
            customization: customization,
            live: live
        )
    }

    /// Build a provider over an instrument that is already loaded, so several
    /// lines can share one copy of the samples.
    public init(
        instrument: SampledInstrument,
        renderSeed: UInt64? = nil,
        customization: InstrumentCustomization = .asRecorded,
        live: SampledInstrumentLiveVoices? = nil
    ) {
        self.instrument = instrument
        self.renderSeed = renderSeed
            ?? SampledInstrumentVoiceProvider.seed(forIdentifier: Self.identifier(of: instrument))
        self.customization = customization
        self.live = live
    }

    /// This instrument's capability set, measured from the files it loaded.
    public var capabilities: InstrumentCapabilities {
        InstrumentCapabilities(
            features: instrument.features,
            coverage: instrument.source.coverage,
            alternateArticulationCount: instrument.source.alternateSFZURLs.count
        )
    }

    public var identifier: String { Self.identifier(of: instrument) }

    public var displayName: String { instrument.source.coverage.name }

    /// The attribution this instrument's licence obliges the app to show
    /// wherever it plays. Empty for CC0.
    public var requiredAttribution: String { instrument.source.requiredAttribution }

    /// What this instrument can actually do, measured from the files on disk.
    public var features: SampledInstrumentFeatures { instrument.features }

    /// Lines whose voice could not be built and which are therefore silent.
    ///
    /// Zero in every normal run. INS003 reads it to flag a line that is playing
    /// nothing, rather than the owner discovering it by listening.
    public var unbuiltVoiceCount: Int { instrument.unbuiltVoiceCount }

    /// How long this instrument can still be heard after its last note ends,
    /// with the owner's release scale applied.
    ///
    /// **The scale has to be in here or an export truncates.**
    /// `RenderProgram` renders this far past the final event and then stops, so
    /// a variant that quadrupled a cello's release and a tail figure that did
    /// not know about it would cut the last note of the piece off in the
    /// exported file while sounding complete in live playback.
    public var releaseTailSeconds: Double {
        let scaled = instrument.features.releaseTailSeconds * customization.releaseScale
        return min(max(scaled, 0), RenderProgram.maximumReleaseTailSeconds)
    }

    public func makeVoice(sampleRate: Double) -> LineVoiceInstance {
        var vtable = SynthLineVoice()
        let state = sample_voice_create(
            instrument.renderData, &vtable, sampleRate, renderSeed
        )

        guard let state else {
            // `sample_voice_create` has already filled `vtable` with the voice
            // that renders silence, so the engine has something callable.
            //
            // **The line goes quiet rather than becoming a synthesizer.** A
            // substitute sound would be the more pleasant failure and the wrong
            // one: #24 requires a line to be flagged and substituted only with
            // the owner's explicit acknowledgment, and quietly playing a patch
            // where a cello was assigned reaches that same prohibited end state
            // by another route. Recording it is what gives INS003 something to
            // flag; #23's own failure behaviour for a vanished asset —
            // "silence-with-flag, never a crash" — is the same answer.
            instrument.recordVoiceAllocationFailure()
            return LineVoiceInstance(vtable: vtable, didFailToBuild: true, release: {})
        }

        // The customization the voice starts on. Taken from the live channel
        // rather than from `customization` when there is one, so a voice built
        // *after* an edit — a device switch rebuilds the program — comes back
        // playing the edited sound rather than the one this provider was
        // constructed with. `SynthPatchLiveVoices.currentPatch` exists for
        // exactly the same reason.
        var current = (live?.currentCustomization ?? customization).renderCustomization
        sample_voice_set_customization(state, &current)
        live?.register(state: UnsafeMutableRawPointer(state), sampleRate: sampleRate)

        // The instrument is captured so the mappings the render thread reads
        // cannot be unmapped while a voice is still over them, whatever else
        // the caller does with its own reference. The pointer travels as an
        // integer because a raw pointer is not `Sendable` — the same crossing
        // `SynthPatchVoiceProvider` makes, for the same reason.
        let held = instrument
        let channel = live
        let address = UInt(bitPattern: UnsafeMutableRawPointer(state))
        return LineVoiceInstance(vtable: vtable, release: {
            withExtendedLifetime(held) {
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                // Deregistered before the storage goes, inside the channel's
                // own lock, so a publish racing this release cannot reach freed
                // memory.
                channel?.unregister(state: pointer)
                sample_voice_destroy(OpaquePointer(pointer))
            }
        })
    }

    /// Stable identity for a preset to name, once INS003 gives instruments a
    /// place in the sound library.
    ///
    /// Includes the SFZ file rather than only the instrument, because two
    /// articulations of one violin are two different sounds to assign.
    static func identifier(of instrument: SampledInstrument) -> String {
        let coverage = instrument.source.coverage
        return "instrument:\(instrument.source.libraryID)/\(coverage.identifier)"
            + "/\(instrument.sfzURL.lastPathComponent)"
    }

    /// FNV-1a of the identifier.
    ///
    /// The same choice `SeededJitter` makes and for the same reason: Swift's
    /// `Hasher` is seeded per process, so a seed derived from it would give a
    /// different performance on every launch — which is exactly the bug this
    /// seed exists to prevent.
    static func seed(forIdentifier identifier: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
