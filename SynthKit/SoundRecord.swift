import Foundation

/// Where a sound came from, and therefore whether it can be changed.
///
/// The distinction REQ-017 is about. A shipped sound is app content: it is
/// versioned with the app, it is not a row in anyone's store, and it cannot be
/// modified or deleted. A user sound is the owner's, lives in the store, and
/// is theirs to rename, re-categorize, edit and delete.
public enum SoundOrigin: String, Codable, Sendable, CaseIterable {
    /// Immutable app content, present on every first run (REQ-019).
    case shipped
    /// The owner's own sound, in the versioned store (REQ-023).
    case user
}

/// How the library is organised.
///
/// A closed set rather than free text, so the shipped collection's
/// categorisation means something and re-categorising is a move between known
/// places rather than a spelling exercise. Stored as the raw string, so adding
/// a category later is an additive change to this enum and needs no migration.
///
/// A row whose category this build does not know is a loud failure
/// (`StoreError.soundRowUnreadable`), not a silently vanished sound — and the
/// forward-only migrator already refuses a store written by a newer build, so
/// the set really is fixed for any store this build will open.
public enum SoundCategory: String, Codable, Sendable, CaseIterable {
    case keys
    case pads
    case bass
    case leads
    case plucks
    case bells
    case brass
    case strings

    /// Shown in a picker or a section header.
    public var displayName: String {
        switch self {
        case .keys: return "Keys"
        case .pads: return "Pads"
        case .bass: return "Bass"
        case .leads: return "Leads"
        case .plucks: return "Plucks"
        case .bells: return "Bells"
        case .brass: return "Brass"
        case .strings: return "Strings"
        }
    }

    /// Declaration order, which is the order the library lists categories in.
    var sortIndex: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// One sound in the library: a shipped entry or a stored user entry.
///
/// **The identity model increment 004 will reference.** `id` is stable for the
/// life of the sound — a rename does not change it, a re-categorisation does
/// not change it, and a deleted identity is never handed to a different sound
/// (`retired_sound_ids`). That is what lets a preset hold a live reference to a
/// sound rather than a copy of it, which is the whole premise of REQ-029.
///
/// `revision` is the other half. A live reference has to be able to tell that
/// the sound it points at has *changed* since it was assigned; a counter that
/// only ever goes up says so without comparing two patches.
public struct SoundEntry: Equatable, Sendable, Identifiable {
    /// Stable identity. Shipped identities are fixed strings compiled into the
    /// app; user identities are UUIDs allocated once and never reused.
    public let id: String

    /// The name shown wherever a sound is chosen. Never the identity.
    public let name: String

    public let category: SoundCategory
    public let origin: SoundOrigin

    /// The shipped sound this was copied from, when it was one.
    ///
    /// Provenance, not a live link: the copy is complete and independent, and
    /// editing it can never reach back to the shipped original. Kept so the
    /// editor can say "based on Warm Analog Pad" and so a future app update
    /// that improves a shipped sound can tell which copies came from it.
    public let shippedOriginID: String?

    /// Format version of the patch document as it was stored.
    ///
    /// The store's schema version and the patch document's format version are
    /// different things with different lifetimes, so the row carries both.
    public let documentVersion: Int

    /// Bumps on every edit that changes this sound. 0 for shipped entries,
    /// which never change within one build.
    public let revision: Int

    /// ISO 8601 UTC. Empty for shipped entries, which have no store row.
    public let createdAt: String
    public let updatedAt: String

    /// The complete sound. Loading it fully determines what is heard.
    public let patch: SynthPatch

    public init(
        id: String,
        name: String,
        category: SoundCategory,
        origin: SoundOrigin,
        shippedOriginID: String? = nil,
        documentVersion: Int,
        revision: Int,
        createdAt: String,
        updatedAt: String,
        patch: SynthPatch
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.origin = origin
        self.shippedOriginID = shippedOriginID
        self.documentVersion = documentVersion
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.patch = patch
    }

    /// Whether this sound may be renamed, re-categorised, edited or deleted.
    ///
    /// False for every shipped sound (REQ-017). The library enforces this
    /// itself rather than trusting a caller to read the flag.
    public var isEditable: Bool { origin == .user }

    /// A provider that renders this sound, for the engine.
    public var voiceProvider: SynthPatchVoiceProvider {
        SynthPatchVoiceProvider(patch: patch)
    }

    /// Ordering the library lists in: category, then name, then identity.
    ///
    /// Identity last so two sounds sharing a name still have a stable order —
    /// names are deliberately not unique.
    static func isOrderedBefore(_ left: SoundEntry, _ right: SoundEntry) -> Bool {
        if left.category != right.category {
            return left.category.sortIndex < right.category.sortIndex
        }
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.id < right.id
    }
}
