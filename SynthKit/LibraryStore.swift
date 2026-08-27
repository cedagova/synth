import Foundation

/// The opened, migrated persistent store: container directories plus the
/// versioned metadata database.
///
/// `open` is the single launch-time bootstrap every later leaf builds on.
public final class LibraryStore: @unchecked Sendable {
    public let container: AppContainer
    public let database: SQLiteDatabase

    /// Schema version in effect after `open` finished migrating.
    public let schemaVersion: Int

    /// What migrating this store did on this launch.
    public let migrationOutcome: MigrationOutcome

    private let fileManager: FileManager

    private init(
        container: AppContainer,
        database: SQLiteDatabase,
        schemaVersion: Int,
        migrationOutcome: MigrationOutcome,
        fileManager: FileManager
    ) {
        self.container = container
        self.database = database
        self.schemaVersion = schemaVersion
        self.migrationOutcome = migrationOutcome
        self.fileManager = fileManager
    }

    /// Prepares the container, opens the database, and migrates it forward.
    ///
    /// Safe to call on every launch: an existing container and store are reused
    /// as-is when they are already at the current schema version.
    ///
    /// - Parameters:
    ///   - container: defaults to `<Application Support>/Synth`.
    ///   - appVersion: recorded in the schema-version row for diagnosis.
    public static func open(
        container: AppContainer? = nil,
        appVersion: String,
        fileManager: FileManager = .default
    ) throws -> LibraryStore {
        let resolved: AppContainer
        if let container {
            resolved = container
        } else {
            resolved = try AppContainer.default(fileManager: fileManager)
        }
        try resolved.prepare(fileManager: fileManager)

        let database = try SQLiteDatabase.open(at: resolved.databaseURL)

        do {
            // Both pragmas must run outside a transaction.
            // WAL keeps readers non-blocking; FULL synchronous is the right
            // trade for a local library the owner must never lose.
            try database.executeScript("PRAGMA journal_mode = WAL;")
            try database.executeScript("PRAGMA synchronous = FULL;")
            try database.executeScript("PRAGMA foreign_keys = ON;")

            let outcome = try SchemaMigrator.migrate(database, appVersion: appVersion)
            let version = try SchemaMigrator.currentVersion(of: database)

            return LibraryStore(
                container: resolved,
                database: database,
                schemaVersion: version,
                migrationOutcome: outcome,
                fileManager: fileManager
            )
        } catch {
            database.close()
            throw error
        }
    }

    /// How many pieces are stored in the container today.
    ///
    /// Imported MusicXML is kept verbatim as one file per piece under
    /// `pieces/`, so the stored file count is the library size this leaf can
    /// establish. The import pipeline replaces this with the database-backed
    /// catalog it owns.
    public func storedPieceCount() throws -> Int {
        let contents = try fileManager.contentsOfDirectory(
            at: container.piecesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.count
    }

    /// When the current schema version was recorded, as stored ISO 8601 text.
    public func schemaVersionAppliedAt() throws -> String? {
        try database.scalarText(
            "SELECT applied_at FROM \(SchemaMigrator.versionTableName) WHERE id = 1;"
        )
    }

    /// Closes the database handle. The container stays on disk.
    public func close() {
        database.close()
    }
}
