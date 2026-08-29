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

    /// A downloaded instrument, exactly as its library recorded it (REQ-020).
    ///
    /// **The same kind of thing a shipped sound is, and read-only for the same
    /// reason.** It is not a row: it is derived from the assets INS001
    /// installed, so removing the library removes it and downloading the
    /// library again brings back the identical identity. Customizing one means
    /// `makeEditableCopy(of:)`, whose result is a named variant of the owner's
    /// — which is REQ-017's edit-as-copy rule applied to an instrument, and why
    /// "variants never mutate the downloaded assets" needs no separate
    /// enforcement.
    case instrument

    /// The owner's own sound, in the versioned store (REQ-023). A synth patch
    /// or a named instrument variant.
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
    /// Added by increment 005 so downloaded instruments file where an
    /// orchestral score would look for them. Purely additive, exactly as the
    /// note above promises: no stored row changes, and a store written before
    /// this build never named either of the two new values.
    case woodwinds
    case percussion

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
        case .woodwinds: return "Woodwinds"
        case .percussion: return "Percussion"
        }
    }

    /// Where an instrument of this family files in the sound library.
    ///
    /// A total function rather than a lookup that can miss, so adding a family
    /// to REQ-020 fails to compile here instead of quietly filing a new
    /// instrument under Keys.
    public static func forInstrumentFamily(_ family: InstrumentCoverage.Family) -> SoundCategory {
        switch family {
        case .strings: return .strings
        case .woodwinds: return .woodwinds
        case .brass: return .brass
        case .keyboards: return .keys
        // A harp is plucked, and Plucks is where the shipped nylon pluck
        // already lives — so a harp line's alternatives sit beside it.
        case .harp: return .plucks
        case .percussion: return .percussion
        }
    }

    /// Declaration order, which is the order the library lists categories in.
    var sortIndex: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// What a sound actually *is*.
///
/// **The two kinds of sound REQ-023 names, as one closed set.** A synth patch
/// is the complete description of a sound the engine synthesises; an instrument
/// variant is a reference to read-only downloaded assets plus the bounded
/// parameters they are played with. They are alternatives rather than a struct
/// with two optionals, because a sound is exactly one of them and a
/// representable "both" or "neither" would be a state every consumer had to
/// decide what to do about.
///
/// It is also what makes `SoundKind` in the preset document mean something:
/// the discriminator ASN001 wrote from day one now has a second case behind it,
/// and no already-written preset had to change for that.
public enum SoundContent: Equatable, Sendable {
    /// A synth patch from SYN001's engine.
    case synth(SynthPatch)

    /// A downloaded instrument, played the owner's way (INS002 + INS003).
    case instrument(InstrumentVariant)

    /// Which engine renders it.
    public var kind: SoundKind {
        switch self {
        case .synth: return .synth
        case .instrument: return .instrument
        }
    }

    /// The patch, when this is a synth sound. Nil for an instrument variant —
    /// deliberately, so a caller that only knows how to render a patch has to
    /// say what it does about the other case rather than silently rendering the
    /// default voice over a cello.
    public var synthPatch: SynthPatch? {
        if case .synth(let patch) = self { return patch }
        return nil
    }

    public var instrumentVariant: InstrumentVariant? {
        if case .instrument(let variant) = self { return variant }
        return nil
    }
}

/// One sound in the library: a shipped entry, an installed instrument, or a
/// stored user entry.
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

    /// ISO 8601 UTC.
    ///
    /// **Empty string for a shipped entry**, which has no store row and
    /// therefore no moment it came into existence — the app version is what
    /// says which shipped collection you have. A consumer that formats these as
    /// dates must check `origin` (or for emptiness) rather than assume every
    /// entry has one; `Optional` was rejected because it would put a `?` on
    /// every user sound's timestamp to describe the shipped case.
    public let createdAt: String
    public let updatedAt: String

    /// The complete sound. Loading it fully determines what is heard.
    public let content: SoundContent

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
        content: SoundContent
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
        self.content = content
    }

    /// The synth patch, when this sound is one.
    public var synthPatch: SynthPatch? { content.synthPatch }

    /// The instrument variant, when this sound is one.
    public var instrumentVariant: InstrumentVariant? { content.instrumentVariant }

    /// Which engine renders it.
    public var kind: SoundKind { content.kind }

    /// Whether this sound may be renamed, re-categorised, edited or deleted.
    ///
    /// False for a shipped sound (REQ-017) and for an installed instrument,
    /// which is read-only for the same reason: neither is a row, and neither
    /// belongs to the owner to change in place. The library enforces this
    /// itself rather than trusting a caller to read the flag.
    public var isEditable: Bool { origin == .user }

    /// True when customizing this means making a copy of it first.
    public var mustBeCopiedToEdit: Bool { origin != .user }

    /// What VoiceOver says a row in the sound list is.
    ///
    /// Here rather than inside a `View` for the reason `PieceDisplay` gives: a
    /// sentence assembled only inside a `body` cannot be tested, and a list row
    /// is exactly where that matters — an `AXOutline` does not vend its rows to
    /// a walk from inside the same process, so this string is not observable
    /// from the app's own smoke run and has to be asserted here instead.
    ///
    /// One sentence, not three labels: "Warm Analog Pad, Pads, one of Synth's
    /// own sounds, read-only" rather than a name followed by an anonymous lock.
    public var accessibilityDescription: String {
        switch origin {
        case .shipped:
            return "\(name), \(category.displayName), one of Synth's own sounds, read-only"
        case .instrument:
            let library = content.instrumentVariant?.reference.libraryName ?? "a downloaded library"
            return "\(name), \(category.displayName), a downloaded instrument from \(library), "
                + "read-only"
        case .user:
            guard let variant = content.instrumentVariant else {
                return "\(name), \(category.displayName), your sound"
            }
            let base = "\(name), \(category.displayName), your variant of "
                + "\(variant.reference.instrumentName)"
            guard let changes = variant.customization.changeSummary else { return base }
            return "\(base), \(changes)"
        }
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
