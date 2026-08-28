import Foundation

/// The rows of the personal sound library.
///
/// Deliberately thin: it reads and writes `sounds` and `retired_sound_ids` and
/// knows nothing about shipped content, edit-as-copy, or naming. All of that is
/// `SoundLibrary`'s, which is the only thing that should be able to say what a
/// legal change to a sound is.
///
/// A protocol, like `PieceCatalogWriting`, so the library's failure paths — a
/// store that refuses a write — can be exercised for real rather than described.
public protocol SoundCatalogStoring: Sendable {
    /// Every stored user sound, ordered by name then identity.
    func allStoredSounds() throws -> [SoundEntry]

    /// The stored sound with this identity, if there is one.
    func storedSound(withID id: String) throws -> SoundEntry?

    /// How many sounds the owner has of their own.
    func storedSoundCount() throws -> Int

    /// True when this identity has been retired by a delete and must never be
    /// handed to another sound.
    func isRetired(id: String) throws -> Bool

    /// Adds one sound. The caller has already validated its document.
    func insert(_ entry: SoundEntry, document: String) throws

    /// Replaces the mutable fields of an existing sound.
    func update(_ entry: SoundEntry, document: String) throws

    /// Deletes the row and retires its identity.
    ///
    /// Called inside the caller's transaction — like `PieceCatalogDeleting`,
    /// it must not open one of its own, because the deletion the owner sees is
    /// larger than these two statements.
    func deleteAndRetire(id: String, at timestamp: String) throws
}

/// The SQLite-backed personal sound library (schema v4).
public final class SoundCatalog: SoundCatalogStoring, @unchecked Sendable {
    /// Name of the table holding the owner's sounds.
    public static let tableName = "sounds"

    /// Name of the table holding identities a delete has retired.
    public static let retiredTableName = "retired_sound_ids"

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
        id, name, category, shipped_origin_id, document_version, document, \
        revision, created_at, updated_at
        """

    public func allStoredSounds() throws -> [SoundEntry] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(Self.tableName)
            ORDER BY name COLLATE NOCASE ASC, id ASC;
            """
        )
        .map(Self.entry(from:))
    }

    public func storedSound(withID id: String) throws -> SoundEntry? {
        try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) WHERE id = ? LIMIT 1;",
            [.text(id)]
        )
        .first
        .map(Self.entry(from:))
    }

    public func storedSoundCount() throws -> Int {
        try database.scalarInt("SELECT count(*) FROM \(Self.tableName);") ?? 0
    }

    public func isRetired(id: String) throws -> Bool {
        let count = try database.scalarInt(
            "SELECT count(*) FROM \(Self.retiredTableName) WHERE id = ?;",
            [.text(id)]
        )
        return (count ?? 0) > 0
    }

    public func insert(_ entry: SoundEntry, document: String) throws {
        try database.execute(
            """
            INSERT INTO \(Self.tableName) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(entry.id),
                .text(entry.name),
                .text(entry.category.rawValue),
                entry.shippedOriginID.map { SQLiteValue.text($0) } ?? .null,
                .integer(Int64(entry.documentVersion)),
                .text(document),
                .integer(Int64(entry.revision)),
                .text(entry.createdAt),
                .text(entry.updatedAt)
            ]
        )
    }

    /// `created_at` and `id` are deliberately not in the SET list: an edit
    /// changes what a sound *is*, never when it came into existence or which
    /// sound it is.
    public func update(_ entry: SoundEntry, document: String) throws {
        try database.execute(
            """
            UPDATE \(Self.tableName) SET
                name = ?,
                category = ?,
                document_version = ?,
                document = ?,
                revision = ?,
                updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(entry.name),
                .text(entry.category.rawValue),
                .integer(Int64(entry.documentVersion)),
                .text(document),
                .integer(Int64(entry.revision)),
                .text(entry.updatedAt),
                .text(entry.id)
            ]
        )
    }

    /// The row goes and the identity is retired, in the caller's transaction,
    /// so an identity is never retired without its sound going and a sound
    /// never goes without its identity being retired. The second half is what
    /// makes "deletes never reuse identities" a property of the database rather
    /// than of the identifier generator.
    public func deleteAndRetire(id: String, at timestamp: String) throws {
        try database.execute(
            "DELETE FROM \(Self.tableName) WHERE id = ?;",
            [.text(id)]
        )
        try database.execute(
            """
            INSERT INTO \(Self.retiredTableName) (id, retired_at) VALUES (?, ?)
            ON CONFLICT(id) DO NOTHING;
            """,
            [.text(id), .text(timestamp)]
        )
    }

    /// Rebuilds an entry from a row.
    ///
    /// A row that cannot be decoded throws rather than being skipped. A sound
    /// the owner made that silently stops appearing in their library is the one
    /// failure this store must never have.
    static func entry(from row: SQLiteRow) throws -> SoundEntry {
        let id = row.text("id") ?? "(no id)"

        func fail(_ reason: String) -> StoreError {
            StoreError.soundRowUnreadable(id: id, reason: reason)
        }

        guard
            let name = row.text("name"),
            let rawCategory = row.text("category"),
            let documentVersion = row.integer("document_version"),
            let document = row.text("document"),
            let revision = row.integer("revision"),
            let createdAt = row.text("created_at"),
            let updatedAt = row.text("updated_at"),
            row.text("id") != nil
        else {
            throw fail("Its stored form does not match this version of Synth.")
        }

        guard let category = SoundCategory(rawValue: rawCategory) else {
            throw fail("It is filed under “\(rawCategory)”, which this version of Synth does not know.")
        }

        let patch: SynthPatch
        do {
            patch = try SynthPatchDocument.patch(from: Data(document.utf8))
        } catch let error as SynthPatchDocumentError {
            throw fail(error.description)
        } catch {
            throw fail(String(describing: error))
        }

        return SoundEntry(
            id: id,
            name: name,
            category: category,
            origin: .user,
            shippedOriginID: row.text("shipped_origin_id"),
            documentVersion: Int(documentVersion),
            revision: Int(revision),
            createdAt: createdAt,
            updatedAt: updatedAt,
            patch: patch
        )
    }
}
