import Foundation

/// Why a patch document could not be loaded.
///
/// Every case names the parameter or the version at fault. A patch is a file
/// the user's own library hands us, and increment 004's presets will hand us
/// more of them; "could not load patch" with no further detail would make a
/// corrupt file indistinguishable from a bug in this engine.
public enum SynthPatchDocumentError: Error, Equatable, CustomStringConvertible {
    /// The bytes are not a JSON object at all.
    case notJSON(reason: String)
    /// A JSON object with no `version`, so there is no safe way to read it.
    case missingVersion
    /// Written by a later version of the app.
    case unsupportedVersion(found: Int, supported: Int)
    /// Structurally wrong: a missing key, a wrong type, an unknown enumerated
    /// value.
    case malformed(reason: String)
    /// The architecture is fixed, so a patch with the wrong number of
    /// oscillators, LFOs or modulation routes is not a patch.
    case wrongComponentCount(name: String, found: Int, expected: Int)
    /// A parameter outside the range the engine accepts.
    case parameterOutOfRange(name: String, value: Double, minimum: Double, maximum: Double)

    public var description: String {
        switch self {
        case .notJSON(let reason):
            return "This is not a patch document: \(reason)"
        case .missingVersion:
            return "This patch document has no version, so it cannot be read safely."
        case .unsupportedVersion(let found, let supported):
            return "This patch was saved by a newer version of the app "
                + "(format \(found); this app reads up to \(supported))."
        case .malformed(let reason):
            return "This patch document is malformed: \(reason)"
        case .wrongComponentCount(let name, let found, let expected):
            return "This patch has \(found) \(name) where the synthesis architecture has \(expected)."
        case .parameterOutOfRange(let name, let value, let minimum, let maximum):
            return "\(name) is \(value), outside the allowed range \(minimum)…\(maximum)."
        }
    }
}

/// The serialised form of a `SynthPatch`.
///
/// JSON with sorted keys, so writing the same patch twice produces the same
/// bytes and a stored patch diffs cleanly. Versioned from its introduction, as
/// the issue requires: a document carries the format version it was written
/// with, and a reader that meets a higher number stops instead of guessing at
/// a shape it has never seen.
public enum SynthPatchDocument {
    /// Just enough of the document to decide whether the rest can be read.
    ///
    /// Read separately, and first, because a future format may have changed
    /// the patch's own shape — in which case decoding the whole thing would
    /// fail with a confusing key error instead of the true reason.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let patch: SynthPatch
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// Serialise `patch` at the current format version.
    ///
    /// Validates first: a document this refuses to write is one no reader
    /// would accept, and failing here points at the parameter rather than at a
    /// file that will not open tomorrow.
    public static func data(from patch: SynthPatch) throws -> Data {
        try validate(patch)
        do {
            return try encoder.encode(Envelope(version: SynthPatch.currentVersion, patch: patch))
        } catch {
            throw SynthPatchDocumentError.malformed(reason: String(describing: error))
        }
    }

    /// Load a patch, or explain precisely why it cannot be loaded.
    public static func patch(from data: Data) throws -> SynthPatch {
        let decoder = JSONDecoder()

        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound:
                throw SynthPatchDocumentError.missingVersion
            case .dataCorrupted(let context) where context.codingPath.isEmpty:
                throw SynthPatchDocumentError.notJSON(reason: context.debugDescription)
            default:
                throw SynthPatchDocumentError.malformed(reason: readable(error))
            }
        } catch {
            throw SynthPatchDocumentError.notJSON(reason: String(describing: error))
        }

        guard probe.version >= 1 else {
            throw SynthPatchDocumentError.malformed(
                reason: "version \(probe.version) is not a document version."
            )
        }
        guard probe.version <= SynthPatch.currentVersion else {
            throw SynthPatchDocumentError.unsupportedVersion(
                found: probe.version, supported: SynthPatch.currentVersion
            )
        }

        let patch = try decode(version: probe.version, from: data, using: decoder)
        try validate(patch)
        return patch
    }

    /*
     Forward migration, dispatched on the document's own version.

     One case today, and that is the point. Without this branch, `patch(from:)`
     would admit every version from 1 to the current one and then hand all of
     them to the *current* shape's decoder — correct while there is only one
     shape, and quietly wrong the moment someone bumps `currentVersion` with a
     changed layout, because every patch already on a user's disk would start
     failing to load and nothing here would have objected.

     The plan is explicit that persisted formats are versioned from day one
     *with* forward migrations, and `SchemaMigrator` honours that literally for
     the store. This is the same obligation for the format SYN002 is about to
     fill a personal library with. Adding version 2 now forces whoever does it
     to say what happens to version 1, instead of letting the trap be walked
     into silently.
    */
    private static func decode(
        version: Int, from data: Data, using decoder: JSONDecoder
    ) throws -> SynthPatch {
        switch version {
        case 1:
            return try decodeVersion1(from: data, using: decoder)
        default:
            // Unreachable: `patch(from:)` has already rejected anything outside
            // 1…currentVersion. Present so raising `currentVersion` without
            // adding a case here fails loudly rather than mis-reading old
            // documents.
            throw SynthPatchDocumentError.malformed(
                reason: "no reader for patch format version \(version)."
            )
        }
    }

    private static func decodeVersion1(
        from data: Data, using decoder: JSONDecoder
    ) throws -> SynthPatch {
        do {
            return try decoder.decode(Envelope.self, from: data).patch
        } catch let error as DecodingError {
            throw SynthPatchDocumentError.malformed(reason: readable(error))
        } catch {
            throw SynthPatchDocumentError.malformed(reason: String(describing: error))
        }
    }

    private static func readable(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context)
            return parent.isEmpty ? "missing \(key.stringValue)" : "missing \(parent).\(key.stringValue)"
        case .typeMismatch(let type, let context):
            return "\(path(context)) is not a \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)) has no \(type)"
        case .dataCorrupted(let context):
            let where_ = path(context)
            return where_.isEmpty ? context.debugDescription : "\(where_): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: Validation

    /// Check every parameter against the range the engine documents.
    ///
    /// The render core clamps as well, and that clamp is the guarantee the
    /// audio thread relies on. This exists so a bad value is *reported* rather
    /// than silently corrected: a patch that says the cutoff is 900 kHz is a
    /// broken file, and quietly rendering it at 20 kHz would hide that.
    public static func validate(_ patch: SynthPatch) throws {
        guard patch.oscillators.count == SynthPatch.oscillatorCount else {
            throw SynthPatchDocumentError.wrongComponentCount(
                name: "oscillators", found: patch.oscillators.count,
                expected: SynthPatch.oscillatorCount
            )
        }
        guard patch.lfos.count == SynthPatch.lfoCount else {
            throw SynthPatchDocumentError.wrongComponentCount(
                name: "LFOs", found: patch.lfos.count, expected: SynthPatch.lfoCount
            )
        }
        guard patch.modulation.count == SynthPatch.modulationSlotCount else {
            throw SynthPatchDocumentError.wrongComponentCount(
                name: "modulation routes", found: patch.modulation.count,
                expected: SynthPatch.modulationSlotCount
            )
        }

        for (index, oscillator) in patch.oscillators.enumerated() {
            let label = "oscillators[\(index)]"
            try check(oscillator.level, "\(label).level", 0, 1)
            try check(oscillator.detuneSemitones, "\(label).detuneSemitones", -48, 48)
            try check(oscillator.detuneCents, "\(label).detuneCents", -100, 100)
            try check(oscillator.shapeAmount, "\(label).shapeAmount", 0, 1)
            try check(oscillator.frequencyModulationRatio,
                      "\(label).frequencyModulationRatio", 0.25, 16)
            try check(oscillator.startPhase, "\(label).startPhase", 0, 1)
        }

        try check(patch.noiseLevel, "noiseLevel", 0, 1)

        try check(patch.filter.cutoffHertz, "filter.cutoffHertz", 20, 20_000)
        try check(patch.filter.resonance, "filter.resonance", 0, 1)
        try check(patch.filter.keyTracking, "filter.keyTracking", 0, 1)
        guard patch.filter.poles == 2 || patch.filter.poles == 4 else {
            throw SynthPatchDocumentError.parameterOutOfRange(
                name: "filter.poles", value: Double(patch.filter.poles), minimum: 2, maximum: 4
            )
        }

        try check(patch.amplitudeEnvelope, "amplitudeEnvelope")
        try check(patch.modulationEnvelope, "modulationEnvelope")

        for (index, lfo) in patch.lfos.enumerated() {
            try check(lfo.rateHertz, "lfos[\(index)].rateHertz", 0.01, 40)
            try check(lfo.startPhase, "lfos[\(index)].startPhase", 0, 1)
        }

        for (index, route) in patch.modulation.enumerated() {
            try check(route.amount, "modulation[\(index)].amount", -1, 1)
        }

        try check(patch.equalizer.lowGainDecibels, "equalizer.lowGainDecibels", -24, 24)
        try check(patch.equalizer.lowHertz, "equalizer.lowHertz", 30, 1_000)
        try check(patch.equalizer.midGainDecibels, "equalizer.midGainDecibels", -24, 24)
        try check(patch.equalizer.midHertz, "equalizer.midHertz", 100, 8_000)
        try check(patch.equalizer.midQ, "equalizer.midQ", 0.2, 8)
        try check(patch.equalizer.highGainDecibels, "equalizer.highGainDecibels", -24, 24)
        try check(patch.equalizer.highHertz, "equalizer.highHertz", 1_000, 16_000)

        try check(patch.chorus.rateHertz, "chorus.rateHertz", 0.01, 8)
        try check(patch.chorus.depthMilliseconds, "chorus.depthMilliseconds", 0.5, 20)
        try check(patch.chorus.centreMilliseconds, "chorus.centreMilliseconds", 1, 30)
        try check(patch.chorus.mix, "chorus.mix", 0, 1)
        try check(patch.chorus.feedback, "chorus.feedback", 0, 0.7)

        try check(patch.delay.timeSeconds, "delay.timeSeconds", 0.005, 1)
        try check(patch.delay.feedback, "delay.feedback", 0, 0.85)
        try check(patch.delay.mix, "delay.mix", 0, 1)
        try check(patch.delay.dampening, "delay.dampening", 0, 1)

        try check(patch.reverb.roomSize, "reverb.roomSize", 0, 1)
        try check(patch.reverb.dampening, "reverb.dampening", 0, 1)
        try check(patch.reverb.mix, "reverb.mix", 0, 1)
        try check(patch.reverb.preDelaySeconds, "reverb.preDelaySeconds", 0, 0.1)

        try check(Double(patch.maximumVoices), "maximumVoices", 1, Double(SynthPatch.maximumPolyphony))
        try check(patch.outputLevel, "outputLevel", 0, 1)
        try check(patch.velocitySensitivity, "velocitySensitivity", 0.2, 4)
    }

    private static func check(_ envelope: SynthPatch.Envelope, _ label: String) throws {
        try check(envelope.attackSeconds, "\(label).attackSeconds", 0.0005, 10)
        try check(envelope.decaySeconds, "\(label).decaySeconds", 0.001, 20)
        try check(envelope.sustainLevel, "\(label).sustainLevel", 0, 1)
        try check(envelope.releaseSeconds, "\(label).releaseSeconds", 0.001, 20)
        try check(envelope.curve, "\(label).curve", 0, 1)
    }

    private static func check(
        _ value: Double, _ name: String, _ minimum: Double, _ maximum: Double
    ) throws {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw SynthPatchDocumentError.parameterOutOfRange(
                name: name, value: value, minimum: minimum, maximum: maximum
            )
        }
    }
}
