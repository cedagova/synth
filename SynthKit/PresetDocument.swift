import Foundation

/// Which engine renders a sound.
///
/// **The engine-agnostic seam.** REQ-006 says a line's one sound is a synth
/// patch *or* an instrument, mutually exclusive. Only synth patches are
/// assignable in this build, so this enumeration has one case — but the stored
/// document carries the discriminator from day one, so increment 005 adds
/// `instrument` beside `synth` without touching a single already-written
/// preset. A document naming a kind this build does not know is a loud failure
/// (`PresetDocumentError.malformed`), never a silently dropped assignment.
///
/// The mutual exclusivity itself is not enforced by this type. It is
/// structural: `PresetLine.assignment` is one non-optional `LineAssignment`, so
/// an unassigned or dual-assigned line is not representable.
public enum SoundKind: String, Codable, Sendable, CaseIterable {
    /// A `SynthPatch` from the sound library (SYN002).
    case synth
}

/// One line's volume, pan, mute and solo, as the preset stores them (REQ-008).
///
/// The same four values `PlaybackEngine.LineMixer` exposes and in the same
/// units, so applying a preset is a copy rather than a conversion. `volume` is
/// linear gain, not decibels, for exactly that reason — the engine multiplies
/// by it, and storing decibels would put a `pow` between the stored value and
/// the audible one where a rounding difference could hide.
public struct LineMixerState: Equatable, Sendable, Codable {
    /// Linear gain, 0…8. 1 is unity, which is what a new line gets.
    public var volume: Double

    /// -1 hard left … +1 hard right, equal-power. 0 is centre.
    public var pan: Double

    public var isMuted: Bool

    /// While any line in the preset is soloed, every line that is not is
    /// silent. The rule lives in the engine; the preset only records the flags.
    public var isSoloed: Bool

    /// Highest gain the engine accepts, mirrored here so a stored preset can
    /// never ask for a level the engine would quietly clamp.
    public static let maximumVolume: Double = 8

    /// A line nobody has touched: unity, centred, heard.
    public static let neutral = LineMixerState(volume: 1, pan: 0, isMuted: false, isSoloed: false)

    public init(volume: Double = 1, pan: Double = 0, isMuted: Bool = false, isSoloed: Bool = false) {
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

/// A complete private copy of a sound, taken at the moment it was deleted.
///
/// REQ-029's other half. A preset holds a *live reference* to a library sound
/// so editing the sound is heard everywhere it is used; when the owner deletes
/// that sound, the reference would dangle, so the deletion transaction replaces
/// it with one of these — the sound exactly as it then was, patch included.
///
/// Self-contained on purpose. Nothing here points back at the library, so a
/// later sound-format migration cannot reach an embedded copy and a re-created
/// sound with a similar name cannot be mistaken for the original. `originalSoundID`
/// is provenance for the UI's "embedded from …", never a lookup key.
public struct EmbeddedSound: Equatable, Sendable, Codable {
    public let kind: SoundKind

    /// Identity of the library sound this was copied from. Retired forever by
    /// the delete that created this copy, so it can never resolve to anything.
    public let originalSoundID: String

    /// The name the sound had when it was deleted.
    public let name: String

    public let category: SoundCategory

    /// The sound itself. Complete: this is what is rendered.
    public let patch: SynthPatch

    /// ISO 8601 UTC moment of the deletion that embedded this.
    public let embeddedAt: String

    public init(
        kind: SoundKind = .synth,
        originalSoundID: String,
        name: String,
        category: SoundCategory,
        patch: SynthPatch,
        embeddedAt: String
    ) {
        self.kind = kind
        self.originalSoundID = originalSoundID
        self.name = name
        self.category = category
        self.patch = patch
        self.embeddedAt = embeddedAt
    }

    /// A copy of `entry` as it is right now.
    public init(copying entry: SoundEntry, at timestamp: String) {
        self.init(
            kind: .synth,
            originalSoundID: entry.id,
            name: entry.name,
            category: entry.category,
            patch: entry.patch,
            embeddedAt: timestamp
        )
    }
}

/// The one sound a line plays through.
///
/// Two cases, and the difference between them is visible to the owner (REQ-029
/// asks for exactly that): a live reference follows the library sound wherever
/// the owner takes it, and an embedded copy is frozen because the sound it came
/// from no longer exists.
public enum LineAssignment: Equatable, Sendable {
    /// A live reference to a sound in the library. Editing that sound changes
    /// what this line plays, in every preset that references it.
    case library(kind: SoundKind, soundID: String)

    /// A private copy the delete-in-use path left behind (REQ-029).
    case embedded(EmbeddedSound)

    /// Which engine renders it, whichever case this is.
    public var kind: SoundKind {
        switch self {
        case .library(let kind, _): return kind
        case .embedded(let sound): return sound.kind
        }
    }

    /// True for a copy the library can no longer change.
    public var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }

    /// The library identity this refers to, or the identity an embedded copy
    /// was taken from.
    public var soundID: String {
        switch self {
        case .library(_, let id): return id
        case .embedded(let sound): return sound.originalSoundID
        }
    }

    /// True when this is a live reference to `soundID`. An embedded copy of
    /// that same sound is deliberately not a reference to it any more.
    public func referencesLibrarySound(_ soundID: String) -> Bool {
        if case .library(_, let id) = self { return id == soundID }
        return false
    }
}

extension LineAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case source, kind, soundID, embedded
    }

    private enum Source: String, Codable {
        case library, embedded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Source.self, forKey: .source) {
        case .library:
            self = .library(
                kind: try container.decode(SoundKind.self, forKey: .kind),
                soundID: try container.decode(String.self, forKey: .soundID)
            )
        case .embedded:
            self = .embedded(try container.decode(EmbeddedSound.self, forKey: .embedded))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .library(let kind, let soundID):
            try container.encode(Source.library, forKey: .source)
            try container.encode(kind, forKey: .kind)
            try container.encode(soundID, forKey: .soundID)
        case .embedded(let sound):
            try container.encode(Source.embedded, forKey: .source)
            try container.encode(sound, forKey: .embedded)
        }
    }
}

/// One line of a preset: which line, what it plays, and how it sits in the mix.
public struct PresetLine: Equatable, Sendable, Codable, Identifiable {
    /// PLY001's stable voice-level identity. `id` so a SwiftUI list in ASN002
    /// can key on it directly.
    public let lineID: ScoreLineID

    public var assignment: LineAssignment
    public var mixer: LineMixerState

    public var id: ScoreLineID { lineID }

    public init(lineID: ScoreLineID, assignment: LineAssignment, mixer: LineMixerState = .neutral) {
        self.lineID = lineID
        self.assignment = assignment
        self.mixer = mixer
    }
}

/// Everything a preset says about a piece, as it is stored.
///
/// **What "complete assignment, customization, and mixer state" (REQ-024)
/// means here.** Assignment and mixer state are literally these fields.
/// Customization is captured *through* the assignment rather than duplicated
/// beside it: a synth sound's customization is its patch, which lives in the
/// library sound the line references — so editing that sound is heard by every
/// preset using it (REQ-029), and deleting it embeds the patch verbatim so the
/// customization survives. Copying the patch into the preset as well would give
/// one sound two homes and make the live-reference requirement unsatisfiable.
///
/// Identity, name, active flag and timestamps are deliberately *not* here: they
/// belong to the row (`Preset`), the same split `SoundEntry` uses. A preset
/// renamed in the list must not need its document rewritten.
public struct PresetContent: Equatable, Sendable, Codable {
    /// One entry per line of the piece, in the compiled score's line order.
    public var lines: [PresetLine]

    public init(lines: [PresetLine]) {
        self.lines = lines
    }

    /// Format version of the stored document. Bumping this requires adding a
    /// reader case in `PresetDocument.decode`, which the `default` branch there
    /// makes impossible to forget.
    public static let currentVersion = 1

    public func line(withID id: ScoreLineID) -> PresetLine? {
        lines.first { $0.lineID == id }
    }

    public func index(ofLine id: ScoreLineID) -> Int? {
        lines.firstIndex { $0.lineID == id }
    }

    /// Every live library reference this preset holds, deduplicated.
    public var referencedLibrarySoundIDs: Set<String> {
        Set(lines.compactMap { line in
            if case .library(_, let id) = line.assignment { return id }
            return nil
        })
    }
}

/// Why a preset document could not be read or written.
public enum PresetDocumentError: Error, Equatable, CustomStringConvertible {
    case notJSON(reason: String)
    case missingVersion
    case unsupportedVersion(found: Int, supported: Int)
    case malformed(reason: String)
    /// Two entries for one line: the one-sound-per-line invariant, violated by
    /// a file rather than by the model.
    case duplicateLine(lineID: String)
    case valueOutOfRange(name: String, value: Double, minimum: Double, maximum: Double)
    /// An embedded copy whose patch the engine would refuse.
    case embeddedSoundRejected(name: String, reason: String)

    public var description: String {
        switch self {
        case .notJSON(let reason):
            return "This is not a preset document: \(reason)"
        case .missingVersion:
            return "This preset document has no version, so it cannot be read safely."
        case .unsupportedVersion(let found, let supported):
            return "This preset was saved by a newer version of the app "
                + "(format \(found); this app reads up to \(supported))."
        case .malformed(let reason):
            return "This preset document is malformed: \(reason)"
        case .duplicateLine(let lineID):
            return "This preset assigns two sounds to the line \(lineID)."
        case .valueOutOfRange(let name, let value, let minimum, let maximum):
            return "\(name) is \(value), outside the allowed range \(minimum)…\(maximum)."
        case .embeddedSoundRejected(let name, let reason):
            return "The embedded copy of “\(name)” cannot be played: \(reason)"
        }
    }
}

/// The serialised form of a `PresetContent`.
///
/// Same shape and same rules as `SynthPatchDocument`: sorted-key JSON so two
/// writes of one preset produce identical bytes, an explicit format version
/// from day one, and a reader dispatched on that version so raising it without
/// saying what happens to the old shape fails loudly instead of mis-reading
/// every preset already on the owner's disk.
public enum PresetDocument {
    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        let version: Int
        let preset: PresetContent
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// Serialise `content` at the current format version, validating first.
    public static func data(from content: PresetContent) throws -> Data {
        try validate(content)
        do {
            return try encoder.encode(
                Envelope(version: PresetContent.currentVersion, preset: content)
            )
        } catch {
            throw PresetDocumentError.malformed(reason: String(describing: error))
        }
    }

    /// The format version a document declares, without decoding the preset.
    public static func version(of data: Data) throws -> Int {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound:
                throw PresetDocumentError.missingVersion
            case .dataCorrupted(let context) where context.codingPath.isEmpty:
                throw PresetDocumentError.notJSON(reason: context.debugDescription)
            default:
                throw PresetDocumentError.malformed(reason: readable(error))
            }
        } catch {
            throw PresetDocumentError.notJSON(reason: String(describing: error))
        }

        guard probe.version >= 1 else {
            throw PresetDocumentError.malformed(
                reason: "version \(probe.version) is not a document version."
            )
        }
        guard probe.version <= PresetContent.currentVersion else {
            throw PresetDocumentError.unsupportedVersion(
                found: probe.version, supported: PresetContent.currentVersion
            )
        }
        return probe.version
    }

    /// Load a preset, or explain precisely why it cannot be loaded.
    public static func content(from data: Data) throws -> PresetContent {
        let content = try decode(version: try version(of: data), from: data)
        try validate(content)
        return content
    }

    private static func decode(version: Int, from data: Data) throws -> PresetContent {
        switch version {
        case 1:
            do {
                return try JSONDecoder().decode(Envelope.self, from: data).preset
            } catch let error as DecodingError {
                throw PresetDocumentError.malformed(reason: readable(error))
            } catch {
                throw PresetDocumentError.malformed(reason: String(describing: error))
            }
        default:
            // Unreachable today: `version(of:)` rejects anything outside
            // 1…currentVersion. Present so raising `currentVersion` without a
            // reader here fails loudly rather than mis-reading old presets.
            throw PresetDocumentError.malformed(
                reason: "no reader for preset format version \(version)."
            )
        }
    }

    /// Every invariant the model cannot make unrepresentable.
    ///
    /// One entry per line is structural in memory but not in a file, so it is
    /// checked here; mixer values are checked so a stored preset can never ask
    /// for a level the engine would silently clamp; and an embedded patch is
    /// run through the engine's own parameter validation, because an embedded
    /// copy that cannot be played would defeat the entire point of embedding it.
    public static func validate(_ content: PresetContent) throws {
        var seen = Set<ScoreLineID>()
        for line in content.lines {
            guard seen.insert(line.lineID).inserted else {
                throw PresetDocumentError.duplicateLine(lineID: line.lineID.rawValue)
            }

            try check(line.mixer.volume, "volume", 0, LineMixerState.maximumVolume)
            try check(line.mixer.pan, "pan", -1, 1)

            if case .embedded(let sound) = line.assignment {
                do {
                    try SynthPatchDocument.validate(sound.patch)
                } catch let error as SynthPatchDocumentError {
                    throw PresetDocumentError.embeddedSoundRejected(
                        name: sound.name, reason: error.description
                    )
                }
            }
        }
    }

    private static func check(
        _ value: Double, _ name: String, _ minimum: Double, _ maximum: Double
    ) throws {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw PresetDocumentError.valueOutOfRange(
                name: name, value: value, minimum: minimum, maximum: maximum
            )
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
            let location = path(context)
            return location.isEmpty ? context.debugDescription : "\(location): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}

/// One stored preset: its row and its content.
///
/// The same split `SoundEntry` uses. `name`, `isActive` and the timestamps are
/// columns, so renaming a preset or making it active is one UPDATE and never a
/// document rewrite.
public struct Preset: Equatable, Sendable, Identifiable {
    /// Stable identity, allocated once. Unlike a sound's, a preset identity is
    /// not retired on delete: nothing outside the piece references a preset.
    public let id: String

    /// The piece this preset belongs to, and dies with (REQ-003).
    public let pieceID: String

    public let name: String

    /// Exactly one preset per piece has this set (REQ-024). The store enforces
    /// it with a partial unique index, not with care.
    public let isActive: Bool

    public let documentVersion: Int

    /// Bumps on every change, so a consumer can tell that a preset moved
    /// without diffing its content.
    public let revision: Int

    /// ISO 8601 UTC.
    public let createdAt: String
    public let updatedAt: String

    public let content: PresetContent

    public init(
        id: String,
        pieceID: String,
        name: String,
        isActive: Bool,
        documentVersion: Int,
        revision: Int,
        createdAt: String,
        updatedAt: String,
        content: PresetContent
    ) {
        self.id = id
        self.pieceID = pieceID
        self.name = name
        self.isActive = isActive
        self.documentVersion = documentVersion
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
    }

    public var lines: [PresetLine] { content.lines }

    public func line(withID id: ScoreLineID) -> PresetLine? { content.line(withID: id) }

    /// True when at least one line of this preset is soloed, which is what
    /// makes every unsoloed line silent.
    public var hasSoloedLine: Bool { content.lines.contains { $0.mixer.isSoloed } }

    /// Ordering the preset list uses: name, then identity so two presets
    /// sharing a name still have a stable order.
    static func isOrderedBefore(_ left: Preset, _ right: Preset) -> Bool {
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.id < right.id
    }
}
