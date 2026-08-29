import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// Every downloaded instrument, loaded on demand and shared between the lines
/// that use it.
///
/// **The sharing is the point.** The orchestral reference has eighteen lines
/// and several of them are the same section; loading a `SampledInstrument` per
/// line would map the same 40 MB of violin samples four times and fault in four
/// copies of their attacks. This keeps one per SFZ file, so assigning the same
/// instrument to a second line costs a voice state and nothing else.
///
/// It is also where a load failure becomes something the owner can read. An
/// instrument whose files were deleted or corrupted since INS001 installed them
/// is reported by name with a reason and a suggestion, and the rest of the
/// library still plays — the failure behaviour issue #23 asks for, and the same
/// honesty principle REQ-014 applies to notation.
public final class SampledInstrumentLibrary: @unchecked Sendable {
    private let store: InstrumentAssetStore
    private let lock = NSLock()
    private var loaded: [String: SampledInstrument] = [:]

    public init(store: InstrumentAssetStore) {
        self.store = store
    }

    /// One instrument's load result: the provider, or why there is none.
    public struct Entry: Sendable {
        public let available: AvailableInstrument

        /// The provider to assign to a line, or nil when the instrument could
        /// not be loaded.
        public let provider: SampledInstrumentVoiceProvider?

        /// Why it could not be loaded, in language that can be shown.
        public let unavailableReason: String?

        /// What the owner should do about it — always INS001's re-download
        /// path, because the bytes on disk are the only thing that can be
        /// wrong.
        public let recoverySuggestion: String?

        public var isPlayable: Bool { provider != nil }
    }

    /// Every installed instrument, loaded.
    ///
    /// Loads each instrument's entry-point SFZ. Alternate articulations are
    /// loaded on request through `provider(for:articulation:)`, because loading
    /// all five of a keyswitched flute's files to show one instrument in a list
    /// would map five times the samples for no benefit.
    public func entries() throws -> [Entry] {
        try store.availableInstruments().map { entry(for: $0, articulation: nil) }
    }

    /// The provider for one instrument, loading it if this is the first ask.
    ///
    /// `customization` is bounded to what the loaded files genuinely support
    /// before it reaches the render core (REQ-021), so a control the instrument
    /// cannot honestly offer has no effect here even when a stored variant asks
    /// for one.
    public func provider(
        for available: AvailableInstrument,
        articulation: URL? = nil,
        renderSeed: UInt64? = nil,
        customization: InstrumentCustomization = .asRecorded,
        live: SampledInstrumentLiveVoices? = nil
    ) throws -> SampledInstrumentVoiceProvider {
        let instrument = try instrument(for: available, articulation: articulation)
        let capabilities = InstrumentCapabilities(
            features: instrument.features,
            coverage: available.coverage,
            alternateArticulationCount: available.alternateSFZURLs.count
        )
        return SampledInstrumentVoiceProvider(
            instrument: instrument,
            renderSeed: renderSeed,
            customization: capabilities.bounded(customization),
            live: live
        )
    }

    /// What one installed instrument can be customized with, measured from the
    /// files on disk.
    ///
    /// Loads the instrument if it is not already loaded, because the answer is
    /// a measurement of its regions rather than a claim from the catalog — which
    /// is exactly the invariant issue #24 states: capability gating comes from
    /// asset facts, never from a per-library switch.
    public func capabilities(
        for available: AvailableInstrument, articulation: URL? = nil
    ) throws -> InstrumentCapabilities {
        let instrument = try instrument(for: available, articulation: articulation)
        return InstrumentCapabilities(
            features: instrument.features,
            coverage: available.coverage,
            alternateArticulationCount: available.alternateSFZURLs.count
        )
    }

    /// The loaded instrument behind one SFZ file, shared across callers.
    public func instrument(
        for available: AvailableInstrument, articulation: URL? = nil
    ) throws -> SampledInstrument {
        let url = articulation ?? available.sfzURL
        let key = url.path(percentEncoded: false)

        lock.lock()
        let cached = loaded[key]
        lock.unlock()
        if let cached { return cached }

        // Loaded outside the lock: parsing an SFZ and mapping several hundred
        // WAV files takes long enough that holding a lock across it would stall
        // every other line's load. Two threads racing the same instrument may
        // both build one; the second one built is dropped, which costs a
        // redundant load and never a wrong result.
        let built = try SampledInstrument(available, sfzURL: url)

        lock.lock()
        defer { lock.unlock() }
        if let winner = loaded[key] { return winner }
        loaded[key] = built
        return built
    }

    /// Drop every loaded instrument, releasing its mappings.
    ///
    /// For a library that was re-downloaded underneath a running app: the
    /// mappings still point at the old inodes, and nothing else would notice.
    public func unloadAll() {
        lock.lock()
        loaded.removeAll()
        lock.unlock()
    }

    /// Bytes currently mapped and currently resident across everything loaded.
    ///
    /// The number REQ-013's memory claim is made from. `resident` is the figure
    /// that competes for RAM; `mapped` is address space, most of which is never
    /// touched.
    public func memoryFootprint() -> (mapped: Int64, resident: Int64) {
        lock.lock()
        let instruments = Array(loaded.values)
        lock.unlock()
        return (
            instruments.reduce(0) { $0 + $1.features.mappedByteCount },
            instruments.reduce(0) { $0 + $1.features.residentByteCount }
        )
    }

    private func entry(for available: AvailableInstrument, articulation: URL?) -> Entry {
        do {
            let loaded = try instrument(for: available, articulation: articulation)
            return Entry(
                available: available,
                provider: SampledInstrumentVoiceProvider(instrument: loaded),
                unavailableReason: nil,
                recoverySuggestion: nil
            )
        } catch let error as SampledInstrument.LoadError {
            return Entry(
                available: available,
                provider: nil,
                unavailableReason: error.description,
                recoverySuggestion: error.recoverySuggestion
            )
        } catch {
            return Entry(
                available: available,
                provider: nil,
                unavailableReason: "\(available.coverage.name) cannot be played: \(error)",
                recoverySuggestion:
                    "Re-download the library from the instrument catalog to replace the files "
                    + "on disk."
            )
        }
    }
}
