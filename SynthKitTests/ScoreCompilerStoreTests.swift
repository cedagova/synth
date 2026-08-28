import XCTest
@testable import SynthKit

/// The compiler against the real boundary it will live at: a piece imported
/// into a real `LibraryStore` container, then compiled out of it.
///
/// The unit tests above hand the compiler bytes directly. This suite proves
/// the path the app actually takes — import writes verbatim MusicXML into the
/// container, the catalog hands back a `PieceRecord`, the compiler reads that
/// record's content file — including across a close and reopen, which is
/// where a compiler that quietly depended on process state would show up.
final class ScoreCompilerStoreTests: XCTestCase {
    private var sandboxRoot: URL!
    private var container: AppContainer!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    /// Imports `data` as `fileName` and returns the resulting record.
    @discardableResult
    private func importPiece(
        _ data: Data,
        named fileName: String,
        into store: LibraryStore
    ) throws -> PieceRecord {
        let sourceURL = sandboxRoot.appending(path: fileName)
        try data.write(to: sourceURL)
        return try store.makeImporter().importPiece(from: sourceURL).piece
    }

    func testAnImportedPieceCompilesOutOfTheContainer() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        let record = try importPiece(
            MusicXMLScoreFixtures.keyboardFugueExposition(),
            named: "fugue.musicxml",
            into: store
        )
        let score = try ScoreCompiler().compile(piece: record, contentStore: store.pieceContent)

        XCTAssertEqual(score.pieceID, record.id)
        XCTAssertEqual(score.contentSHA256, record.contentSHA256)
        XCTAssertEqual(score.workTitle, "Fugue in C minor")
        XCTAssertEqual(score.lines.count, 4)
        XCTAssertEqual(score.playbackMeasures.count, 10)
    }

    /// The identity promise as the owner experiences it: quit the app, come
    /// back, and the presets still point at the same lines.
    func testLineIdentifiersSurviveClosingAndReopeningTheLibrary() throws {
        let firstStore = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        let record = try importPiece(
            MusicXMLScoreFixtures.stringQuartetMovement(),
            named: "quartet.musicxml",
            into: firstStore
        )
        let before = try ScoreCompiler().compile(piece: record, contentStore: firstStore.pieceContent)
        firstStore.close()

        let secondStore = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { secondStore.close() }
        let reloaded = try XCTUnwrap(try secondStore.allPieces().first)
        let after = try ScoreCompiler().compile(piece: reloaded, contentStore: secondStore.pieceContent)

        XCTAssertEqual(before.lines.map(\.id), after.lines.map(\.id))
        XCTAssertEqual(try before.canonicalData(), try after.canonicalData())
    }

    func testACompressedImportCompilesTheSameAsItsUncompressedTwin() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        let plain = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        let compressed = MusicXMLFixtures.compressedScore(score: plain)

        let record = try importPiece(compressed, named: "structure.mxl", into: store)
        XCTAssertEqual(record.sourceFormat, .compressedMusicXML)

        let fromStore = try ScoreCompiler().compile(piece: record, contentStore: store.pieceContent)
        let direct = try ScoreCompiler().compile(pieceID: record.id, musicXML: plain)
        XCTAssertEqual(try fromStore.canonicalData(), try direct.canonicalData())
    }

    func testAMissingContentFileFailsWithAReadableReasonRatherThanCrashing() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        let record = try importPiece(
            MusicXMLScoreFixtures.unsupportedMarking(),
            named: "marked.musicxml",
            into: store
        )
        store.pieceContent.removeIfPresent(named: record.contentFileName)

        XCTAssertThrowsError(
            try ScoreCompiler().compile(piece: record, contentStore: store.pieceContent)
        ) { error in
            guard case ScoreCompilationError.contentUnreadable = error else {
                return XCTFail("expected contentUnreadable, got \(error)")
            }
        }
    }

    /// The dense reference score, through the whole store path, with the
    /// numbers written down so a regression in size or shape is visible.
    func testTheOrchestralReferenceCompilesThroughTheStore() throws {
        let store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }

        let record = try importPiece(
            MusicXMLScoreFixtures.orchestralExcerpt(),
            named: "orchestral.musicxml",
            into: store
        )
        let score = try ScoreCompiler().compile(piece: record, contentStore: store.pieceContent)

        XCTAssertEqual(score.lines.count, 18)
        XCTAssertEqual(score.sourceMeasures.count, 32)
        XCTAssertEqual(score.playbackMeasures.count, 32)
        XCTAssertEqual(score.lines.reduce(0) { $0 + $1.notes.count }, 18 * 32 * 8)
        // ♩=144 is 416667 µs a quarter after rounding to whole microseconds;
        // 128 quarters of it is 53.333376 s, 43 µs above the exact 53⅓ s.
        XCTAssertEqual(score.totalMicroseconds, 128 * 416_667)
        XCTAssertEqual(score.totalMicroseconds, 53_333_376)
    }
}
