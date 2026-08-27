import CryptoKit
import Foundation

/// What an accepted import did.
public enum PieceImportOutcome: Equatable, Sendable {
    /// A new piece was added.
    case imported(PieceRecord)

    /// The library already held this exact score. Nothing was written, and the
    /// existing entry is returned unchanged — re-importing never replaces or
    /// duplicates what is already there.
    case alreadyInLibrary(PieceRecord)

    /// The piece this import ended up pointing at, new or pre-existing.
    public var piece: PieceRecord {
        switch self {
        case .imported(let record), .alreadyInLibrary(let record):
            return record
        }
    }

    public var isDuplicate: Bool {
        if case .alreadyInLibrary = self { return true }
        return false
    }
}

/// Imports MusicXML into the permanent library.
///
/// The pipeline, in order, and why the order matters:
///
/// 1. read the source (never write to it, never leave it open);
/// 2. unwrap a `.mxl` container down to its rootfile;
/// 3. parse the XML — this both validates the file and reads its metadata;
/// 4. hash the content and ask the catalog whether the library already has it;
/// 5. write the verbatim bytes into the container atomically;
/// 6. insert the library record, rolling the file back if that fails.
///
/// Everything that can reject the file happens before step 5, so a rejected
/// import cannot have touched the library. Steps 5 and 6 are the only mutating
/// pair, and step 6 undoes step 5 on failure.
///
/// AD4: the stored bytes are the *source's* bytes, uncompressed but otherwise
/// untouched. Metadata is derived and re-derivable; the content is the record.
public struct MusicXMLImporter: Sendable {
    /// File extensions this build accepts, lowercased.
    public static let acceptedFileExtensions: Set<String> = ["musicxml", "xml", "mxl"]

    /// Largest source file this build will read. Engraved scores are measured
    /// in hundreds of kilobytes; this only exists to bound the damage a
    /// mistaken or hostile file can do.
    public static let maximumSourceByteCount = 64 * 1024 * 1024

    private let catalog: PieceCatalogWriting
    private let contentStore: PieceContentStoring
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> String

    /// The importer for an opened library.
    public init(store: LibraryStore) {
        self.init(catalog: store.pieces, contentStore: store.pieceContent)
    }

    /// Seams exist for the failure paths: a content store that fails like a
    /// full disk, and a catalog that fails after the content already landed.
    init(
        catalog: PieceCatalogWriting,
        contentStore: PieceContentStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.catalog = catalog
        self.contentStore = contentStore
        self.now = now
        self.makeIdentifier = makeIdentifier
    }

    /// Imports the file at `sourceURL`.
    ///
    /// - Returns: the new piece, or the existing one when the library already
    ///   holds this exact content.
    /// - Throws: `ImportError`, always naming the file and the reason. The
    ///   library is unchanged whenever this throws.
    @discardableResult
    public func importPiece(from sourceURL: URL) throws -> PieceImportOutcome {
        let fileName = sourceURL.lastPathComponent
        let fileExtension = sourceURL.pathExtension.lowercased()

        guard Self.acceptedFileExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFileType(fileName: fileName, fileExtension: fileExtension)
        }

        let sourceData = try readSource(at: sourceURL, fileName: fileName)
        let (verbatimXML, sourceFormat) = try scoreContent(
            from: sourceData,
            fileName: fileName,
            fileExtension: fileExtension
        )
        let metadata = try parseScore(verbatimXML, fileName: fileName)

        let digest = Self.sha256Hex(verbatimXML)
        if let existing = try lookUpDuplicate(digest: digest, fileName: fileName) {
            return .alreadyInLibrary(existing)
        }

        let pieceID = makeIdentifier()
        let record = PieceRecord(
            id: pieceID,
            title: Self.title(from: metadata, sourceFileName: fileName),
            composer: metadata.composer,
            workTitle: metadata.workTitle,
            workNumber: metadata.workNumber,
            movementTitle: metadata.movementTitle,
            movementNumber: metadata.movementNumber,
            sourceFileName: fileName,
            sourceFormat: sourceFormat,
            contentFileName: Self.contentFileName(forPieceID: pieceID),
            contentSHA256: digest,
            contentByteCount: verbatimXML.count,
            importedAt: SchemaMigrator.timestamp(now())
        )

        do {
            try contentStore.write(verbatimXML, named: record.contentFileName)
        } catch {
            throw ImportError.contentWriteFailed(
                fileName: fileName,
                reason: (error as NSError).localizedDescription
            )
        }

        do {
            try catalog.insert(record)
        } catch {
            // Two imports of the same score can race past the lookup above.
            // The catalog's unique digest is the real guard, so a collision
            // here is a duplicate, not a failure — but the bytes this attempt
            // wrote are orphaned either way and must go.
            contentStore.removeIfPresent(named: record.contentFileName)

            if let existing = try? catalog.piece(withContentSHA256: digest) {
                return .alreadyInLibrary(existing)
            }
            throw ImportError.catalogWriteFailed(
                fileName: fileName,
                reason: (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
            )
        }

        return .imported(record)
    }

    // MARK: - Pipeline steps

    /// Reads the source, size-checked *before* the bytes are loaded.
    ///
    /// Checking after the read would mean a 10 GB file had already been pulled
    /// into memory by the time the limit rejected it, which is the opposite of
    /// what the limit is for.
    private func readSource(at sourceURL: URL, fileName: String) throws -> Data {
        let declaredByteCount: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: sourceURL.path(percentEncoded: false)
            )
            declaredByteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw ImportError.unreadableSource(
                fileName: fileName,
                reason: (error as NSError).localizedDescription
            )
        }

        guard declaredByteCount <= Self.maximumSourceByteCount else {
            throw ImportError.sourceTooLarge(
                fileName: fileName,
                byteCount: declaredByteCount,
                limit: Self.maximumSourceByteCount
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw ImportError.unreadableSource(
                fileName: fileName,
                reason: (error as NSError).localizedDescription
            )
        }

        guard !data.isEmpty else {
            throw ImportError.emptySource(fileName: fileName)
        }
        // The file can grow between the stat and the read; the limit is a
        // bound on what this process holds, so it is enforced on both.
        guard data.count <= Self.maximumSourceByteCount else {
            throw ImportError.sourceTooLarge(
                fileName: fileName,
                byteCount: data.count,
                limit: Self.maximumSourceByteCount
            )
        }
        return data
    }

    /// Resolves the source bytes down to the uncompressed score.
    ///
    /// The extension declares the format, but the bytes decide: a `.xml` that
    /// is really a ZIP is still a compressed container, and `.mxl` is refused
    /// when it is not one. Detecting it this way means a file that a notation
    /// app exported with the wrong extension still imports correctly.
    private func scoreContent(
        from sourceData: Data,
        fileName: String,
        fileExtension: String
    ) throws -> (Data, PieceSourceFormat) {
        guard ZipArchive.looksLikeZip(sourceData) else {
            guard fileExtension != "mxl" else {
                throw ImportError.compressedContainerUnreadable(
                    fileName: fileName,
                    reason: "it does not start with a ZIP header, so it is not a compressed MusicXML container"
                )
            }
            return (sourceData, .musicXML)
        }
        return (try unpackContainer(sourceData, fileName: fileName), .compressedMusicXML)
    }

    /// Unpacks a compressed container per the MusicXML container spec:
    /// `META-INF/container.xml` names the rootfile, and the rootfile is the
    /// score.
    private func unpackContainer(_ sourceData: Data, fileName: String) throws -> Data {
        let archive: ZipArchive
        do {
            archive = try ZipArchive.read(sourceData)
        } catch let error as ZipArchiveError {
            throw ImportError.compressedContainerUnreadable(
                fileName: fileName,
                reason: error.description
            )
        }

        guard let descriptorEntry = archive.entry(named: MusicXMLContainerDescriptor.entryName) else {
            throw ImportError.containerDescriptorMissing(
                fileName: fileName,
                entryName: MusicXMLContainerDescriptor.entryName
            )
        }

        let descriptorData: Data
        do {
            descriptorData = try archive.contents(of: descriptorEntry)
        } catch let error as ZipArchiveError {
            throw ImportError.compressedContainerUnreadable(fileName: fileName, reason: error.description)
        }

        let descriptor: MusicXMLContainerDescriptor
        do {
            descriptor = try MusicXMLContainerDescriptor.parse(descriptorData)
        } catch let error as MusicXMLParseError {
            throw ImportError.containerRootfileUnusable(
                fileName: fileName,
                reason: "its \(MusicXMLContainerDescriptor.entryName) is not readable (\(Self.describe(error)))"
            )
        }

        guard let scoreEntryName = descriptor.scoreEntryName else {
            throw ImportError.containerRootfileUnusable(
                fileName: fileName,
                reason: descriptor.rootfiles.isEmpty
                    ? "its \(MusicXMLContainerDescriptor.entryName) declares no rootfile"
                    : "its \(MusicXMLContainerDescriptor.entryName) declares no MusicXML rootfile"
            )
        }
        guard let scoreEntry = archive.entry(named: scoreEntryName) else {
            throw ImportError.containerRootfileUnusable(
                fileName: fileName,
                reason: "it declares “\(scoreEntryName)” as the score, but the archive has no such entry"
            )
        }

        do {
            return try archive.contents(of: scoreEntry)
        } catch let error as ZipArchiveError {
            throw ImportError.compressedContainerUnreadable(fileName: fileName, reason: error.description)
        }
    }

    private func parseScore(_ xml: Data, fileName: String) throws -> MusicXMLScoreMetadata {
        let metadata: MusicXMLScoreMetadata
        do {
            metadata = try MusicXMLScore.metadata(from: xml)
        } catch MusicXMLParseError.notWellFormed(let reason, let line, let column) {
            throw ImportError.notWellFormedXML(
                fileName: fileName,
                reason: reason,
                line: line,
                column: column
            )
        } catch MusicXMLParseError.noRootElement {
            throw ImportError.notWellFormedXML(
                fileName: fileName,
                reason: "the document contains no XML elements",
                line: 0,
                column: 0
            )
        }

        guard metadata.isMusicXMLScore else {
            throw ImportError.notAMusicXMLScore(
                fileName: fileName,
                rootElement: metadata.rootElement
            )
        }
        return metadata
    }

    private func lookUpDuplicate(digest: String, fileName: String) throws -> PieceRecord? {
        do {
            return try catalog.piece(withContentSHA256: digest)
        } catch {
            throw ImportError.catalogWriteFailed(
                fileName: fileName,
                reason: (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
            )
        }
    }

    // MARK: - Derivation

    /// The owner-facing title, with the fallbacks the issue calls for.
    ///
    /// Order: the work title, then the movement title, then the first credit
    /// line an engraver put on the page, then the source file's own name. A
    /// piece is never nameless and a missing field never fails an import.
    static func title(from metadata: MusicXMLScoreMetadata, sourceFileName: String) -> String {
        let candidates = [metadata.workTitle, metadata.movementTitle, metadata.creditWords.first]
        if let declared = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return declared
        }
        let stem = (sourceFileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? sourceFileName : stem
    }

    /// Content files are named after the piece, so the container stays
    /// navigable and one piece can never overwrite another's bytes.
    static func contentFileName(forPieceID id: String) -> String {
        "\(id).musicxml"
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: MusicXMLParseError) -> String {
        switch error {
        case .notWellFormed(let reason, let line, let column):
            return "\(reason) at line \(line), column \(column)"
        case .noRootElement:
            return "it contains no XML elements"
        }
    }
}
