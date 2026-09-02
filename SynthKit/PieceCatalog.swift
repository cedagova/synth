import Foundation

/// Read access to the library's piece records.
public protocol PieceCatalogReading: Sendable {
    /// The piece whose stored content has this digest, if the library has it.
    func piece(withContentSHA256 digest: String) throws -> PieceRecord?

    /// Every piece, ordered by title then imported time, both ascending.
    func allPieces() throws -> [PieceRecord]

    /// How many pieces the library holds.
    func pieceCount() throws -> Int
}

/// Delete access to the library's piece records.
///
/// Separate from `PieceCatalogWriting` because removal's failure paths need a
/// catalog that refuses to delete, and the importer's do not: keeping the two
/// capabilities apart means neither side's test doubles have to implement the
/// other's operations.
public protocol PieceCatalogDeleting: PieceCatalogReading {
    /// The piece with this identifier, if it exists.
    func piece(withID id: String) throws -> PieceRecord?

    /// Deletes the piece with this identifier. Deleting a piece that is not
    /// there is not an error; the caller checks existence when it matters.
    func delete(pieceID: String) throws
}

/// Write access to the library's piece records.
///
/// A protocol rather than a concrete dependency so the importer's failure
/// paths — a catalog write that fails after the content file already landed —
/// can be exercised for real instead of described.
public protocol PieceCatalogWriting: PieceCatalogReading {
    /// Adds one piece. Throws `StoreError.statementFailed` when the record
    /// collides with an existing one, which is what makes the duplicate rule
    /// hold even if two imports race past the lookup.
    func insert(_ record: PieceRecord) throws
}

/// The SQLite-backed piece catalog: the metadata half of AD3.
///
/// Bulk content stays beside the database as files under `pieces/`; this table
/// holds only what the library must query.
public final class PieceCatalog: PieceCatalogWriting, PieceCatalogDeleting, @unchecked Sendable {
    /// Name of the table this catalog owns.
    public static let tableName = "pieces"

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
        id, title, composer, work_title, work_number, movement_title, \
        movement_number, source_file_name, source_format, content_file_name, \
        content_sha256, content_byte_count, imported_at
        """

    public func piece(withContentSHA256 digest: String) throws -> PieceRecord? {
        let rows = try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) WHERE content_sha256 = ? LIMIT 1;",
            [.text(digest)]
        )
        return try rows.first.map(Self.record(from:))
    }

    /// The piece with this identifier, if it exists.
    public func piece(withID id: String) throws -> PieceRecord? {
        let rows = try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) WHERE id = ? LIMIT 1;",
            [.text(id)]
        )
        return try rows.first.map(Self.record(from:))
    }

    public func allPieces() throws -> [PieceRecord] {
        try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) ORDER BY title COLLATE NOCASE ASC, imported_at ASC;"
        )
        .map(Self.record(from:))
    }

    public func pieceCount() throws -> Int {
        try database.scalarInt("SELECT count(*) FROM \(Self.tableName);") ?? 0
    }

    public func insert(_ record: PieceRecord) throws {
        try database.execute(
            """
            INSERT INTO \(Self.tableName) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(record.id),
                .text(record.title),
                Self.optional(record.composer),
                Self.optional(record.workTitle),
                Self.optional(record.workNumber),
                Self.optional(record.movementTitle),
                Self.optional(record.movementNumber),
                .text(record.sourceFileName),
                .text(record.sourceFormat.rawValue),
                .text(record.contentFileName),
                .text(record.contentSHA256),
                .integer(Int64(record.contentByteCount)),
                .text(record.importedAt)
            ]
        )
    }

    /// Replaces the owner-facing title and composer of one piece.
    ///
    /// The owner's edit is ground truth over anything the importer derived:
    /// re-importing the same content is a duplicate and never rewrites the
    /// record, so an edited name can only be changed by editing it again.
    public func updateNames(pieceID: String, title: String, composer: String?) throws {
        try database.execute(
            "UPDATE \(Self.tableName) SET title = ?, composer = ? WHERE id = ?;",
            [.text(title), Self.optional(composer), .text(pieceID)]
        )
    }

    public func delete(pieceID: String) throws {
        try database.execute(
            "DELETE FROM \(Self.tableName) WHERE id = ?;",
            [.text(pieceID)]
        )
    }

    private static func optional(_ value: String?) -> SQLiteValue {
        value.map { SQLiteValue.text($0) } ?? .null
    }

    /// Rebuilds a record from a row. A row that cannot be decoded means the
    /// database no longer matches this build's schema, which is a loud failure
    /// rather than a silently dropped piece.
    private static func record(from row: SQLiteRow) throws -> PieceRecord {
        guard
            let id = row.text("id"),
            let title = row.text("title"),
            let sourceFileName = row.text("source_file_name"),
            let rawFormat = row.text("source_format"),
            let sourceFormat = PieceSourceFormat(rawValue: rawFormat),
            let contentFileName = row.text("content_file_name"),
            let contentSHA256 = row.text("content_sha256"),
            let contentByteCount = row.integer("content_byte_count"),
            let importedAt = row.text("imported_at")
        else {
            throw StoreError.pieceRowUnreadable(id: row.text("id") ?? "(no id)")
        }

        return PieceRecord(
            id: id,
            title: title,
            composer: row.text("composer"),
            workTitle: row.text("work_title"),
            workNumber: row.text("work_number"),
            movementTitle: row.text("movement_title"),
            movementNumber: row.text("movement_number"),
            sourceFileName: sourceFileName,
            sourceFormat: sourceFormat,
            contentFileName: contentFileName,
            contentSHA256: contentSHA256,
            contentByteCount: Int(contentByteCount),
            importedAt: importedAt
        )
    }
}
