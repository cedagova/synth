import Foundation

/// The rows behind per-piece presets and line renames: the SQLite half of
/// schema v5.
///
/// Deliberately thin, like `SoundCatalog`. It reads and writes `presets` and
/// `line_names` and knows nothing about auto-creation, the active-preset rule,
/// embedding, or the removal cascade — all of which belong to `PresetLibrary`,
/// because that should be the only thing able to say what a legal change to a
/// preset is.
public final class PresetCatalog: @unchecked Sendable {
    /// Name of the table holding presets.
    public static let tableName = "presets"

    /// Name of the table holding the owner's line renames.
    public static let lineNameTableName = "line_names"

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    private static let columns = """
        id, piece_id, name, is_active, document_version, document, revision, \
        created_at, updated_at
        """

    // MARK: Presets

    /// Every preset of one piece, ordered by name then identity.
    public func presets(forPieceID pieceID: String) throws -> [Preset] {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(Self.tableName)
            WHERE piece_id = ?
            ORDER BY name COLLATE NOCASE ASC, id ASC;
            """,
            [.text(pieceID)]
        )
        .map(Self.preset(from:))
    }

    public func preset(withID id: String) throws -> Preset? {
        try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) WHERE id = ? LIMIT 1;",
            [.text(id)]
        )
        .first
        .map(Self.preset(from:))
    }

    /// The one preset of this piece with the active flag set, if there is one.
    public func activePreset(forPieceID pieceID: String) throws -> Preset? {
        try database.query(
            """
            SELECT \(Self.columns) FROM \(Self.tableName)
            WHERE piece_id = ? AND is_active = 1 LIMIT 1;
            """,
            [.text(pieceID)]
        )
        .first
        .map(Self.preset(from:))
    }

    public func presetCount(forPieceID pieceID: String) throws -> Int {
        try database.scalarInt(
            "SELECT count(*) FROM \(Self.tableName) WHERE piece_id = ?;",
            [.text(pieceID)]
        ) ?? 0
    }

    public func presetCount() throws -> Int {
        try database.scalarInt("SELECT count(*) FROM \(Self.tableName);") ?? 0
    }

    /// Every preset in the store, whatever piece it belongs to.
    ///
    /// Used by the delete-in-use scan (REQ-029), which has to find references
    /// across every piece rather than only the one currently open.
    public func allPresets() throws -> [Preset] {
        try database.query(
            "SELECT \(Self.columns) FROM \(Self.tableName) ORDER BY piece_id ASC, id ASC;"
        )
        .map(Self.preset(from:))
    }

    public func insert(_ preset: Preset, document: String) throws {
        try database.execute(
            """
            INSERT INTO \(Self.tableName) (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(preset.id),
                .text(preset.pieceID),
                .text(preset.name),
                .integer(preset.isActive ? 1 : 0),
                .integer(Int64(preset.documentVersion)),
                .text(document),
                .integer(Int64(preset.revision)),
                .text(preset.createdAt),
                .text(preset.updatedAt)
            ]
        )
    }

    /// `piece_id`, `created_at` and `id` are deliberately not in the SET list:
    /// a change alters what a preset *is*, never which piece it belongs to,
    /// when it came into existence, or which preset it is.
    public func update(_ preset: Preset, document: String) throws {
        try database.execute(
            """
            UPDATE \(Self.tableName) SET
                name = ?,
                is_active = ?,
                document_version = ?,
                document = ?,
                revision = ?,
                updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(preset.name),
                .integer(preset.isActive ? 1 : 0),
                .integer(Int64(preset.documentVersion)),
                .text(document),
                .integer(Int64(preset.revision)),
                .text(preset.updatedAt),
                .text(preset.id)
            ]
        )
    }

    /// Clears the active flag on every preset of a piece except `keeping`.
    ///
    /// Run before setting the new active one, so the partial unique index is
    /// never momentarily violated inside the transaction.
    public func clearActive(forPieceID pieceID: String, except keeping: String? = nil) throws {
        var sql = "UPDATE \(Self.tableName) SET is_active = 0 WHERE piece_id = ? AND is_active = 1"
        var parameters: [SQLiteValue] = [.text(pieceID)]
        if let keeping {
            sql += " AND id <> ?"
            parameters.append(.text(keeping))
        }
        try database.execute(sql + ";", parameters)
    }

    public func delete(presetID: String) throws {
        try database.execute(
            "DELETE FROM \(Self.tableName) WHERE id = ?;",
            [.text(presetID)]
        )
    }

    /// Deletes every preset of one piece. The removal cascade's half (REQ-003).
    public func deletePresets(forPieceID pieceID: String) throws {
        try database.execute(
            "DELETE FROM \(Self.tableName) WHERE piece_id = ?;",
            [.text(pieceID)]
        )
    }

    // MARK: Line names

    /// The owner's renames for one piece, keyed by line.
    public func lineNames(forPieceID pieceID: String) throws -> [ScoreLineID: String] {
        var names: [ScoreLineID: String] = [:]
        for row in try database.query(
            "SELECT line_id, name FROM \(Self.lineNameTableName) WHERE piece_id = ?;",
            [.text(pieceID)]
        ) {
            guard let lineID = row.text("line_id"), let name = row.text("name") else {
                throw StoreError.presetRowUnreadable(
                    id: row.text("line_id") ?? "(no line)",
                    reason: "A stored line name is missing its line or its text."
                )
            }
            names[ScoreLineID(rawValue: lineID)] = name
        }
        return names
    }

    public func setLineName(
        _ name: String, forLineID lineID: ScoreLineID, pieceID: String, at timestamp: String
    ) throws {
        try database.execute(
            """
            INSERT INTO \(Self.lineNameTableName) (piece_id, line_id, name, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(piece_id, line_id) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at;
            """,
            [.text(pieceID), .text(lineID.rawValue), .text(name), .text(timestamp)]
        )
    }

    /// Forgets a rename, so the line goes back to the score's own name.
    public func clearLineName(forLineID lineID: ScoreLineID, pieceID: String) throws {
        try database.execute(
            "DELETE FROM \(Self.lineNameTableName) WHERE piece_id = ? AND line_id = ?;",
            [.text(pieceID), .text(lineID.rawValue)]
        )
    }

    /// Deletes every rename of one piece. The removal cascade's other half.
    public func deleteLineNames(forPieceID pieceID: String) throws {
        try database.execute(
            "DELETE FROM \(Self.lineNameTableName) WHERE piece_id = ?;",
            [.text(pieceID)]
        )
    }

    public func lineNameCount(forPieceID pieceID: String) throws -> Int {
        try database.scalarInt(
            "SELECT count(*) FROM \(Self.lineNameTableName) WHERE piece_id = ?;",
            [.text(pieceID)]
        ) ?? 0
    }

    // MARK: Decoding

    /// Rebuilds a preset from a row.
    ///
    /// A row that cannot be decoded throws rather than being skipped, for the
    /// same reason `SoundCatalog` does: a preset the owner made that silently
    /// stops appearing is the one failure this store must never have.
    static func preset(from row: SQLiteRow) throws -> Preset {
        func fail(_ reason: String) -> StoreError {
            StoreError.presetRowUnreadable(id: row.text("id") ?? "(no id)", reason: reason)
        }

        guard
            let id = row.text("id"),
            let pieceID = row.text("piece_id"),
            let name = row.text("name"),
            let isActive = row.integer("is_active"),
            let documentVersion = row.integer("document_version"),
            let document = row.text("document"),
            let revision = row.integer("revision"),
            let createdAt = row.text("created_at"),
            let updatedAt = row.text("updated_at")
        else {
            throw fail("Its stored form does not match this version of Synth.")
        }

        // The row records the document's format version and the document
        // records it too, so — exactly as `SoundCatalog` does — the two are made
        // to agree here. Otherwise the column is an unchecked copy and the
        // obvious future migration ("rewrite every preset below format version
        // N") would be a query nothing keeps honest.
        let bytes = Data(document.utf8)
        let content: PresetContent
        do {
            let declared = try PresetDocument.version(of: bytes)
            guard Int(documentVersion) == declared else {
                throw fail(
                    "Its row records preset format version \(documentVersion), "
                        + "but the document itself declares version \(declared)."
                )
            }
            content = try PresetDocument.content(from: bytes)
        } catch let error as StoreError {
            throw error
        } catch let error as PresetDocumentError {
            throw fail(error.description)
        } catch {
            throw fail(String(describing: error))
        }

        return Preset(
            id: id,
            pieceID: pieceID,
            name: name,
            isActive: isActive != 0,
            documentVersion: Int(documentVersion),
            revision: Int(revision),
            createdAt: createdAt,
            updatedAt: updatedAt,
            content: content
        )
    }
}
