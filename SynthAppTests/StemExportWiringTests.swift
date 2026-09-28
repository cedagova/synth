import XCTest
@testable import Synth
import SynthKit

/// The join between the open piece and "Export Stems…" (#90), proved the way
/// `ExportWiringTests` proves the mix export's: against a real store, through
/// the methods the menu and the sheet call, with only the system panels
/// replaced. `AudioStemExportTests` proves the stems themselves.
@MainActor
final class StemExportWiringTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var exports: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "StemExportWiringTests-\(UUID().uuidString)")
        exports = directory.appending(path: "stems")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        model = AppModel(container: AppContainer(rootURL: directory.appending(path: "container")))
        await model.bootstrap()
        guard model.store != nil else {
            return XCTFail("The store did not open; nothing below can be meaningful.")
        }
    }

    override func tearDown() async throws {
        model?.closePlayback()
        model = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: Fixture

    /// Two parts, so two lines and two stems.
    private static func score(measureCount: Int) -> String {
        func part(_ id: String, octave: Int) -> String {
            let notes = (0..<4).map { index in
                """
                <note>
                  <pitch><step>\(["C", "E", "G", "A"][index])</step><octave>\(octave)</octave></pitch>
                  <duration>4</duration><type>quarter</type>
                </note>
                """
            }.joined(separator: "\n")
            let measures = (1...measureCount).map { number in
                let attributes = number == 1
                    ? """
                      <attributes>
                        <divisions>4</divisions>
                        <key><fifths>0</fifths></key>
                        <time><beats>4</beats><beat-type>4</beat-type></time>
                        <clef><sign>G</sign><line>2</line></clef>
                      </attributes>
                      """
                    : ""
                return "<measure number=\"\(number)\">\(attributes)\(notes)</measure>"
            }.joined(separator: "\n")
            return "<part id=\"\(id)\">\(measures)</part>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>Stem Fixture</work-title></work>
              <part-list>
                <score-part id="P1"><part-name>Flute</part-name></score-part>
                <score-part id="P2"><part-name>Oboe</part-name></score-part>
              </part-list>
            \(part("P1", octave: 5))
            \(part("P2", octave: 4))
            </score-partwise>
            """
    }

    private func openPreparedPiece(measureCount: Int = 2) async throws -> PlaybackModel {
        let source = directory.appending(path: "stems-\(measureCount).musicxml")
        try Data(Self.score(measureCount: measureCount).utf8).write(to: source)
        let library = try XCTUnwrap(model.library)
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first)
        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback)
        await playback.prepare()
        XCTAssertEqual(playback.assignment.lines.count, 2, "The fixture should have two lines.")
        playback.stemExport.chooseFolder = { [exports] done in done(exports) }
        return playback
    }

    private func waitForOutcome(_ playback: PlaybackModel) async throws -> StemExportPhase {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            switch playback.stemExport.phase {
            case .finished, .failed: return playback.stemExport.phase
            case .ready, .exporting: try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw NSError(domain: "StemExportWiringTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The stem export never finished: \(playback.stemExport.phase)"
        ])
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: exports.path(percentEncoded: false)).sorted()
    }

    // MARK: Wiring

    /// Opening a piece installs the connection, and the sheet lists one stem
    /// per line named by piece and line.
    func testOpeningAPieceWiresStemsForEveryLine() async throws {
        let playback = try await openPreparedPiece()
        playback.stemExport.present()
        XCTAssertTrue(playback.stemExport.isPresented)
        XCTAssertEqual(
            playback.stemExport.plannedStems.map(\.lineID),
            playback.assignment.lines.map(\.lineID)
        )
        for (stem, line) in zip(playback.stemExport.plannedStems, playback.assignment.lines) {
            XCTAssertEqual(stem.fileName, "Stem Fixture — \(line.name).wav")
        }
        XCTAssertEqual(playback.stemExport.fileDescription, "WAV · 48 kHz · 32-bit float")
        XCTAssertTrue(playback.stemExport.canExport)
    }

    /// Choose Folder… writes one float file per line, and the mix export's
    /// own settings are untouched.
    func testExportingStemsWritesOneFloatFilePerLine() async throws {
        let playback = try await openPreparedPiece()
        playback.export.settings = .cdQuality
        playback.stemExport.settings.format = .aiff
        playback.stemExport.present()
        playback.stemExport.chooseFolderAndStart()

        guard case .finished(let result) = try await waitForOutcome(playback) else {
            return XCTFail("Expected a finished export, got \(playback.stemExport.phase)")
        }
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(try files(), playback.stemExport.plannedStems.map(\.fileName).sorted())
        XCTAssertTrue(result.files.allSatisfy { $0.encoding == .float32 && $0.url.pathExtension == "aiff" })
        XCTAssertEqual(playback.export.settings, .cdQuality, "Stems changed the mix export's settings.")
        XCTAssertEqual(playback.stemExport.statusMessage?.hasPrefix("Exported 2 stems"), true)
    }

    /// The owner's rename reaches the file name.
    func testARenamedLineNamesItsStem() async throws {
        let playback = try await openPreparedPiece()
        let line = try XCTUnwrap(playback.assignment.lines.first).lineID
        playback.assignment.beginLineRename(line)
        playback.assignment.lineNameDraft = "Solo/Flute"
        playback.assignment.commitLineRename()

        playback.stemExport.present()
        XCTAssertEqual(playback.stemExport.plannedStems.first?.fileName, "Stem Fixture — Solo-Flute.wav")
    }

    /// Everything muted: nothing to export, and the sheet says so.
    func testWithEveryLineMutedThereIsNothingToExport() async throws {
        let playback = try await openPreparedPiece()
        for line in playback.assignment.lines { playback.assignment.setMuted(true, forLine: line.lineID) }

        playback.stemExport.present()
        XCTAssertTrue(playback.stemExport.plannedStems.isEmpty)
        XCTAssertFalse(playback.stemExport.canExport)

        playback.stemExport.start(in: exports)
        guard case .failed(let failure) = playback.stemExport.phase else {
            return XCTFail("Expected a failure, got \(playback.stemExport.phase)")
        }
        XCTAssertEqual(failure.summary, AudioExportError.nothingAudible.errorDescription)
        XCTAssertEqual(try files(), [])
    }

    /// Soloing one line exports only that line.
    func testSoloingALineExportsOnlyThatLine() async throws {
        let playback = try await openPreparedPiece()
        let solo = try XCTUnwrap(playback.assignment.lines.last).lineID
        playback.assignment.setSoloed(true, forLine: solo)
        playback.stemExport.present()
        XCTAssertEqual(playback.stemExport.plannedStems.map(\.lineID), [solo])
    }

    /// An existing file is replaced only after the owner says so; declining
    /// changes nothing.
    func testExistingFilesAreReplacedOnlyAfterConfirmation() async throws {
        let playback = try await openPreparedPiece()
        playback.stemExport.present()
        let name = try XCTUnwrap(playback.stemExport.plannedStems.first).fileName
        let existing = exports.appending(path: name)
        try Data("keep".utf8).write(to: existing)

        var asked: [String] = []
        playback.stemExport.confirmReplacing = { names, _, done in
            asked = names
            done(false)
        }
        playback.stemExport.chooseFolderAndStart()
        XCTAssertEqual(asked, [name])
        XCTAssertEqual(playback.stemExport.phase, .ready, "Declining still started an export.")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertEqual(try files(), [name])

        playback.stemExport.confirmReplacing = { _, _, done in done(true) }
        playback.stemExport.chooseFolderAndStart()
        guard case .finished = try await waitForOutcome(playback) else {
            return XCTFail("Expected a finished export, got \(playback.stemExport.phase)")
        }
        XCTAssertNotEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertEqual(try files().count, 2)
    }

    /// Agreeing to replace one file is not agreement to replace another: if
    /// a second stem name exists by the time the export starts, the owner is
    /// asked again about the full list, and declining writes nothing.
    func testAFileThatAppearsAfterConfirmingIsAskedAboutAgain() async throws {
        let playback = try await openPreparedPiece()
        playback.stemExport.present()
        let names = playback.stemExport.plannedStems.map(\.fileName)
        let first = exports.appending(path: names[0])
        let second = exports.appending(path: names[1])
        try Data("one".utf8).write(to: first)

        var asked: [[String]] = []
        playback.stemExport.confirmReplacing = { [second] listed, _, done in
            asked.append(listed)
            if asked.count == 1 {
                // Arrives between the owner's answer and the export starting.
                try? Data("two".utf8).write(to: second)
                done(true)
            } else {
                done(false)
            }
        }
        playback.stemExport.chooseFolderAndStart()

        XCTAssertEqual(asked, [[names[0]], names])
        XCTAssertEqual(playback.stemExport.phase, .ready, "An export started without the second answer.")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    /// Cancel from the main actor stops a running batch and leaves no stems.
    func testCancellingARunningBatchLeavesNoStems() async throws {
        let playback = try await openPreparedPiece(measureCount: 40)
        playback.stemExport.present()
        playback.stemExport.chooseFolderAndStart()

        var sawProgress = false
        for _ in 0..<400 {
            if case .exporting(let progress) = playback.stemExport.phase, progress != nil {
                sawProgress = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawProgress, "The batch finished before it could be cancelled.")
        playback.stemExport.cancel()

        guard case .failed(let failure) = try await waitForOutcome(playback) else {
            return XCTFail("Expected a cancellation, got \(playback.stemExport.phase)")
        }
        XCTAssertTrue(failure.wasCancelled)
        XCTAssertEqual(playback.stemExport.statusMessage, "Stem export cancelled. Nothing was written.")
        XCTAssertEqual(try files(), [])
    }
}
