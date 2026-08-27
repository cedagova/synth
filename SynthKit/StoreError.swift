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
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable(let reason):
            return "Synth could not locate your Application Support folder. \(reason)"
        case .containerCreationFailed(let path, let reason):
            return "Synth could not create its library folder at \(path). \(reason)"
        case .containerPathIsNotADirectory(let path):
            return "Synth expected a folder at \(path), but something else is already there."
        case .databaseOpenFailed(let path, let code, let message):
            return "Synth could not open its library database at \(path). SQLite error \(code): \(message)"
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
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Check that your home folder is available, then reopen Synth."
        case .containerCreationFailed:
            return "Check available disk space and folder permissions, then reopen Synth."
        case .containerPathIsNotADirectory(let path):
            return "Move or rename the item at \(path), then reopen Synth."
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
        }
    }
}
