import Foundation

/// Which downloaded instrument a sound plays, named so it survives the
/// instrument being absent.
///
/// **Everything here is durable identity, not a path.** A container directory
/// belongs to one install on one machine; a variant the owner saved must still
/// say "Cello section, from VSCO 2 Community Edition" after the library has been
/// removed, so that the missing-instrument state can name what is missing and
/// offer to fetch it. The URLs are resolved from this at play time by
/// `InstrumentAssetStore`, never stored.
///
/// `libraryName` and `instrumentName` are carried alongside the identifiers for
/// exactly that reason: when this build's catalog no longer contains the
/// library, the identifiers resolve to nothing and these two are all the app
/// has left to say.
public struct InstrumentReference: Equatable, Sendable, Hashable, Codable {
    /// `CatalogLibrary.identifier`.
    public let libraryID: String

    /// `InstrumentCoverage.identifier`.
    public let instrumentID: String

    /// What the library was called when this reference was made.
    public let libraryName: String

    /// What the instrument was called when this reference was made.
    public let instrumentName: String

    public init(
        libraryID: String,
        instrumentID: String,
        libraryName: String,
        instrumentName: String
    ) {
        self.libraryID = libraryID
        self.instrumentID = instrumentID
        self.libraryName = libraryName
        self.instrumentName = instrumentName
    }

    /// The reference to an instrument the asset store found installed.
    public init(_ available: AvailableInstrument) {
        self.init(
            libraryID: available.libraryID,
            instrumentID: available.coverage.identifier,
            libraryName: available.libraryName,
            instrumentName: available.coverage.name
        )
    }

    /// The reference to an instrument this build's catalog declares, installed
    /// or not.
    public init(library: CatalogLibrary, coverage: InstrumentCoverage) {
        self.init(
            libraryID: library.identifier,
            instrumentID: coverage.identifier,
            libraryName: library.name,
            instrumentName: coverage.name
        )
    }

    /// The sound-library identity an installed instrument appears under.
    ///
    /// **Derived rather than allocated**, because an installed instrument is
    /// app-and-asset content with no row of its own — the same thing that makes
    /// a shipped sound's identity a fixed string. Removing a library and
    /// downloading it again therefore produces the same identity, so every
    /// preset that referenced it starts playing again rather than resolving to
    /// a stranger.
    ///
    /// Deliberately *not* `SampledInstrumentVoiceProvider.identifier`: that one
    /// names one SFZ file, because two articulations render differently. This
    /// names the instrument, because two articulations are one thing to assign.
    public var soundID: String { "instrument:\(libraryID)/\(instrumentID)" }

    /// The reference an `instrument:` sound identity names, or nil when the
    /// string is not one.
    public static func soundID(_ id: String) -> (libraryID: String, instrumentID: String)? {
        guard id.hasPrefix("instrument:") else { return nil }
        let body = id.dropFirst("instrument:".count)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let libraryID = String(body[body.startIndex..<slash])
        let instrumentID = String(body[body.index(after: slash)...])
        guard !libraryID.isEmpty, !instrumentID.isEmpty else { return nil }
        return (libraryID, instrumentID)
    }

    /// True when `id` names an installed-instrument sound rather than a stored
    /// one.
    public static func isInstrumentSoundID(_ id: String) -> Bool { soundID(id) != nil }
}

/// One instrument, played the owner's way (REQ-021, REQ-023).
///
/// **A variant never touches the samples.** It is a reference to a read-only
/// downloaded instrument plus the bounded parameter set the render core applies
/// over it, which is what makes "variants never mutate the downloaded assets"
/// a property of the type rather than a rule to remember. Saving one costs a
/// row in the sound library; the 3.2 GB under `assets/` is untouched by every
/// operation in this file.
public struct InstrumentVariant: Equatable, Sendable, Codable {
    public var reference: InstrumentReference
    public var customization: InstrumentCustomization

    public init(
        reference: InstrumentReference,
        customization: InstrumentCustomization = .asRecorded
    ) {
        self.reference = reference
        self.customization = customization
    }

    /// The instrument exactly as recorded — what an installed instrument looks
    /// like in the sound library before anyone has customized it.
    public static func asRecorded(_ available: AvailableInstrument) -> InstrumentVariant {
        InstrumentVariant(reference: InstrumentReference(available))
    }

    /// Which SFZ file this variant plays, or nil for the instrument's entry
    /// point.
    public var articulationFileName: String? { customization.articulationFileName }
}

// MARK: - Document

/// Why a variant document could not be read or written.
public enum InstrumentVariantDocumentError: Error, Equatable, CustomStringConvertible {
    case notJSON(reason: String)
    case missingVersion
    case unsupportedVersion(found: Int, supported: Int)
    case malformed(reason: String)
    case valueOutOfRange(name: String, value: Double, minimum: Double, maximum: Double)

    public var description: String {
        switch self {
        case .notJSON(let reason):
            return "This is not an instrument variant: \(reason)"
        case .missingVersion:
            return "This variant has no version, so it cannot be read safely."
        case .unsupportedVersion(let found, let supported):
            return "This variant was saved by a newer version of the app "
                + "(format \(found); this app reads up to \(supported))."
        case .malformed(let reason):
            return "This variant is malformed: \(reason)"
        case .valueOutOfRange(let name, let value, let minimum, let maximum):
            return "\(name) is \(value), outside the allowed range \(minimum)…\(maximum)."
        }
    }
}

/// The serialised form of an `InstrumentVariant`.
///
/// Same three rules as `SynthPatchDocument` and `PresetDocument`, so there is
/// one serialisation contract in this project rather than three: sorted-key
/// JSON so two writes of one variant produce identical bytes, an explicit
/// format version from day one, and a reader dispatched on that version so
/// raising it without saying what happens to the old shape fails loudly instead
/// of mis-reading every variant already on the owner's disk.
public enum InstrumentVariantDocument {
    /// Format version of a stored variant.
    public static let currentVersion = 1

    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let variant: InstrumentVariant
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    public static func data(from variant: InstrumentVariant) throws -> Data {
        try validate(variant)
        do {
            return try encoder.encode(Envelope(version: currentVersion, variant: variant))
        } catch {
            throw InstrumentVariantDocumentError.malformed(reason: String(describing: error))
        }
    }

    public static func version(of data: Data) throws -> Int {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound:
                throw InstrumentVariantDocumentError.missingVersion
            case .dataCorrupted(let context) where context.codingPath.isEmpty:
                throw InstrumentVariantDocumentError.notJSON(reason: context.debugDescription)
            default:
                throw InstrumentVariantDocumentError.malformed(reason: String(describing: error))
            }
        } catch {
            throw InstrumentVariantDocumentError.notJSON(reason: String(describing: error))
        }

        guard probe.version >= 1 else {
            throw InstrumentVariantDocumentError.malformed(
                reason: "version \(probe.version) is not a document version."
            )
        }
        guard probe.version <= currentVersion else {
            throw InstrumentVariantDocumentError.unsupportedVersion(
                found: probe.version, supported: currentVersion
            )
        }
        return probe.version
    }

    public static func variant(from data: Data) throws -> InstrumentVariant {
        let variant = try decode(version: try version(of: data), from: data)
        try validate(variant)
        return variant
    }

    private static func decode(version: Int, from data: Data) throws -> InstrumentVariant {
        switch version {
        case 1:
            do {
                return try JSONDecoder().decode(Envelope.self, from: data).variant
            } catch let error as DecodingError {
                throw InstrumentVariantDocumentError.malformed(reason: String(describing: error))
            } catch {
                throw InstrumentVariantDocumentError.malformed(reason: String(describing: error))
            }
        default:
            // Unreachable today: `version(of:)` rejects anything outside
            // 1…currentVersion. Present so raising `currentVersion` without a
            // reader here fails loudly rather than mis-reading old variants.
            throw InstrumentVariantDocumentError.malformed(
                reason: "no reader for variant format version \(version)."
            )
        }
    }

    /// Every invariant the model cannot make unrepresentable.
    ///
    /// The identifiers must be present, because a variant that names no
    /// instrument can never resolve to one; and every parameter must be inside
    /// the range the controls offer, because a stored value outside it would be
    /// silently clamped by the render core and the editor would then show a
    /// number that is not what is heard.
    public static func validate(_ variant: InstrumentVariant) throws {
        guard !variant.reference.libraryID.isEmpty, !variant.reference.instrumentID.isEmpty else {
            throw InstrumentVariantDocumentError.malformed(
                reason: "it names no instrument."
            )
        }

        let customization = variant.customization
        try check(customization.toneLowDecibels, "toneLowDecibels",
                  InstrumentCustomization.toneDecibelRange)
        try check(customization.toneHighDecibels, "toneHighDecibels",
                  InstrumentCustomization.toneDecibelRange)
        try check(customization.dynamicsResponse, "dynamicsResponse",
                  InstrumentCustomization.dynamicsResponseRange)
        try check(customization.attackSeconds, "attackSeconds",
                  InstrumentCustomization.attackSecondsRange)
        try check(customization.releaseScale, "releaseScale",
                  InstrumentCustomization.releaseScaleRange)
        try check(customization.vibratoDepthCents, "vibratoDepthCents",
                  InstrumentCustomization.vibratoDepthCentsRange)
        try check(customization.vibratoRateHz, "vibratoRateHz",
                  InstrumentCustomization.vibratoRateHzRange)
        try check(customization.tuningOffsetCents, "tuningOffsetCents",
                  InstrumentCustomization.tuningOffsetCentsRange)
    }

    private static func check(
        _ value: Double, _ name: String, _ range: ClosedRange<Double>
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw InstrumentVariantDocumentError.valueOutOfRange(
                name: name,
                value: value,
                minimum: range.lowerBound,
                maximum: range.upperBound
            )
        }
    }
}
