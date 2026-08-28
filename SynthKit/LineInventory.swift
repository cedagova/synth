import Foundation

/// One line of a piece as the owner sees it: its stable identity, the name the
/// score implies, and the name the owner gave it.
///
/// REQ-005 in one value. The identity is PLY001's `ScoreLineID`, derived only
/// from `(part, staff, voice)`, so a keyboard fugue yields one entry per fugal
/// voice rather than one entry called "Piano".
public struct LineEntry: Equatable, Sendable, Identifiable {
    public let id: ScoreLineID

    /// The name the compiled score gives this line — `Violin I`, or
    /// `Piano, staff 2, voice 5`. Recomputed from the score on every open, so
    /// improving the deriver reaches every existing piece.
    public let defaultName: String

    /// What to show. The owner's rename when there is one, otherwise
    /// `defaultName`.
    public let name: String

    /// `part-name`, when the score gives one. Kept because the auto-mapping
    /// reads it and because a UI grouping lines by part needs it.
    public let partName: String?

    public let staff: Int
    public let voice: String

    /// True when the owner renamed this line.
    ///
    /// A rename is stored, a default is derived, and the difference matters:
    /// resetting a renamed line is a delete, not a write of the current
    /// default, so a later improvement to the deriver still reaches it.
    public var isRenamed: Bool { name != defaultName }

    public init(
        id: ScoreLineID,
        defaultName: String,
        name: String? = nil,
        partName: String? = nil,
        staff: Int = 1,
        voice: String = "1"
    ) {
        self.id = id
        self.defaultName = defaultName
        self.name = name ?? defaultName
        self.partName = partName
        self.staff = staff
        self.voice = voice
    }

    /// What VoiceOver says a line row is.
    ///
    /// Here rather than in a `View` for the reason `SoundEntry` gives: a
    /// sentence assembled inside a `body` cannot be tested, and a list row is
    /// exactly where that matters.
    public var accessibilityDescription: String {
        isRenamed ? "\(name), renamed from \(defaultName)" : name
    }
}

/// Every line of one piece, in the compiled score's order.
///
/// The inventory is derived, never stored: the lines come from compiling the
/// piece's verbatim MusicXML, and only the *renames* are persisted. That is why
/// a preset can be written against a piece before the owner has renamed
/// anything, and why re-importing an improved compiler does not orphan a
/// preset — the identities do not move.
public struct LineInventory: Equatable, Sendable {
    public let pieceID: String
    public let entries: [LineEntry]

    public init(pieceID: String, entries: [LineEntry]) {
        self.pieceID = pieceID
        self.entries = entries
    }

    /// Builds the inventory for a compiled score, applying stored renames.
    public init(score: CompiledScore, renames: [ScoreLineID: String] = [:]) {
        self.init(
            pieceID: score.pieceID,
            entries: score.lines.map { line in
                LineEntry(
                    id: line.id,
                    defaultName: line.name,
                    name: renames[line.id],
                    partName: line.partName,
                    staff: line.staff,
                    voice: line.voice
                )
            }
        )
    }

    public var lineIDs: [ScoreLineID] { entries.map(\.id) }

    public func entry(withID id: ScoreLineID) -> LineEntry? {
        entries.first { $0.id == id }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
}
