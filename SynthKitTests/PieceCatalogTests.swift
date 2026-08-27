import Foundation
import XCTest
@testable import SynthKit

final class PieceCatalogTests: XCTestCase {
    private var sandboxRoot: URL!
    private var database: SQLiteDatabase!
    private var catalog: PieceCatalog!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        database = try SQLiteDatabase.open(at: sandboxRoot.appending(path: "library.sqlite"))
        try SchemaMigrator.migrate(database, appVersion: "1.0 (1)")
        catalog = PieceCatalog(database: database)
    }

    override func tearDownWithError() throws {
        database?.close()
        database = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    private func record(
        id: String = UUID().uuidString,
        title: String = "Prelude",
        composer: String? = "Bach",
        digest: String = String(repeating: "a", count: 64)
    ) -> PieceRecord {
        PieceRecord(
            id: id,
            title: title,
            composer: composer,
            workTitle: "Prelude",
            workNumber: "BWV 846",
            movementTitle: nil,
            movementNumber: nil,
            sourceFileName: "prelude.musicxml",
            sourceFormat: .musicXML,
            contentFileName: "\(id).musicxml",
            contentSHA256: digest,
            contentByteCount: 1234,
            importedAt: "2026-08-27T10:00:00Z"
        )
    }

    func testRoundTripsEveryField() throws {
        let original = record()
        try catalog.insert(original)

        let loaded = try XCTUnwrap(try catalog.piece(withID: original.id))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try catalog.piece(withContentSHA256: original.contentSHA256), original)
        XCTAssertEqual(try catalog.pieceCount(), 1)
    }

    func testOptionalFieldsRoundTripAsNil() throws {
        let sparse = PieceRecord(
            id: "piece-1",
            title: "untitled sketch",
            composer: nil,
            workTitle: nil,
            workNumber: nil,
            movementTitle: nil,
            movementNumber: nil,
            sourceFileName: "untitled sketch.musicxml",
            sourceFormat: .compressedMusicXML,
            contentFileName: "piece-1.musicxml",
            contentSHA256: String(repeating: "b", count: 64),
            contentByteCount: 10,
            importedAt: "2026-08-27T10:00:00Z"
        )
        try catalog.insert(sparse)

        XCTAssertEqual(try catalog.piece(withID: "piece-1"), sparse)
    }

    func testTheContentDigestIsUnique() throws {
        let digest = String(repeating: "c", count: 64)
        try catalog.insert(record(id: "one", digest: digest))

        XCTAssertThrowsError(try catalog.insert(record(id: "two", digest: digest))) { error in
            guard case StoreError.statementFailed = error else {
                return XCTFail("Expected statementFailed, got \(error)")
            }
        }
        XCTAssertEqual(try catalog.pieceCount(), 1)
    }

    func testTheContentFileNameIsUnique() throws {
        try catalog.insert(record(id: "one", digest: String(repeating: "d", count: 64)))

        var collision = record(id: "two", digest: String(repeating: "e", count: 64))
        collision = PieceRecord(
            id: collision.id,
            title: collision.title,
            composer: collision.composer,
            workTitle: collision.workTitle,
            workNumber: collision.workNumber,
            movementTitle: collision.movementTitle,
            movementNumber: collision.movementNumber,
            sourceFileName: collision.sourceFileName,
            sourceFormat: collision.sourceFormat,
            contentFileName: "one.musicxml",
            contentSHA256: collision.contentSHA256,
            contentByteCount: collision.contentByteCount,
            importedAt: collision.importedAt
        )

        XCTAssertThrowsError(try catalog.insert(collision))
        XCTAssertEqual(try catalog.pieceCount(), 1)
    }

    func testTheIdentifierIsUnique() throws {
        try catalog.insert(record(id: "same", digest: String(repeating: "f", count: 64)))

        XCTAssertThrowsError(
            try catalog.insert(record(id: "same", digest: String(repeating: "0", count: 64)))
        )
    }

    func testPiecesComeBackSortedByTitleCaseInsensitively() throws {
        try catalog.insert(record(id: "1", title: "zebra suite", digest: String(repeating: "1", count: 64)))
        try catalog.insert(record(id: "2", title: "Adagio", digest: String(repeating: "2", count: 64)))
        try catalog.insert(record(id: "3", title: "berceuse", digest: String(repeating: "3", count: 64)))

        XCTAssertEqual(try catalog.allPieces().map(\.title), ["Adagio", "berceuse", "zebra suite"])
    }

    func testAnUnknownPieceIsNilRatherThanAnError() throws {
        XCTAssertNil(try catalog.piece(withID: "missing"))
        XCTAssertNil(try catalog.piece(withContentSHA256: String(repeating: "9", count: 64)))
        XCTAssertEqual(try catalog.pieceCount(), 0)
        XCTAssertTrue(try catalog.allPieces().isEmpty)
    }

    func testARowThisBuildCannotDecodeIsALoudFailure() throws {
        try database.execute(
            """
            INSERT INTO pieces (
                id, title, composer, work_title, work_number, movement_title,
                movement_number, source_file_name, source_format,
                content_file_name, content_sha256, content_byte_count, imported_at
            ) VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text("future"),
                .text("From A Newer Build"),
                .text("future.musicxml"),
                .text("some-format-from-the-future"),
                .text("future.musicxml"),
                .text(String(repeating: "7", count: 64)),
                .integer(1),
                .text("2026-08-27T10:00:00Z")
            ]
        )

        XCTAssertThrowsError(try catalog.allPieces()) { error in
            guard case StoreError.pieceRowUnreadable(let id) = error else {
                return XCTFail("Expected pieceRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, "future")
        }
    }
}
