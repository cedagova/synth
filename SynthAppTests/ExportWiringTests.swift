import XCTest
@testable import Synth
import SynthKit

/// The join between the open piece and the export (REQ-026), at the level where
/// it is actually made.
///
/// **This suite exists for the reason `AppModelWiringTests` exists.** The
/// increment-004 effort review found that `AppModel`'s closure wiring was proved
/// nowhere: each end was covered and the line joining them was not, so deleting
/// it would have passed every test while the feature quietly stopped working.
/// `ExportModel` has the same shape — three closures installed by
/// `PlaybackModel.wireExport()` — so the same gap is closed here rather than
/// reopened.
///
/// Everything runs against a real store in a temporary container, driven through
/// the same methods the menu command and the sheet call. The exporter itself is
/// `SynthKit`'s and is proved there; what these tests can prove and
/// `AudioExportTests` cannot is that the app hands it *this piece's* timeline,
/// *this piece's* preset, and a Cancel button that reaches a render already in
/// flight on another thread.
@MainActor
final class ExportWiringTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var model: AppModel!
    private var exports: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ExportWiringTests-\(UUID().uuidString)")
        exports = directory.appending(path: "exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        container = AppContainer(rootURL: directory.appending(path: "container"))
        model = AppModel(container: container)
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

    // MARK: The fixture

    /// A two-part score: long enough that a render takes several blocks, short
    /// enough that the whole suite stays quick.
    private static func score(measureCount: Int) -> String {
        let notes = (0..<4).map { index in
            """
            <note>
              <pitch><step>\(["C", "E", "G", "A"][index])</step><octave>4</octave></pitch>
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

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>Export Fixture</work-title></work>
              <part-list>
                <score-part id="P1"><part-name>Flute</part-name></score-part>
              </part-list>
              <part id="P1">
            \(measures)
              </part>
            </score-partwise>
            """
    }

    @discardableResult
    private func openPreparedPiece(measureCount: Int = 2) async throws -> PlaybackModel {
        let source = directory.appending(path: "fixture-\(measureCount).musicxml")
        try Data(Self.score(measureCount: measureCount).utf8).write(to: source)

        let library = try XCTUnwrap(model.library, "The library model should exist once open")
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(
            library.pieces.first { $0.id != model.playback?.piece.id } ?? library.pieces.first,
            "The fixture should have imported"
        )

        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback, "Opening a piece should make a transport")
        await playback.prepare()
        XCTAssertTrue(playback.assignment.isReady, "The piece should have resolved lines")
        // CD quality unless a test says otherwise, so a comparison against an
        // offline render is a comparison of the same rate and depth. The app's
        // own default is 48 kHz / 24-bit; `testEachFormatAndQualityChoice…`
        // covers that it reaches the file.
        playback.export.settings = .cdQuality
        return playback
    }

    /// The sheet's Export button, with the save panel answered by a fixed URL.
    ///
    /// The panel is the one step a test cannot drive — under the sandbox it is
    /// another process's window — so it is the one step replaced. Everything
    /// after the choice, including `chooseDestinationAndStart`, is the shipped
    /// path.
    private func exportAndWait(
        _ playback: PlaybackModel, to url: URL, timeout: TimeInterval = 120
    ) async throws -> AudioExportResult {
        playback.export.chooseDestination = { _, _ in url }
        playback.export.chooseDestinationAndStart()
        return try await waitForFinish(playback, timeout: timeout)
    }

    private func waitForFinish(
        _ playback: PlaybackModel, timeout: TimeInterval
    ) async throws -> AudioExportResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch playback.export.phase {
            case .finished(let result):
                return result
            case .failed(let failure):
                throw ExportDidNotFinish(reason: failure.summary)
            case .ready, .exporting:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw ExportDidNotFinish(reason: "the export never left \(playback.export.phase)")
    }

    private struct ExportDidNotFinish: Error, CustomStringConvertible {
        let reason: String
        var description: String { "The export did not finish: \(reason)" }
    }

    // MARK: The closures exist at all

    /// The cheapest half of the guard, and the one that catches a deletion.
    func testOpeningAPieceInstallsEveryExportConnection() async throws {
        let playback = try await openPreparedPiece()

        XCTAssertEqual(
            playback.export.pieceTitle, playback.piece.title,
            "The export must know which piece it is exporting, or every file is named wrong."
        )
        XCTAssertEqual(
            playback.export.presetName(), playback.assignment.activePreset?.name,
            "The preset name has to reach the export, or the suggested file name loses it."
        )
        XCTAssertNotNil(
            playback.export.makeRequest(.cdQuality),
            "The request builder has to reach this piece, or every export fails as empty."
        )
    }

    /// A piece that has not finished opening yet has nothing to export, and says
    /// so rather than writing an empty file.
    func testAPieceThatIsNotReadyYetExportsNothingAndSaysWhy() async throws {
        let source = directory.appending(path: "unready.musicxml")
        try Data(Self.score(measureCount: 1).utf8).write(to: source)
        let library = try XCTUnwrap(model.library)
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first)

        // Opened but deliberately never prepared: no timeline, no preset.
        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback)
        XCTAssertNil(playback.export.makeRequest(.cdQuality))

        let url = exports.appending(path: "unready.wav")
        playback.export.chooseDestination = { _, _ in url }
        playback.export.chooseDestinationAndStart()

        guard case .failed(let failure) = playback.export.phase else {
            return XCTFail("Expected a clear failure, got \(playback.export.phase)")
        }
        XCTAssertFalse(failure.wasCancelled)
        XCTAssertEqual(failure.summary, "This piece has nothing to export yet.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "Nothing should have been written."
        )
    }

    // MARK: An export is of this piece, this preset, this humanization

    /// The end-to-end claim: pressing Export in the app writes a real file whose
    /// audio equals an offline render of the live path for that piece.
    ///
    /// This is the app-level half of REQ-026. `AudioExportTests` proves the
    /// exporter's output equals `renderTimelineOffline`; only this can prove the
    /// app hands the exporter the timeline it is actually playing.
    func testExportingTheOpenPieceWritesTheLivePathsAudio() async throws {
        let playback = try await openPreparedPiece()
        let url = exports.appending(path: "open-piece.wav")

        let result = try await exportAndWait(playback, to: url)
        XCTAssertEqual(result.url, url.standardizedFileURL)
        XCTAssertGreaterThan(result.frameCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        // The live path, rendered independently from the model's own timeline
        // and its own resolved preset.
        let timeline = try XCTUnwrap(playback.timeline)
        let request = try XCTUnwrap(
            playback.assignment.exportRequest(timeline: timeline, settings: .cdQuality)
        )
        let live = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: request.voices
        )
        let writer = AudioFileWriter(settings: .cdQuality, frameCount: Int64(live.frameCount))
        let expected = writer.header() + writer.encode(left: live.left[...], right: live.right[...])

        XCTAssertEqual(
            try Data(contentsOf: url), expected,
            "The app's export is not an offline render of the piece it is playing."
        )
    }

    /// Exporting the same open piece twice, unchanged, writes identical files.
    func testExportingTheOpenPieceTwiceUnchangedProducesIdenticalFiles() async throws {
        let playback = try await openPreparedPiece()

        let first = exports.appending(path: "twice-a.wav")
        let second = exports.appending(path: "twice-b.wav")
        _ = try await exportAndWait(playback, to: first)
        _ = try await exportAndWait(playback, to: second)

        XCTAssertEqual(
            try Data(contentsOf: first), try Data(contentsOf: second),
            "Two exports of the unchanged open piece differed."
        )
    }

    /// Turning humanization off between two exports changes the file, and the
    /// second file matches the literal realization the transport now holds.
    ///
    /// The wiring claim underneath: the export reads
    /// `PlaybackModel.timeline`, which humanization re-realizes, rather than a
    /// timeline captured when the piece opened.
    func testTurningHumanizationOffChangesWhatIsExported() async throws {
        let playback = try await openPreparedPiece(measureCount: 4)

        await playback.setHumanizationEnabled(true)
        let humanized = exports.appending(path: "humanized.wav")
        _ = try await exportAndWait(playback, to: humanized)

        await playback.setHumanizationEnabled(false)
        XCTAssertTrue(playback.humanization.isLiteral)
        let literal = exports.appending(path: "literal.wav")
        _ = try await exportAndWait(playback, to: literal)

        XCTAssertNotEqual(
            try Data(contentsOf: humanized), try Data(contentsOf: literal),
            "Turning humanization off did not change the export, so it is not reading the "
                + "timeline the transport re-realized."
        )

        let timeline = try XCTUnwrap(playback.timeline)
        let request = try XCTUnwrap(
            playback.assignment.exportRequest(timeline: timeline, settings: .cdQuality)
        )
        let live = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: 44_100, voices: request.voices
        )
        let writer = AudioFileWriter(settings: .cdQuality, frameCount: Int64(live.frameCount))
        XCTAssertEqual(
            try Data(contentsOf: literal),
            writer.header() + writer.encode(left: live.left[...], right: live.right[...]),
            "The literal export does not match live playback of the literal state."
        )
    }

    /// Muting a line in the mixer mutes it in the export.
    ///
    /// The mix is the other half of "the active preset": an export of the piece
    /// but not of the owner's balance would satisfy no one.
    func testMutingALineInTheMixerIsHeardInTheExport() async throws {
        let playback = try await openPreparedPiece()
        let line = try XCTUnwrap(playback.assignment.lines.first).lineID

        let full = exports.appending(path: "unmuted.wav")
        _ = try await exportAndWait(playback, to: full)

        playback.assignment.setMuted(true, forLine: line)
        XCTAssertTrue(
            try XCTUnwrap(playback.assignment.lines.first { $0.lineID == line }).mixer.isMuted
        )

        let muted = exports.appending(path: "muted.wav")
        let result = try await exportAndWait(playback, to: muted)

        XCTAssertNotEqual(
            try Data(contentsOf: full), try Data(contentsOf: muted),
            "Muting the only line did not change the export."
        )
        XCTAssertLessThan(
            result.peakLevel, 0.001,
            "Muting the only line should have exported silence; peak was \(result.peakLevel)."
        )
    }

    // MARK: Format, quality and naming

    /// The sheet's format choice reaches the file, and the file opens.
    func testEachFormatAndQualityChoiceReachesTheWrittenFile() async throws {
        let playback = try await openPreparedPiece()

        for settings in [
            AudioExportSettings.cdQuality,
            AudioExportSettings(format: .aiff, sampleRate: .rate48000, bitDepth: .bits24)
        ] {
            playback.export.settings = settings
            let url = exports.appending(
                path: "choice-\(settings.format.rawValue)-\(settings.bitDepth.rawValue).\(settings.format.fileExtension)"
            )
            let result = try await exportAndWait(playback, to: url)

            XCTAssertEqual(result.settings, settings)
            XCTAssertEqual(
                Int64(try Data(contentsOf: url).count), result.byteCount,
                "\(settings.displayName): the file on disk is not the size the result reports."
            )
        }
    }

    /// The suggested file name follows the format picker and names the preset.
    func testTheSuggestedFileNameFollowsThePieceThePresetAndTheFormat() async throws {
        let playback = try await openPreparedPiece()
        let preset = try XCTUnwrap(playback.assignment.activePreset).name

        playback.export.settings.format = .wav
        XCTAssertEqual(
            playback.export.suggestedFileName, "\(playback.piece.title) — \(preset).wav"
        )
        playback.export.settings.format = .aiff
        XCTAssertTrue(playback.export.suggestedFileName.hasSuffix(".aiff"))
    }

    // MARK: Cancel, from the main actor, against a real background render

    /// **The cancel path, end to end.** A render running on its own thread is
    /// stopped from the main actor, reports itself cancelled, and leaves neither
    /// the destination file nor a staged sibling.
    ///
    /// The piece is long enough that the render takes several blocks, and the
    /// cancel is sent as soon as the first progress step lands, so the render is
    /// genuinely in flight and has genuinely already written audio.
    func testCancellingFromTheMainActorStopsARunningExportAndLeavesNothing() async throws {
        let playback = try await openPreparedPiece(measureCount: 40)
        let url = exports.appending(path: "cancelled.wav")

        playback.export.chooseDestination = { _, _ in url }
        playback.export.chooseDestinationAndStart()

        // Wait for the render to be genuinely under way before pressing Cancel.
        var sawProgress = false
        for _ in 0..<400 {
            if case .exporting(let progress) = playback.export.phase, progress != nil {
                sawProgress = true
                break
            }
            if case .finished = playback.export.phase { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawProgress, "The export finished before it could be cancelled.")

        playback.export.cancel()

        var failure: ExportFailure?
        for _ in 0..<600 {
            if case .failed(let observed) = playback.export.phase {
                failure = observed
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let observed = try XCTUnwrap(failure, "The cancelled export never reported a result.")
        XCTAssertTrue(observed.wasCancelled, "The failure was not a cancellation: \(observed.summary)")
        XCTAssertEqual(playback.export.statusMessage, "Export cancelled. Nothing was written.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "A cancelled export left a file at the destination."
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exports.path(percentEncoded: false)),
            [],
            "A cancelled export left a staged file behind."
        )
    }

    /// Closing the piece stops a render that is still going.
    func testClosingThePieceStopsARunningExport() async throws {
        let playback = try await openPreparedPiece(measureCount: 40)
        let url = exports.appending(path: "abandoned.wav")

        playback.export.chooseDestination = { _, _ in url }
        playback.export.chooseDestinationAndStart()
        for _ in 0..<400 {
            if case .exporting(let progress) = playback.export.phase, progress != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        model.closePlayback()

        // The render notices between blocks and cleans up after itself; give it
        // the same window the cancel test does.
        var settled = false
        for _ in 0..<600 {
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
               (try? FileManager.default.contentsOfDirectory(
                   atPath: exports.path(percentEncoded: false)
               ))?.isEmpty == true,
               !playback.export.isExporting {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(
            settled,
            "Closing the piece left an export running or a file behind: "
                + "\((try? FileManager.default.contentsOfDirectory(atPath: exports.path(percentEncoded: false))) ?? [])"
        )
    }

    // MARK: The play-through caveat

    /// When the sound studio has taken the piece over, the sheet says the export
    /// is still of the preset — because at that moment live playback is not.
    func testTheSheetWarnsWhenPlayThroughMeansTheExportIsNotWhatYouHear() async throws {
        let playback = try await openPreparedPiece()
        XCTAssertNil(playback.export.caveat(), "There is nothing to warn about normally.")

        model.openSoundStudio()
        let studio = try XCTUnwrap(model.studio)
        studio.reload()
        studio.selection = try XCTUnwrap(studio.sounds.first).id
        studio.editor.startPlayingPieceThroughSound()

        let caveat = try XCTUnwrap(
            playback.export.caveat(),
            "Play-through makes live playback differ from the export; the sheet has to say so."
        )
        XCTAssertTrue(caveat.contains("preset"))

        studio.editor.stopPlayingPieceThroughSound()
        XCTAssertNil(playback.export.caveat())
    }
}
