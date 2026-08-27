import CryptoKit
import Foundation
import XCTest
@testable import SynthKit

/// The acceptance surface of issue #11 (LIB002).
///
/// Grouped by the criteria it proves: the three accepted formats, permanence
/// across a relaunch with the sources deleted, metadata with fallbacks,
/// deterministic duplicates, and the failure states that must leave the
/// library untouched.
final class MusicXMLImporterTests: XCTestCase {
    private var sandboxRoot: URL!
    private var sourceDirectory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        sourceDirectory = sandboxRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    private func importer() -> MusicXMLImporter {
        store.makeImporter()
    }

    // MARK: - Accepted formats

    func testImportsAnUncompressedMusicXMLFile() throws {
        let score = MusicXMLFixtures.score()
        let source = try writeFixture(score, named: "prelude.musicxml", in: sourceDirectory)

        let outcome = try importer().importPiece(from: source)

        guard case .imported(let piece) = outcome else {
            return XCTFail("Expected a new piece, got \(outcome)")
        }
        XCTAssertEqual(piece.title, "Prelude in C")
        XCTAssertEqual(piece.composer, "Johann Sebastian Bach")
        XCTAssertEqual(piece.workTitle, "Prelude in C")
        XCTAssertEqual(piece.workNumber, "BWV 846")
        XCTAssertEqual(piece.sourceFileName, "prelude.musicxml")
        XCTAssertEqual(piece.sourceFormat, .musicXML)
        XCTAssertEqual(piece.contentByteCount, score.count)
        XCTAssertEqual(try store.pieceCount(), 1)

        XCTAssertEqual(
            try store.pieceContent.read(named: piece.contentFileName),
            score,
            "An uncompressed source must be stored byte-for-byte"
        )
    }

    func testImportsAPlainXMLFile() throws {
        let score = MusicXMLFixtures.score(workTitle: "Sonata", workNumber: nil)
        let source = try writeFixture(score, named: "sonata.xml", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.title, "Sonata")
        XCTAssertEqual(piece.sourceFormat, .musicXML)
        XCTAssertEqual(try store.pieceContent.read(named: piece.contentFileName), score)
    }

    func testImportsACompressedMXLFileAndStoresTheRootfileVerbatim() throws {
        let score = MusicXMLFixtures.score(workTitle: "Fugue in D", composer: "Bach")
        let archive = MusicXMLFixtures.compressedScore(score: score, rootfilePath: "Fugue.xml")
        let source = try writeFixture(archive, named: "fugue.mxl", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.title, "Fugue in D")
        XCTAssertEqual(piece.composer, "Bach")
        XCTAssertEqual(piece.sourceFormat, .compressedMusicXML)
        XCTAssertEqual(
            try store.pieceContent.read(named: piece.contentFileName),
            score,
            "The stored content must be the uncompressed rootfile, byte-for-byte"
        )
        XCTAssertEqual(piece.contentSHA256, Self.digest(score))
    }

    func testImportsACompressedFileWhoseEntriesAreStoredRatherThanDeflated() throws {
        let score = MusicXMLFixtures.score(workTitle: "Stored Entry")
        let archive = MusicXMLFixtures.compressedScore(score: score, deflateScore: false)
        let source = try writeFixture(archive, named: "stored.mxl", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.title, "Stored Entry")
        XCTAssertEqual(try store.pieceContent.read(named: piece.contentFileName), score)
    }

    func testAnXMLFileThatIsReallyAZipIsImportedAsACompressedContainer() throws {
        // Notation apps do mislabel exports; the bytes are the truth.
        let score = MusicXMLFixtures.score(workTitle: "Mislabelled")
        let archive = MusicXMLFixtures.compressedScore(score: score)
        let source = try writeFixture(archive, named: "mislabelled.xml", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.sourceFormat, .compressedMusicXML)
        XCTAssertEqual(try store.pieceContent.read(named: piece.contentFileName), score)
    }

    // MARK: - Permanence (the headline acceptance criterion)

    func testImportedPiecesSurviveDeletingTheSourcesAndReopeningTheLibrary() throws {
        let plainScore = MusicXMLFixtures.score(workTitle: "Prelude in C", composer: "J. S. Bach")
        let compressedScore = MusicXMLFixtures.score(workTitle: "Clair de lune", composer: "Claude Debussy")

        let plainSource = try writeFixture(plainScore, named: "prelude.musicxml", in: sourceDirectory)
        let compressedSource = try writeFixture(
            MusicXMLFixtures.compressedScore(score: compressedScore),
            named: "clair-de-lune.mxl",
            in: sourceDirectory
        )

        let first = try importer().importPiece(from: plainSource).piece
        let second = try importer().importPiece(from: compressedSource).piece

        // The originals go away, exactly as the acceptance criterion says.
        try FileManager.default.removeItem(at: plainSource)
        try FileManager.default.removeItem(at: compressedSource)
        store.close()

        let reopened = try LibraryStore.open(container: container, appVersion: "1.0 (2)")
        defer { reopened.close() }
        store = reopened

        let pieces = try reopened.pieces.allPieces()
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.title), ["Clair de lune", "Prelude in C"])
        XCTAssertEqual(pieces.map(\.composer), ["Claude Debussy", "J. S. Bach"])
        XCTAssertEqual(Set(pieces.map(\.id)), [first.id, second.id])

        XCTAssertEqual(try reopened.pieceContent.read(named: first.contentFileName), plainScore)
        XCTAssertEqual(try reopened.pieceContent.read(named: second.contentFileName), compressedScore)
        XCTAssertEqual(try reopened.pieceCount(), 2)
        XCTAssertEqual(try reopened.storedContentFileCount(), 2)
    }

    func testTheSourceFileIsNeverModified() throws {
        let score = MusicXMLFixtures.score()
        let source = try writeFixture(score, named: "readonly.musicxml", in: sourceDirectory)
        let attributesBefore = try FileManager.default.attributesOfItem(
            atPath: source.path(percentEncoded: false)
        )

        try importer().importPiece(from: source)

        XCTAssertEqual(try Data(contentsOf: source), score, "The source file's bytes changed")
        let attributesAfter = try FileManager.default.attributesOfItem(
            atPath: source.path(percentEncoded: false)
        )
        XCTAssertEqual(
            attributesBefore[.modificationDate] as? Date,
            attributesAfter[.modificationDate] as? Date,
            "The source file was rewritten"
        )
    }

    // MARK: - Metadata and its fallbacks

    func testAScoreWithNoMetadataAtAllFallsBackToTheFileName() throws {
        let bare = MusicXMLFixtures.score(
            workTitle: nil,
            workNumber: nil,
            composer: nil,
            includeDoctype: false
        )
        let source = try writeFixture(bare, named: "untitled sketch.musicxml", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.title, "untitled sketch")
        XCTAssertNil(piece.composer)
        XCTAssertNil(piece.workTitle)
        XCTAssertNil(piece.movementTitle)
    }

    func testTitleFallsBackToTheMovementTitleThenToACreditLine() throws {
        let movementOnly = MusicXMLFixtures.score(
            workTitle: nil,
            workNumber: nil,
            movementTitle: "Allegro con brio",
            composer: nil
        )
        let movementPiece = try importer()
            .importPiece(from: try writeFixture(movementOnly, named: "m.musicxml", in: sourceDirectory))
            .piece
        XCTAssertEqual(movementPiece.title, "Allegro con brio")
        XCTAssertEqual(movementPiece.movementTitle, "Allegro con brio")

        let creditOnly = MusicXMLFixtures.score(
            workTitle: nil,
            workNumber: nil,
            composer: nil,
            creditWords: ["Engraved Title", "subtitle"]
        )
        let creditPiece = try importer()
            .importPiece(from: try writeFixture(creditOnly, named: "c.musicxml", in: sourceDirectory))
            .piece
        XCTAssertEqual(creditPiece.title, "Engraved Title")
    }

    func testWorkAndMovementFieldsAreCapturedSeparately() throws {
        let score = MusicXMLFixtures.score(
            workTitle: "Symphony No. 5",
            workNumber: "Op. 67",
            movementTitle: "Allegro con brio",
            movementNumber: "1",
            composer: "Ludwig van Beethoven"
        )
        let source = try writeFixture(score, named: "sym5.musicxml", in: sourceDirectory)

        let piece = try importer().importPiece(from: source).piece

        XCTAssertEqual(piece.title, "Symphony No. 5")
        XCTAssertEqual(piece.workTitle, "Symphony No. 5")
        XCTAssertEqual(piece.workNumber, "Op. 67")
        XCTAssertEqual(piece.movementTitle, "Allegro con brio")
        XCTAssertEqual(piece.movementNumber, "1")
        XCTAssertEqual(piece.composer, "Ludwig van Beethoven")
    }

    // MARK: - Duplicates

    func testReimportingTheSameFileReturnsTheExistingPieceAndChangesNothing() throws {
        let score = MusicXMLFixtures.score()
        let source = try writeFixture(score, named: "prelude.musicxml", in: sourceDirectory)

        let first = try importer().importPiece(from: source)
        let afterFirst = try LibrarySnapshot.capture(store)

        let second = try importer().importPiece(from: source)

        XCTAssertFalse(first.isDuplicate)
        XCTAssertTrue(second.isDuplicate, "A re-import must be reported as already in the library")
        XCTAssertEqual(second.piece, first.piece, "The existing entry must come back unchanged")
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(try store.storedContentFileCount(), 1)
        XCTAssertEqual(try LibrarySnapshot.capture(store), afterFirst)
    }

    func testTheSameScoreUnderADifferentFileNameIsStillTheSamePiece() throws {
        let score = MusicXMLFixtures.score()
        let first = try importer()
            .importPiece(from: try writeFixture(score, named: "prelude.musicxml", in: sourceDirectory))
            .piece
        let second = try importer()
            .importPiece(from: try writeFixture(score, named: "prelude-copy.xml", in: sourceDirectory))

        XCTAssertTrue(second.isDuplicate)
        XCTAssertEqual(second.piece.id, first.id)
        XCTAssertEqual(
            second.piece.sourceFileName,
            "prelude.musicxml",
            "The first import's provenance must not be overwritten by a later duplicate"
        )
        XCTAssertEqual(try store.pieceCount(), 1)
    }

    func testTwoDifferentScoresAreTwoPieces() throws {
        let firstSource = try writeFixture(
            MusicXMLFixtures.score(workTitle: "One"),
            named: "one.musicxml",
            in: sourceDirectory
        )
        let secondSource = try writeFixture(
            MusicXMLFixtures.score(workTitle: "Two"),
            named: "two.musicxml",
            in: sourceDirectory
        )

        let first = try importer().importPiece(from: firstSource).piece
        let second = try importer().importPiece(from: secondSource).piece

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.contentFileName, second.contentFileName)
        XCTAssertEqual(try store.pieceCount(), 2)
        XCTAssertEqual(try store.storedContentFileCount(), 2)
    }

    // MARK: - Failure states leave the library unchanged

    func testACorruptScoreIsRejectedByNameAndLeavesTheLibraryByteIdentical() throws {
        try importer().importPiece(
            from: try writeFixture(
                MusicXMLFixtures.score(workTitle: "Already Here"),
                named: "already-here.musicxml",
                in: sourceDirectory
            )
        )
        let before = try LibrarySnapshot.capture(store)

        let corrupt = Data("<?xml version=\"1.0\"?>\n<score-partwise><part-list></score-partwise>".utf8)
        let source = try writeFixture(corrupt, named: "damaged.musicxml", in: sourceDirectory)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.notWellFormedXML(let fileName, let reason, _, _) = error else {
                return XCTFail("Expected notWellFormedXML, got \(error)")
            }
            XCTAssertEqual(fileName, "damaged.musicxml")
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(
                (error as? ImportError)?.errorDescription?.contains("damaged.musicxml") == true,
                "The owner-facing message must name the file"
            )
        }

        XCTAssertEqual(try LibrarySnapshot.capture(store), before)
        XCTAssertEqual(try store.pieceCount(), 1)
    }

    func testWellFormedXMLThatIsNotAScoreIsRejected() throws {
        let notAScore = Data("<?xml version=\"1.0\"?>\n<opus><opus-link/></opus>".utf8)
        let source = try writeFixture(notAScore, named: "collection.musicxml", in: sourceDirectory)
        let before = try LibrarySnapshot.capture(store)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.notAMusicXMLScore(let fileName, let rootElement) = error else {
                return XCTFail("Expected notAMusicXMLScore, got \(error)")
            }
            XCTAssertEqual(fileName, "collection.musicxml")
            XCTAssertEqual(rootElement, "opus")
        }
        XCTAssertEqual(try LibrarySnapshot.capture(store), before)
    }

    func testATruncatedCompressedFileIsRejectedAndLeavesTheLibraryByteIdentical() throws {
        let archive = MusicXMLFixtures.compressedScore()
        let truncated = archive.prefix(archive.count / 2)
        let source = try writeFixture(Data(truncated), named: "truncated.mxl", in: sourceDirectory)
        let before = try LibrarySnapshot.capture(store)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.compressedContainerUnreadable(let fileName, let reason) = error else {
                return XCTFail("Expected compressedContainerUnreadable, got \(error)")
            }
            XCTAssertEqual(fileName, "truncated.mxl")
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(try LibrarySnapshot.capture(store), before)
    }

    func testACompressedFileWithNoContainerDescriptorIsRejected() throws {
        let archive = ZipBuilder.archive([
            .init(name: "score.xml", data: MusicXMLFixtures.score(), deflate: true)
        ])
        let source = try writeFixture(archive, named: "no-descriptor.mxl", in: sourceDirectory)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.containerDescriptorMissing(let fileName, let entryName) = error else {
                return XCTFail("Expected containerDescriptorMissing, got \(error)")
            }
            XCTAssertEqual(fileName, "no-descriptor.mxl")
            XCTAssertEqual(entryName, "META-INF/container.xml")
        }
        XCTAssertEqual(try store.pieceCount(), 0)
    }

    func testACompressedFileWhoseRootfileIsMissingIsRejected() throws {
        let archive = MusicXMLFixtures.compressedScore(
            rootfilePath: "score.xml",
            descriptor: MusicXMLFixtures.containerDescriptor(rootfilePath: "elsewhere.xml")
        )
        let source = try writeFixture(archive, named: "dangling.mxl", in: sourceDirectory)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.containerRootfileUnusable(let fileName, let reason) = error else {
                return XCTFail("Expected containerRootfileUnusable, got \(error)")
            }
            XCTAssertEqual(fileName, "dangling.mxl")
            XCTAssertTrue(reason.contains("elsewhere.xml"), "The reason must name the missing entry: \(reason)")
        }
    }

    func testAnMXLThatIsNotAZipIsRejected() throws {
        let source = try writeFixture(
            MusicXMLFixtures.score(),
            named: "plain-in-disguise.mxl",
            in: sourceDirectory
        )

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.compressedContainerUnreadable(let fileName, _) = error else {
                return XCTFail("Expected compressedContainerUnreadable, got \(error)")
            }
            XCTAssertEqual(fileName, "plain-in-disguise.mxl")
        }
    }

    func testAnUnsupportedExtensionIsRejectedBeforeTheFileIsEvenRead() throws {
        let source = try writeFixture(Data("not music".utf8), named: "notes.txt", in: sourceDirectory)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.unsupportedFileType(let fileName, let fileExtension) = error else {
                return XCTFail("Expected unsupportedFileType, got \(error)")
            }
            XCTAssertEqual(fileName, "notes.txt")
            XCTAssertEqual(fileExtension, "txt")
        }
    }

    func testAnOversizedFileIsRejectedWithoutBeingReadIntoMemory() throws {
        // A sparse file: 1 GiB of declared length, no allocated blocks. If the
        // limit were checked after the read, this test would need a gigabyte.
        let source = sourceDirectory.appending(path: "enormous.musicxml")
        FileManager.default.createFile(atPath: source.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.sourceTooLarge(let fileName, let byteCount, let limit) = error else {
                return XCTFail("Expected sourceTooLarge, got \(error)")
            }
            XCTAssertEqual(fileName, "enormous.musicxml")
            XCTAssertEqual(byteCount, 1 << 30)
            XCTAssertEqual(limit, MusicXMLImporter.maximumSourceByteCount)
        }
        XCTAssertEqual(try store.pieceCount(), 0)
    }

    func testAnEmptyFileIsRejected() throws {
        let source = try writeFixture(Data(), named: "empty.musicxml", in: sourceDirectory)

        XCTAssertThrowsError(try importer().importPiece(from: source)) { error in
            guard case ImportError.emptySource(let fileName) = error else {
                return XCTFail("Expected emptySource, got \(error)")
            }
            XCTAssertEqual(fileName, "empty.musicxml")
        }
    }

    func testAMissingFileIsRejectedByName() throws {
        let missing = sourceDirectory.appending(path: "gone.musicxml")

        XCTAssertThrowsError(try importer().importPiece(from: missing)) { error in
            guard case ImportError.unreadableSource(let fileName, let reason) = error else {
                return XCTFail("Expected unreadableSource, got \(error)")
            }
            XCTAssertEqual(fileName, "gone.musicxml")
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: - Atomicity

    func testAFullDiskDuringTheContentWriteLeavesNoPartialImport() throws {
        try importer().importPiece(
            from: try writeFixture(
                MusicXMLFixtures.score(workTitle: "Already Here"),
                named: "already-here.musicxml",
                in: sourceDirectory
            )
        )
        let before = try LibrarySnapshot.capture(store)

        let failing = MusicXMLImporter(
            catalog: store.pieces,
            contentStore: FullDiskContentStore(directoryURL: container.piecesURL)
        )
        let source = try writeFixture(
            MusicXMLFixtures.score(workTitle: "Never Arrives"),
            named: "never-arrives.musicxml",
            in: sourceDirectory
        )

        XCTAssertThrowsError(try failing.importPiece(from: source)) { error in
            guard case ImportError.contentWriteFailed(let fileName, let reason) = error else {
                return XCTFail("Expected contentWriteFailed, got \(error)")
            }
            XCTAssertEqual(fileName, "never-arrives.musicxml")
            XCTAssertTrue(reason.contains("space"), "The reason must be the real disk error: \(reason)")
        }

        XCTAssertEqual(try LibrarySnapshot.capture(store), before, "The library must be byte-identical")
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(try store.storedContentFileCount(), 1)
    }

    func testACatalogFailureAfterTheContentWriteRemovesTheOrphanedFile() throws {
        let before = try LibrarySnapshot.capture(store)

        let refusing = InsertRefusingCatalog(wrapping: store.pieces)
        let failing = MusicXMLImporter(catalog: refusing, contentStore: store.pieceContent)
        let source = try writeFixture(
            MusicXMLFixtures.score(workTitle: "Rolled Back"),
            named: "rolled-back.musicxml",
            in: sourceDirectory
        )

        XCTAssertThrowsError(try failing.importPiece(from: source)) { error in
            guard case ImportError.catalogWriteFailed(let fileName, _) = error else {
                return XCTFail("Expected catalogWriteFailed, got \(error)")
            }
            XCTAssertEqual(fileName, "rolled-back.musicxml")
        }

        XCTAssertEqual(refusing.insertAttempts, 1)
        XCTAssertEqual(
            try store.storedContentFileCount(),
            0,
            "The content written before the failed record must be removed"
        )
        XCTAssertEqual(try LibrarySnapshot.capture(store), before, "The library must be byte-identical")
    }

    func testEveryImportErrorIsOwnerReadableAndNamesItsFile() {
        let errors: [ImportError] = [
            .unreadableSource(fileName: "a.musicxml", reason: "The file does not exist."),
            .unsupportedFileType(fileName: "a.pdf", fileExtension: "pdf"),
            .sourceTooLarge(fileName: "a.musicxml", byteCount: 200_000_000, limit: 67_108_864),
            .emptySource(fileName: "a.musicxml"),
            .compressedContainerUnreadable(fileName: "a.mxl", reason: "the archive is truncated"),
            .containerDescriptorMissing(fileName: "a.mxl", entryName: "META-INF/container.xml"),
            .containerRootfileUnusable(fileName: "a.mxl", reason: "it declares no rootfile"),
            .notWellFormedXML(fileName: "a.musicxml", reason: "Opening and ending tag mismatch", line: 12, column: 4),
            .notAMusicXMLScore(fileName: "a.musicxml", rootElement: "html"),
            .contentWriteFailed(fileName: "a.musicxml", reason: "The disk is full."),
            .catalogWriteFailed(fileName: "a.musicxml", reason: "The disk is full.")
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) has no owner-facing description")
            XCTAssertTrue(
                description.contains(error.fileName),
                "\(error) does not name its file: \(description)"
            )
            XCTAssertNotNil(error.recoverySuggestion, "\(error) has no recovery suggestion")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
