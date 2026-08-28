import Foundation

/// Every failure the persistent-store bootstrap can surface at launch.
///
/// Each case carries enough detail to render a specific, actionable launch
/// error; `LocalizedError` supplies the owner-facing wording.
public enum StoreError: Error, Equatable, Sendable {
    /// The system could not tell us where Application Support lives.
    case applicationSupportUnavailable(reason: String)

    /// A container directory could not be created (permissions, disk full, ...).
    case containerCreationFailed(path: String, reason: String)

    /// A path the container needs is occupied by something that is not a directory.
    case containerPathIsNotADirectory(path: String)

    /// SQLite refused to open or create the database file.
    case databaseOpenFailed(path: String, code: Int32, message: String)

    /// A SQL statement failed. `sql` is always app-authored, never user input.
    case statementFailed(sql: String, code: Int32, message: String)

    /// The store on disk is newer than this build understands. Forward-only
    /// migrations mean we must refuse rather than guess.
    case storeWrittenByNewerApp(storedVersion: Int, supportedVersion: Int)

    /// A migration threw. The whole pending chain is rolled back before this
    /// error is raised, so the store is left exactly as it was.
    case migrationFailed(version: Int, name: String, reason: String)

    /// The `schema_version` table exists but holds no readable current row.
    case schemaVersionUnreadable

    /// A `pieces` row could not be decoded into a `PieceRecord`. The database
    /// no longer matches this build's schema, which is loud rather than a
    /// silently vanishing piece.
    case pieceRowUnreadable(id: String)

    /// A `sounds` row could not be decoded into a `SoundEntry` — a missing
    /// column, a category this build does not know, a patch document it cannot
    /// read, or a row whose recorded format version disagrees with the document
    /// it describes. Loud for the same reason as `pieceRowUnreadable`: a sound
    /// the owner made must never quietly disappear from the list.
    ///
    /// **Reading is all-or-nothing, and the wording says so.** `entry(from:)`
    /// throws on the first row it cannot decode, and every listing goes through
    /// it, so one bad row stops the whole library being listed rather than
    /// costing one sound. That is the intended design — silently dropping the
    /// row is the failure this case exists to prevent — but it means the
    /// recovery text must not reassure the owner that their other sounds are
    /// fine while they are staring at an empty list.
    case soundRowUnreadable(id: String, reason: String)

    /// A `presets` or `line_names` row could not be decoded — a missing column,
    /// a preset document this build cannot read, or a row whose recorded format
    /// version disagrees with the document it describes.
    ///
    /// Loud for the same reason as `soundRowUnreadable`, and with the same
    /// all-or-nothing consequence: one unreadable preset stops the piece's
    /// preset list being read rather than costing one preset. Silently dropping
    /// it would lose an interpretation the owner built, which REQ-025 is
    /// precisely a promise not to do.
    case presetRowUnreadable(id: String, reason: String)
}

extension StoreError: LocalizedError {
    /// Paths are shown home-relative so messages stay readable and never put
    /// the account name on screen or in a screenshot.
    private static func display(_ path: String) -> String {
        HomeRelativePath.display(path, relativeTo: HomeRelativePath.realHomeDirectory)
    }

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable(let reason):
            return "Synth could not locate your Application Support folder. \(reason)"
        case .containerCreationFailed(let path, let reason):
            return "Synth could not create its library folder at \(Self.display(path)). \(reason)"
        case .containerPathIsNotADirectory(let path):
            return "Synth expected a folder at \(Self.display(path)), but something else is already there."
        case .databaseOpenFailed(let path, let code, let message):
            return "Synth could not open its library database at \(Self.display(path)). SQLite error \(code): \(message)"
        case .statementFailed(_, let code, let message):
            return "Synth's library database rejected an operation. SQLite error \(code): \(message)"
        case .storeWrittenByNewerApp(let storedVersion, let supportedVersion):
            return """
                Your library was written by a newer version of Synth \
                (store schema \(storedVersion), this build understands \(supportedVersion)).
                """
        case .migrationFailed(let version, let name, let reason):
            return "Synth could not upgrade its library to schema \(version) (\(name)). \(reason)"
        case .schemaVersionUnreadable:
            return "Synth's library database has no readable schema version."
        case .pieceRowUnreadable(let id):
            return "Synth could not read the library entry \(id); its stored form does not match this version of Synth."
        case .soundRowUnreadable(let id, let reason):
            return "Synth could not read the sound \(id), so it cannot list your sound library. \(reason)"
        case .presetRowUnreadable(let id, let reason):
            return "Synth could not read the preset \(id), so it cannot list this piece's presets. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Check that your home folder is available, then reopen Synth."
        case .containerCreationFailed:
            return "Check available disk space and folder permissions, then reopen Synth."
        case .containerPathIsNotADirectory:
            return "Move or rename that item, then reopen Synth."
        case .databaseOpenFailed:
            return "Check available disk space and folder permissions, then reopen Synth."
        case .statementFailed:
            return "Reopen Synth. If this keeps happening, the library database may be damaged."
        case .storeWrittenByNewerApp:
            return "Update Synth to the newest version you have used with this library."
        case .migrationFailed:
            return "Your library was left unchanged. Check disk space, then reopen Synth."
        case .schemaVersionUnreadable:
            return "The library database may be damaged. Restore it from a backup."
        case .pieceRowUnreadable:
            return "Update Synth to the newest version you have used with this library, or restore the library from a backup."
        case .soundRowUnreadable:
            return "No sounds can be listed until that entry is dealt with. Update Synth to the newest version you have used with this library, or restore the library from a backup."
        case .presetRowUnreadable:
            return "This piece's presets cannot be listed until that entry is dealt with. Update Synth to the newest version you have used with this library, or restore the library from a backup."
        }
    }
}
