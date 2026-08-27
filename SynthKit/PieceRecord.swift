import Foundation

/// How a piece arrived in the library.
public enum PieceSourceFormat: String, Equatable, Sendable, CaseIterable {
    /// An uncompressed `.musicxml` or `.xml` score.
    case musicXML = "musicxml"

    /// A compressed `.mxl` container; the stored content is its rootfile.
    case compressedMusicXML = "mxl"
}

/// One imported piece, as the library knows it.
///
/// The record is *derived* data: everything here except `id`, `importedAt`,
/// and the source description can be recomputed from the stored verbatim
/// MusicXML. That is the point of AD4 — interpretation improves without a
/// re-import, because the original bytes never leave the container.
public struct PieceRecord: Equatable, Sendable, Identifiable {
    /// Stable library identity. Independent of the content so later features
    /// (metadata correction, re-derivation) never have to renumber a piece.
    public let id: String

    /// Owner-facing name. Never empty: falls back to the source file's name
    /// when the score declares no title at all.
    public let title: String

    /// `identification/creator[@type="composer"]`, when the score names one.
    public let composer: String?

    /// `work/work-title` and `work/work-number`, when present.
    public let workTitle: String?
    public let workNumber: String?

    /// `movement-title` and `movement-number`, when present.
    public let movementTitle: String?
    public let movementNumber: String?

    /// The imported file's name (not its path — the source location is the
    /// owner's business and is never retained).
    public let sourceFileName: String

    /// Which of the accepted formats the source file was.
    public let sourceFormat: PieceSourceFormat

    /// File name of the verbatim MusicXML inside the container's `pieces/`.
    public let contentFileName: String

    /// Lowercase hex SHA-256 of the stored verbatim MusicXML. The library's
    /// duplicate key, and an integrity check for later readers.
    public let contentSHA256: String

    /// Size of the stored verbatim MusicXML in bytes.
    public let contentByteCount: Int

    /// When the import committed, ISO 8601 UTC.
    public let importedAt: String

    public init(
        id: String,
        title: String,
        composer: String?,
        workTitle: String?,
        workNumber: String?,
        movementTitle: String?,
        movementNumber: String?,
        sourceFileName: String,
        sourceFormat: PieceSourceFormat,
        contentFileName: String,
        contentSHA256: String,
        contentByteCount: Int,
        importedAt: String
    ) {
        self.id = id
        self.title = title
        self.composer = composer
        self.workTitle = workTitle
        self.workNumber = workNumber
        self.movementTitle = movementTitle
        self.movementNumber = movementNumber
        self.sourceFileName = sourceFileName
        self.sourceFormat = sourceFormat
        self.contentFileName = contentFileName
        self.contentSHA256 = contentSHA256
        self.contentByteCount = contentByteCount
        self.importedAt = importedAt
    }
}
