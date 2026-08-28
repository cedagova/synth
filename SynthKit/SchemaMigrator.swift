import Foundation

/// One forward step of the store schema.
///
/// Migrations are forward-only and numbered contiguously from 1. A build never
/// downgrades a store: opening a store written by a newer build fails loudly
/// instead (`StoreError.storeWrittenByNewerApp`).
public struct Migration: Sendable {
    /// Schema version this migration produces. Contiguous from 1.
    public let version: Int

    /// Stable identifier used in errors and in the recorded version row.
    public let name: String

    /// Applies the step. Runs inside the migrator's transaction; it must not
    /// open one of its own.
    public let apply: @Sendable (SQLiteDatabase) throws -> Void

    public init(version: Int, name: String, apply: @escaping @Sendable (SQLiteDatabase) throws -> Void) {
        self.version = version
        self.name = name
        self.apply = apply
    }
}

/// What `SchemaMigrator.migrate` did.
public struct MigrationOutcome: Equatable, Sendable {
    /// Schema version found on disk before migrating. 0 means a fresh store.
    public let previousVersion: Int

    /// Schema version after migrating.
    public let currentVersion: Int

    /// Names of the migrations applied by this call, in order.
    public let appliedMigrationNames: [String]

    /// True when the store was already at the target version.
    public var wasAlreadyCurrent: Bool { appliedMigrationNames.isEmpty }
}

/// Applies the versioned, forward-only schema chain to a database.
public enum SchemaMigrator {
    /// Name of the table holding the single current-version row.
    public static let versionTableName = "schema_version"

    /// The complete ordered migration chain for this build.
    ///
    /// Version 1 establishes the versioning mechanism itself: the single-row
    /// `schema_version` table every later migration and every later leaf reads.
    /// Content tables (pieces, sounds, presets, catalog) arrive as additive
    /// version-2+ migrations in the leaves that own them.
    public static let migrations: [Migration] = [
        Migration(version: 1, name: "create_schema_version") { database in
            try database.executeScript(
                """
                CREATE TABLE schema_version (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    version INTEGER NOT NULL,
                    applied_at TEXT NOT NULL,
                    app_version TEXT NOT NULL
                ) STRICT;
                """
            )
        },
        Migration(version: 2, name: "create_pieces") { database in
            // The metadata half of an imported piece. The score itself stays
            // beside the database as a verbatim file under `pieces/`;
            // `content_file_name` is the link, and `content_sha256` is both the
            // duplicate key and an integrity check for later readers.
            try database.executeScript(
                """
                CREATE TABLE pieces (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    composer TEXT,
                    work_title TEXT,
                    work_number TEXT,
                    movement_title TEXT,
                    movement_number TEXT,
                    source_file_name TEXT NOT NULL,
                    source_format TEXT NOT NULL,
                    content_file_name TEXT NOT NULL,
                    content_sha256 TEXT NOT NULL,
                    content_byte_count INTEGER NOT NULL,
                    imported_at TEXT NOT NULL
                ) STRICT;

                CREATE UNIQUE INDEX pieces_content_sha256
                    ON pieces (content_sha256);

                CREATE UNIQUE INDEX pieces_content_file_name
                    ON pieces (content_file_name);
                """
            )
        },
        Migration(version: 3, name: "create_preferences") { database in
            // The owner's small durable choices — the humanization enable and
            // intensity the transport exposes (REQ-012), and whatever later
            // increments add. One key-value table so a new preference costs no
            // migration; `updated_at` is diagnostic only.
            try database.executeScript(
                """
                CREATE TABLE preferences (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;
                """
            )
        },
        Migration(version: 4, name: "create_sounds") { database in
            // The owner's personal sound library (REQ-023). Purely additive:
            // nothing here touches `pieces` or `preferences`, so a store this
            // step migrated still opens with every earlier record intact, and
            // reverting this build leaves the store openable — the two extra
            // tables are simply unread.
            //
            // **Only user sounds are rows.** The shipped collection is app
            // content compiled into the build (`ShippedSoundCollection`), which
            // is what makes "shipped content is never duplicated into user
            // storage until edited" literally true and makes deleting a shipped
            // sound impossible rather than merely refused.
            //
            // The patch document lives in the row rather than beside the
            // database as a file. AD3 puts *verbatim assets* — MusicXML,
            // downloaded samples — in the filesystem and metadata in SQLite; a
            // patch is small structured metadata, and keeping it here is what
            // makes a rename, a re-categorisation and an edit one atomic
            // transaction instead of a row write plus a file write that can
            // half-fail. `sounds/` in the container stays reserved for
            // increment 005's sampled instrument assets, which are the other
            // kind.
            try database.executeScript(
                """
                CREATE TABLE sounds (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    shipped_origin_id TEXT,
                    document_version INTEGER NOT NULL,
                    document TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;

                CREATE INDEX sounds_category ON sounds (category);

                CREATE TABLE retired_sound_ids (
                    id TEXT PRIMARY KEY,
                    retired_at TEXT NOT NULL
                ) STRICT;

                CREATE TRIGGER sounds_never_reuse_a_retired_identity
                    BEFORE INSERT ON sounds
                    WHEN EXISTS (SELECT 1 FROM retired_sound_ids WHERE id = NEW.id)
                BEGIN
                    SELECT RAISE(ABORT, 'a deleted sound identity is never reused');
                END;
                """
            )
        },
        Migration(version: 5, name: "create_presets") { database in
            // Per-piece presets and line renames (REQ-005, REQ-024, REQ-029).
            // Purely additive: nothing here touches `pieces`, `preferences` or
            // `sounds`, so a store this step migrated still opens with every
            // earlier record intact, and reverting this build leaves the store
            // openable — the two extra tables are simply unread.
            //
            // The preset *document* lives in the row for the same reason a
            // patch does: name, active flag and content then change in one
            // atomic transaction instead of a row write plus a file write that
            // can half-fail. It is also what makes auto-save (REQ-024) a single
            // statement rather than a two-phase commit.
            //
            // Two constraints here are load-bearing rather than decorative:
            //
            // * `presets_one_active_per_piece` is a *partial* unique index, so
            //   "exactly one preset is active" is a property of the database
            //   rather than of the code that remembers to clear the old flag.
            // * The `piece_id` foreign key has deliberately **no** ON DELETE
            //   CASCADE. REQ-003's cascade is `PresetLibrary`'s explicit
            //   `PieceDependentStore` hook, and leaving the key strict means a
            //   removal that somehow skipped that hook aborts loudly inside the
            //   transaction instead of orphaning presets. The failure mode is a
            //   refused removal with everything intact, which is the one this
            //   store is allowed to have.
            try database.executeScript(
                """
                CREATE TABLE presets (
                    id TEXT PRIMARY KEY,
                    piece_id TEXT NOT NULL REFERENCES pieces (id),
                    name TEXT NOT NULL,
                    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
                    document_version INTEGER NOT NULL,
                    document TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;

                CREATE INDEX presets_piece ON presets (piece_id);

                CREATE UNIQUE INDEX presets_one_active_per_piece
                    ON presets (piece_id) WHERE is_active = 1;

                CREATE TABLE line_names (
                    piece_id TEXT NOT NULL REFERENCES pieces (id),
                    line_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (piece_id, line_id)
                ) STRICT;
                """
            )
        }
    ]

    /// Highest schema version this build understands.
    public static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Reads the current schema version, or 0 when the store is fresh.
    public static func currentVersion(of database: SQLiteDatabase) throws -> Int {
        guard try database.tableExists(versionTableName) else { return 0 }
        guard let version = try database.scalarInt(
            "SELECT version FROM \(versionTableName) WHERE id = 1;"
        ) else {
            throw StoreError.schemaVersionUnreadable
        }
        return version
    }

    /// Brings `database` up to the newest schema this build understands.
    ///
    /// The whole pending chain runs inside one transaction, so a failure at any
    /// step leaves the store exactly as it was found. A store already newer
    /// than this build is refused rather than modified.
    ///
    /// - Parameters:
    ///   - database: the store to migrate.
    ///   - appVersion: recorded alongside the version row for diagnosis.
    ///   - migrations: injectable for tests; defaults to the shipped chain.
    @discardableResult
    public static func migrate(
        _ database: SQLiteDatabase,
        appVersion: String,
        migrations: [Migration] = SchemaMigrator.migrations
    ) throws -> MigrationOutcome {
        precondition(
            migrations.enumerated().allSatisfy { $0.element.version == $0.offset + 1 },
            "Migrations must be numbered contiguously from 1"
        )

        let target = migrations.last?.version ?? 0
        let existing = try currentVersion(of: database)

        guard existing <= target else {
            throw StoreError.storeWrittenByNewerApp(
                storedVersion: existing,
                supportedVersion: target
            )
        }

        let pending = migrations.filter { $0.version > existing }
        guard !pending.isEmpty else {
            return MigrationOutcome(
                previousVersion: existing,
                currentVersion: existing,
                appliedMigrationNames: []
            )
        }

        try database.withTransaction { transactionDatabase in
            for migration in pending {
                do {
                    try migration.apply(transactionDatabase)
                } catch {
                    throw StoreError.migrationFailed(
                        version: migration.version,
                        name: migration.name,
                        reason: (error as? LocalizedError)?.errorDescription
                            ?? (error as NSError).localizedDescription
                    )
                }
            }

            try transactionDatabase.execute(
                """
                INSERT INTO \(versionTableName) (id, version, applied_at, app_version)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    version = excluded.version,
                    applied_at = excluded.applied_at,
                    app_version = excluded.app_version;
                """,
                [
                    .integer(Int64(target)),
                    .text(Self.timestamp()),
                    .text(appVersion)
                ]
            )
        }

        return MigrationOutcome(
            previousVersion: existing,
            currentVersion: target,
            appliedMigrationNames: pending.map(\.name)
        )
    }

    /// ISO 8601 UTC, stable and sortable as text.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
