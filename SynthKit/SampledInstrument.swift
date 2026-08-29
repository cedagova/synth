import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// One downloaded instrument, loaded and ready to render.
///
/// This is the control-thread object the render core's `SampleInstrumentData`
/// points into: it owns the region table, the key index and every sample
/// mapping, and it must outlive every voice built over it. Loading it is the
/// expensive part of assigning an instrument to a line — parsing the SFZ,
/// opening a few hundred WAV files, faulting in their attacks — and it happens
/// once per instrument rather than once per line, because
/// `SampledInstrumentLibrary` shares one of these between every line using it.
///
/// **Nothing here is persisted.** A parsed instrument is derived from files the
/// catalog already pins, so caching it in the database would create a second
/// source of truth that could disagree with the bytes on disk. Issue #23 says
/// so explicitly, and it is why this leaf adds no schema version.
public final class SampledInstrument: @unchecked Sendable {
    /// What the owner is playing, as INS001 recorded it.
    public let source: AvailableInstrument

    /// Which of the instrument's SFZ files this is: the entry point, or one of
    /// its alternate articulations.
    public let sfzURL: URL

    /// What this instrument can and cannot do, for INS003's capability gating
    /// and for the owner-facing honesty report.
    public let features: SampledInstrumentFeatures

    /// The flat tables the render core reads. Stable for this object's
    /// lifetime; never mutated after `init` returns.
    private let regionStorage: UnsafeMutableBufferPointer<SampleRegionData>
    private let waveformStorage: UnsafeMutableBufferPointer<SampleWaveformData>
    private let keyRegionStorage: UnsafeMutableBufferPointer<Int32>
    private let keyStartStorage: UnsafeMutableBufferPointer<Int32>
    private let instrumentStorage: UnsafeMutablePointer<SampleInstrumentData>

    /// The mappings, held so they are not unmapped while a voice is reading
    /// them.
    private let waveforms: [SampleWaveform]

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        /// The SFZ file itself could not be read.
        case definitionUnreadable(instrument: String, reason: String)

        /// The SFZ parsed, but nothing in it can be played — every sample was
        /// missing or unreadable, or it declared no regions at all.
        case noPlayableSamples(instrument: String, reason: String)

        public var description: String {
            switch self {
            case .definitionUnreadable(let instrument, let reason):
                return "\(instrument) cannot be played: \(reason)"
            case .noPlayableSamples(let instrument, let reason):
                return "\(instrument) cannot be played: \(reason)"
            }
        }

        /// What the owner should do about it. Both cases have the same answer,
        /// and it is INS001's: the bytes on disk are wrong, so fetch them again.
        public var recoverySuggestion: String {
            "Re-download the library from the instrument catalog to replace the files on disk."
        }
    }

    /// Load `instrument`'s primary SFZ, or one of its alternate articulations.
    ///
    /// A sample that is missing or unreadable does not fail the load: its
    /// region is dropped, the reason is recorded in
    /// `features.unplayableSamples`, and the rest of the instrument plays. Only
    /// an instrument with nothing left to play fails — which is the difference
    /// between "one articulation of your violin is incomplete" and "your violin
    /// is gone", and the owner is owed both answers accurately.
    public init(_ instrument: AvailableInstrument, sfzURL: URL? = nil) throws {
        let url = sfzURL ?? instrument.sfzURL
        self.source = instrument
        self.sfzURL = url

        let name = instrument.coverage.name

        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
              let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1)
        else {
            throw LoadError.definitionUnreadable(
                instrument: name,
                reason: "its definition file \(url.lastPathComponent) could not be read."
            )
        }

        let document = SFZDocument.parse(text)
        guard !document.regions.isEmpty else {
            throw LoadError.noPlayableSamples(
                instrument: name,
                reason: "\(url.lastPathComponent) declares no playable regions."
            )
        }

        // Sample paths are relative to the SFZ file's own directory, not to the
        // library root: an alternate articulation in a subfolder resolves
        // against its own folder, which is what `default_path` is relative to
        // as well.
        let root = url.deletingLastPathComponent()

        var loaded: [String: Int] = [:]
        var mappings: [SampleWaveform] = []
        var regions: [SampleRegionData] = []
        var unplayable: [SampledInstrumentFeatures.UnplayableSample] = []
        var seenFailures: Set<String> = []

        for region in document.regions {
            // A region outside the MIDI range cannot be reached by a note. The
            // curated set uses `lokey=-1` for Salamander's pedal-action layers,
            // which are started by a pedal position rather than a key.
            guard region.hiKey >= 0, region.loKey <= 127, region.hiKey >= region.loKey else {
                continue
            }

            let index: Int
            if let existing = loaded[region.samplePath] {
                index = existing
            } else if seenFailures.contains(region.samplePath) {
                continue
            } else {
                // A `sample` path must stay inside the library INS001
                // installed. The curated files are pinned by digest, so this is
                // not a live threat today; it is here because an SFZ file is
                // third-party text that names files to open, and `../..` in one
                // must never become a read outside the library — a property
                // worth holding by construction rather than by the catalog
                // continuing to be trustworthy.
                guard let sampleURL = Self.resolve(
                    region.samplePath, under: root, notEscaping: instrument.libraryRootURL
                ) else {
                    seenFailures.insert(region.samplePath)
                    unplayable.append(
                        SampledInstrumentFeatures.UnplayableSample(
                            path: region.samplePath,
                            reason: "it points outside the installed library."
                        )
                    )
                    continue
                }

                do {
                    let waveform = try SampleWaveform(contentsOf: sampleURL)
                    index = mappings.count
                    mappings.append(waveform)
                    loaded[region.samplePath] = index
                } catch {
                    seenFailures.insert(region.samplePath)
                    // `SampleWaveform.LoadFailure` already reads as a sentence
                    // naming the file and the reason; anything else falls back
                    // to its own description rather than to a type name.
                    let reason = (error as? SampleWaveform.LoadFailure)?.description
                        ?? (error as NSError).localizedDescription
                    unplayable.append(
                        SampledInstrumentFeatures.UnplayableSample(
                            path: region.samplePath, reason: reason
                        )
                    )
                    continue
                }
            }

            regions.append(region.renderData(waveformIndex: Int32(index)))
        }

        guard !regions.isEmpty, !mappings.isEmpty else {
            let detail = unplayable.isEmpty
                ? "none of its regions map to a playable key."
                : "none of its \(unplayable.count) sample files could be read "
                    + "(\(unplayable[0].reason))."
            throw LoadError.noPlayableSamples(instrument: name, reason: detail)
        }

        // Fault in every sample's attack before the first note can ask for it.
        // This is the whole real-time-safety story for a memory-mapped sampler,
        // and it belongs on this thread rather than the audio one.
        var residentBytes = 0
        var mappedBytes = 0
        for waveform in mappings {
            residentBytes += waveform.prewarmAttack()
            mappedBytes += waveform.mappedByteCount
        }

        // MARK: Tables

        self.waveforms = mappings
        self.waveformStorage = .allocate(capacity: mappings.count)
        for (index, waveform) in mappings.enumerated() {
            waveformStorage[index] = waveform.renderData
        }

        self.regionStorage = .allocate(capacity: regions.count)
        for (index, region) in regions.enumerated() { regionStorage[index] = region }

        // The per-key index: every region reachable from a key, gathered so a
        // note-on scans a handful of entries instead of all 641 of Salamander's.
        var buckets: [[Int32]] = Array(repeating: [], count: SampledInstrument.keyCount)
        for (index, region) in regions.enumerated() {
            let low = max(0, Int(region.loKey))
            let high = min(SampledInstrument.keyCount - 1, Int(region.hiKey))
            guard low <= high else { continue }
            for key in low...high { buckets[key].append(Int32(index)) }
        }

        let flattened = buckets.flatMap { $0 }
        self.keyRegionStorage = .allocate(capacity: max(1, flattened.count))
        for (index, value) in flattened.enumerated() { keyRegionStorage[index] = value }

        self.keyStartStorage = .allocate(capacity: SampledInstrument.keyCount + 1)
        var running: Int32 = 0
        for key in 0..<SampledInstrument.keyCount {
            keyStartStorage[key] = running
            running += Int32(buckets[key].count)
        }
        keyStartStorage[SampledInstrument.keyCount] = running

        self.instrumentStorage = .allocate(capacity: 1)
        instrumentStorage.pointee = SampleInstrumentData(
            waveforms: UnsafePointer(waveformStorage.baseAddress!),
            waveformCount: Int32(mappings.count),
            regions: UnsafePointer(regionStorage.baseAddress!),
            regionCount: Int32(regions.count),
            keyRegions: UnsafePointer(keyRegionStorage.baseAddress!),
            keyRegionStart: UnsafePointer(keyStartStorage.baseAddress!),
            defaultSwitchKey: Int32(document.defaultSwitchKey ?? -1),
            switchLowKey: Int32(document.switchKeyRange?.lowerBound ?? -1),
            switchHighKey: Int32(document.switchKeyRange?.upperBound ?? -1)
        )

        self.features = SampledInstrumentFeatures(
            document: document,
            regions: regions,
            waveforms: mappings,
            unplayableSamples: unplayable,
            mappedByteCount: Int64(mappedBytes),
            residentByteCount: Int64(residentBytes)
        )
    }

    deinit {
        instrumentStorage.deallocate()
        keyStartStorage.deallocate()
        keyRegionStorage.deallocate()
        regionStorage.deallocate()
        waveformStorage.deallocate()
    }

    /// Lines this instrument could not build a voice for, and which are
    /// therefore rendering silence.
    ///
    /// **Zero in every normal run, and it has to stay readable when it is not.**
    /// A voice is one small allocation, so this only moves under real memory
    /// exhaustion — but when it does, the owner assigned a cello and is hearing
    /// nothing, and the app must be able to say so. INS003 (#24) owns the flag
    /// and the acknowledgment; this leaf owes it the fact.
    ///
    /// The alternative — quietly substituting a synth patch — was rejected: it
    /// is the same prohibited end state #24 is being built to gate behind an
    /// explicit acknowledgment, reached by another route.
    public var unbuiltVoiceCount: Int {
        failureLock.lock()
        defer { failureLock.unlock() }
        return voiceAllocationFailures
    }

    private let failureLock = NSLock()
    private var voiceAllocationFailures = 0

    /// Called by the provider when `sample_voice_create` could not allocate.
    func recordVoiceAllocationFailure() {
        failureLock.lock()
        voiceAllocationFailures += 1
        failureLock.unlock()
    }

    static let keyCount = Int(SAMPLE_VOICE_KEY_COUNT)

    /// `path` joined to `directory`, or nil when the result leaves `boundary`.
    ///
    /// Compared on the standardized paths, so `..` is resolved before the
    /// containment test rather than after it, and with a trailing separator on
    /// the boundary so a sibling directory whose name merely starts with the
    /// library's does not pass.
    static func resolve(_ path: String, under directory: URL, notEscaping boundary: URL) -> URL? {
        let candidate = directory.appending(path: path).standardizedFileURL
        var root = boundary.standardizedFileURL.path(percentEncoded: false)
        if !root.hasSuffix("/") { root += "/" }
        return candidate.path(percentEncoded: false).hasPrefix(root) ? candidate : nil
    }

    /// The table pointer a voice is built over. Valid while this object lives.
    var renderData: UnsafePointer<SampleInstrumentData> { UnsafePointer(instrumentStorage) }
}

// MARK: - Region conversion

extension SFZRegion {
    /// This region as the flat struct the render core reads.
    ///
    /// The conversion is where SFZ's units become the engine's: decibels become
    /// a linear gain, percentages become fractions, and `loop_mode`'s absence
    /// becomes -1 for "let the sample file's own loop points decide", which is
    /// what SFZ 1.0 specifies.
    func renderData(waveformIndex: Int32) -> SampleRegionData {
        let trigger: Int32
        switch self.trigger {
        case .attack: trigger = Int32(SampleRegionTriggerAttack.rawValue)
        case .release: trigger = Int32(SampleRegionTriggerRelease.rawValue)
        case .first, .legato: trigger = Int32(SampleRegionTriggerOther.rawValue)
        }

        let loop: Int32
        switch loopMode {
        case .none: loop = -1
        case .noLoop: loop = Int32(SampleLoopModeNone.rawValue)
        case .oneShot: loop = Int32(SampleLoopModeOneShot.rawValue)
        case .loopContinuous: loop = Int32(SampleLoopModeContinuous.rawValue)
        case .loopSustain: loop = Int32(SampleLoopModeSustain.rawValue)
        }

        return SampleRegionData(
            waveformIndex: waveformIndex,
            loKey: Int32(loKey),
            hiKey: Int32(hiKey),
            loVelocity: Int32(loVelocity),
            hiVelocity: Int32(hiVelocity),
            pitchKeycenter: Int32(pitchKeycenter),
            tuneSemitones: Float(tuneSemitones),
            pitchKeytrack: Float(pitchKeytrack),
            gainLinear: Float(pow(10.0, volumeDecibels / 20.0)),
            ampVelocityTracking: Float(amplitudeVelocityTracking),
            attackSeconds: Float(attackSeconds),
            decaySeconds: Float(decaySeconds),
            sustainLevel: Float(sustainLevel),
            releaseSeconds: Float(releaseSeconds),
            trigger: trigger,
            releaseTriggerDecayDBPerSecond: Float(releaseTriggerDecayDecibelsPerSecond),
            loopMode: loop,
            loopStart: loopStart ?? -1,
            loopEnd: loopEnd ?? -1,
            sampleOffset: sampleOffset,
            sampleEnd: sampleEnd ?? -1,
            sequenceLength: Int32(sequenceLength),
            sequencePosition: Int32(sequencePosition),
            randomLow: Float(randomLow),
            randomHigh: Float(randomHigh),
            switchKey: Int32(switchKey ?? -1)
        )
    }
}

// MARK: - Features

/// What a loaded instrument actually offers, and what it does not.
///
/// **This is the surface INS003 gates its customization controls on.** REQ-021
/// says a control that cannot do anything must degrade visibly rather than
/// pretend, and "cannot do anything" is a question about the samples: an
/// instrument with one velocity layer has no sampled dynamics to shape, and one
/// with no round robins cannot vary repeated notes however the control is set.
/// INS001's `dynamicLayerCount` and `qualityNotes` are the catalog's editorial
/// answer to the same question; this is the measured one, taken from the files
/// the owner actually has.
public struct SampledInstrumentFeatures: Sendable, Equatable {
    /// A sample the instrument names but cannot play, and why.
    public struct UnplayableSample: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Playable regions after unreadable samples were dropped.
    public let regionCount: Int

    /// Distinct sample files the instrument maps.
    public let sampleCount: Int

    /// The widest velocity split on any one key: how many sampled dynamic
    /// layers the owner is really getting. 1 means none.
    public let velocityLayerCount: Int

    /// The deepest round robin on any one key, counting both `seq_length`
    /// sequences and `lorand`/`hirand` alternates. 1 means repeated notes
    /// always play the same sample.
    public let roundRobinDepth: Int

    /// True when the instrument samples its own release — a piano's dampers, a
    /// harp's string noise — rather than only fading the note out.
    public let hasReleaseTriggers: Bool

    /// True when at least one sounding region follows the key it is played at
    /// (`pitch_keytrack` above zero).
    ///
    /// **The asset fact behind INS003's pitch controls.** A patch whose every
    /// region pins its sample to the recorded pitch — a General MIDI style
    /// percussion map is the case in the curated set — has no pitch for a
    /// tuning offset or a vibrato to move, so `InstrumentCapabilities` disables
    /// both rather than offering a control that changes nothing audible.
    public let isPitched: Bool

    /// True when at least one sounding region actually stops on note-off.
    ///
    /// False for an instrument made entirely of one-shots, where the sample
    /// always plays to its end whatever the notated duration — a cymbal, a
    /// snare. Release shaping has nothing to act on there, so it is disabled
    /// rather than shown doing nothing.
    public let respondsToNoteOff: Bool

    /// True when any region loops, so a long note can be held indefinitely
    /// rather than running out of sample.
    public let hasSustainLoops: Bool

    /// Keyswitched articulations this file offers, or 0 when it has none.
    public let articulationCount: Int

    /// The keys that sound. Nil only when nothing does, which cannot happen for
    /// an instrument that loaded.
    public let playableKeyRange: ClosedRange<Int>?

    /// Address space the instrument's sample mappings occupy.
    public let mappedByteCount: Int64

    /// Bytes faulted into memory when the instrument loaded: every sample's
    /// attack. This is the figure to compare against a machine's RAM, not
    /// `mappedByteCount`.
    public let residentByteCount: Int64

    /// SFZ features the file uses that this player does not apply. Never
    /// fatal — see `SFZUnsupportedFeature`.
    public let unsupported: [SFZUnsupportedFeature]

    /// Samples the file names that could not be read. An empty list is the
    /// normal case and is what a healthy install looks like.
    public let unplayableSamples: [UnplayableSample]

    /// How long this instrument can still be heard after its last note ends.
    ///
    /// `LineVoiceProvider.releaseTailSeconds` is what `RenderProgram` uses to
    /// decide how far past the final event to render, so getting it wrong
    /// truncates the end of an export. A sampler's tail has two parts and both
    /// matter: the amplitude envelope's release, and — for a library that
    /// samples its own release — how long the longest release sample runs.
    /// Etherealwinds writes `ampeg_release=10`, and Salamander's string
    /// resonances are a second or two of sound in their own right.
    public let releaseTailSeconds: Double

    init(
        document: SFZDocument,
        regions: [SampleRegionData],
        waveforms: [SampleWaveform],
        unplayableSamples: [UnplayableSample],
        mappedByteCount: Int64,
        residentByteCount: Int64
    ) {
        self.regionCount = regions.count
        self.sampleCount = waveforms.count
        self.unsupported = document.unsupported
        self.unplayableSamples = unplayableSamples
        self.mappedByteCount = mappedByteCount
        self.residentByteCount = residentByteCount
        self.articulationCount = document.switchKeyRange.map { $0.count } ?? 0

        let attacks = regions.filter { $0.trigger == Int32(SampleRegionTriggerAttack.rawValue) }
        self.hasReleaseTriggers = regions.contains {
            $0.trigger == Int32(SampleRegionTriggerRelease.rawValue)
        }
        self.isPitched = attacks.contains { $0.pitchKeytrack > 0 }
        // A one-shot ignores note-off by definition — `sample_voice_release_slots`
        // skips it — so an instrument made only of one-shots never releases.
        self.respondsToNoteOff = attacks.contains {
            $0.loopMode != Int32(SampleLoopModeOneShot.rawValue)
        }
        self.hasSustainLoops = regions.contains { region in
            if region.loopMode == Int32(SampleLoopModeContinuous.rawValue)
                || region.loopMode == Int32(SampleLoopModeSustain.rawValue) { return true }
            // -1 means "whatever the file says", so a file with loop points
            // does loop.
            guard region.loopMode < 0,
                  region.waveformIndex >= 0, Int(region.waveformIndex) < waveforms.count
            else { return false }
            return waveforms[Int(region.waveformIndex)].fileLoopStart >= 0
        }

        let low = attacks.map(\.loKey).min()
        let high = attacks.map(\.hiKey).max()
        if let low, let high, low <= high {
            self.playableKeyRange = Int(max(0, low))...Int(min(127, high))
        } else {
            self.playableKeyRange = nil
        }

        // Layers and round robins are per key: an instrument sampled every
        // third semitone would otherwise look as though it had three times the
        // layers it has.
        var layersByKey: [Int: Set<Int32>] = [:]
        var alternatesByKey: [Int: Int] = [:]
        for region in attacks {
            let low = max(0, Int(region.loKey))
            let high = min(127, Int(region.hiKey))
            guard low <= high else { continue }
            for key in low...high {
                layersByKey[key, default: []].insert(region.loVelocity)
                let sequence = max(1, Int(region.sequenceLength))
                let windows = region.randomHigh - region.randomLow > 0
                    ? Int((1.0 / Double(region.randomHigh - region.randomLow)).rounded())
                    : 1
                alternatesByKey[key] = max(alternatesByKey[key] ?? 1, max(sequence, windows))
            }
        }
        self.velocityLayerCount = layersByKey.values.map(\.count).max() ?? 1
        self.roundRobinDepth = alternatesByKey.values.max() ?? 1

        let envelopeTail = attacks.map { Double($0.releaseSeconds) }.max() ?? 0
        let releaseSampleTail = regions
            .filter { $0.trigger == Int32(SampleRegionTriggerRelease.rawValue) }
            .compactMap { region -> Double? in
                guard region.waveformIndex >= 0,
                      Int(region.waveformIndex) < waveforms.count else { return nil }
                let waveform = waveforms[Int(region.waveformIndex)]
                guard waveform.sampleRate > 0 else { return nil }
                return Double(waveform.frameCount) / waveform.sampleRate
            }
            .max() ?? 0
        self.releaseTailSeconds = min(
            max(envelopeTail, releaseSampleTail), RenderProgram.maximumReleaseTailSeconds
        )
    }
}
