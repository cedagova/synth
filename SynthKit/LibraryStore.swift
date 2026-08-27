import Foundation

/// The opened, migrated persistent store: container directories plus the
/// versioned metadata database.
///
/// `open` is the single launch-time bootstrap every later leaf builds on.
public final class LibraryStore: @unchecked Sendable {
    public let container: AppContainer
    public let database: SQLiteDatabase

    /// The library's piece records. Written by the import pipeline, read by
    /// the library UI and, from increment 002, by the score compiler.
    public let pieces: PieceCatalog

    /// Where each piece's verbatim MusicXML lives inside the container.
    public let pieceContent: PieceContentStoring

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
        self.pieces = PieceCatalog(database: database)
        self.pieceContent = DirectoryPieceContentStore(directoryURL: container.piecesURL)
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

    /// How many pieces the library holds.
    ///
    /// The catalog is the authority: a file under `pieces/` with no record is
    /// not a piece, only debris a rolled-back import failed to clean up.
    public func pieceCount() throws -> Int {
        try pieces.pieceCount()
    }

    /// How many verbatim score files sit in the container.
    ///
    /// Equal to `pieceCount()` in a healthy library. Exposed because that
    /// equality is exactly what the import contract promises, and a diagnostic
    /// that cannot be checked is not a guarantee.
    public func storedContentFileCount() throws -> Int {
        try fileManager.contentsOfDirectory(
            at: container.piecesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).count
    }

    /// An importer writing into this store.
    public func makeImporter() -> MusicXMLImporter {
        MusicXMLImporter(store: self)
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
