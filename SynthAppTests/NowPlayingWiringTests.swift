import MediaPlayer
import XCTest
@testable import Synth
import SynthKit

/// The media keys and Control Center, driving the open piece (#87).
///
/// Everything runs against a real store and a real `PlaybackModel`; only the
/// two MediaPlayer singletons are replaced, by `FakeCenters`, which records the
/// handler it was given and every publish. The handler is invoked exactly as
/// `SystemNowPlayingCenters` invokes it for a system command.
@MainActor
final class NowPlayingWiringTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var centers: FakeCenters!
    private var control: NowPlayingControl!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "NowPlayingWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(container: AppContainer(rootURL: directory.appending(path: "container")))
        await model.bootstrap()
        guard model.store != nil else {
            return XCTFail("The store did not open; nothing below can be meaningful.")
        }
        centers = FakeCenters()
        control = NowPlayingControl(centers: centers) { [weak model] in model?.playback }
        control.install()
    }

    override func tearDown() async throws {
        model?.closePlayback()
        model = nil
        control = nil
        centers = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: The fixture

    private static func score(measureCount: Int, composer: String?) -> String {
        let notes = ["C", "D", "E", "F"].map { step in
            """
            <note>
              <pitch><step>\(step)</step><octave>5</octave></pitch>
              <duration>4</duration><type>quarter</type>
            </note>
            """
        }.joined()
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
        let identification = composer.map {
            "<identification><creator type=\"composer\">\($0)</creator></identification>"
        } ?? ""

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>Now Playing Fixture \(measureCount)</work-title></work>
              \(identification)
              <part-list>
                <score-part id="P1"><part-name>Flute</part-name></score-part>
              </part-list>
              <part id="P1">
            \(measures)
              </part>
            </score-partwise>
            """
    }

    /// Opens (and, unless told not to, prepares) a fixture piece.
    @discardableResult
    private func openPiece(
        measureCount: Int = 8,
        composer: String? = "J. S. Bach",
        prepare: Bool = true
    ) async throws -> PlaybackModel {
        let source = directory.appending(path: "fixture-\(measureCount).musicxml")
        try Data(Self.score(measureCount: measureCount, composer: composer).utf8).write(to: source)

        let library = try XCTUnwrap(model.library, "The library model should exist once open")
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(
            library.pieces.first { $0.title == "Now Playing Fixture \(measureCount)" },
            "The fixture should have imported"
        )
        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback, "Opening a piece should make a transport")
        if prepare {
            await playback.prepare()
            XCTAssertTrue(playback.isReady, "The fixture should prepare")
        }
        return playback
    }

    /// Lets the observation's re-publish, which hops once through the main
    /// actor, run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func send(_ command: RemoteTransportCommand) throws -> MPRemoteCommandHandlerStatus {
        let handler = try XCTUnwrap(centers.handler, "install() should register the commands")
        return handler(command)
    }

    // MARK: Registration

    func testInstallRegistersOnceAndIsIdempotent() {
        control.install()
        control.install()
        XCTAssertEqual(centers.registrationCount, 1)
    }

    // MARK: No piece

    func testWithNoPieceEveryCommandHasNothingToControl() throws {
        let commands: [RemoteTransportCommand] = [
            .play, .pause, .togglePlayPause, .stop, .skipForward, .skipBackward,
            .changePlaybackPosition(seconds: 3),
        ]
        for command in commands {
            XCTAssertEqual(try send(command), .noActionableNowPlayingItem, "\(command)")
        }
        XCTAssertNil(centers.published.last ?? nil, "Nothing is published with no piece open")
    }

    func testAPieceStillPreparingHasNothingToControlYet() async throws {
        let playback = try await openPiece(prepare: false)
        XCTAssertFalse(playback.isReady)
        XCTAssertEqual(try send(.togglePlayPause), .noActionableNowPlayingItem)
    }

    // MARK: Handler → action

    /// The seeks first, while the graph has never run and the playhead is the
    /// model's own; then the transport, where `pause` has to wait for the
    /// render thread to confirm the play (as the transport's own button does).
    func testEachCommandReachesTheTransportActionItNames() async throws {
        let playback = try await openPiece()
        let total = playback.totalMicroseconds
        XCTAssertGreaterThan(total, 10_000_000, "The fixture must be longer than a skip")

        XCTAssertEqual(try send(.skipForward), .success)
        XCTAssertEqual(playback.positionMicroseconds, PlaybackModel.skipMicroseconds, "+5 s")
        XCTAssertEqual(try send(.skipForward), .success)
        XCTAssertEqual(try send(.skipBackward), .success)
        XCTAssertEqual(playback.positionMicroseconds, PlaybackModel.skipMicroseconds, "−5 s")

        XCTAssertEqual(try send(.changePlaybackPosition(seconds: 2.5)), .success)
        XCTAssertEqual(playback.positionMicroseconds, 2_500_000, "The scrubber seeks")

        XCTAssertEqual(try send(.changePlaybackPosition(seconds: 1_000_000)), .success)
        XCTAssertEqual(playback.positionMicroseconds, total, "A seek past the end clamps")
        XCTAssertEqual(try send(.changePlaybackPosition(seconds: 0)), .success)

        XCTAssertEqual(try send(.play), .success)
        XCTAssertEqual(playback.statusMessage, "Playing.", "play → play()")
        try await waitUntil { playback.isPlaying }

        XCTAssertEqual(try send(.pause), .success)
        XCTAssertEqual(playback.statusMessage, "Paused.", "pause → pause()")
        try await waitUntil { !playback.isPlaying }

        XCTAssertEqual(try send(.togglePlayPause), .success)
        XCTAssertEqual(playback.statusMessage, "Playing.", "toggle → togglePlayPause()")

        XCTAssertEqual(try send(.stop), .success)
        XCTAssertEqual(playback.statusMessage, "Stopped.", "stop → stop()")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for the render thread")
    }

    func testTheScrubberIsAnsweredWithWhereItLanded() async throws {
        _ = try await openPiece()
        XCTAssertEqual(try send(.changePlaybackPosition(seconds: 4)), .success)
        let info = try XCTUnwrap(centers.published.last ?? nil)
        XCTAssertEqual(info.elapsedSeconds, 4, accuracy: 0.000_001)
    }

    // MARK: Now Playing contents

    func testOpeningAPiecePublishesItBeforeItIsEverPlayed() async throws {
        let playback = try await openPiece()
        await settle()

        let info = try XCTUnwrap(centers.published.last ?? nil, "Published on open")
        XCTAssertEqual(info.title, playback.piece.title)
        XCTAssertEqual(info.composer, "J. S. Bach")
        XCTAssertEqual(info.durationSeconds, Double(playback.totalMicroseconds) / 1_000_000)
        XCTAssertEqual(info.elapsedSeconds, 0)
        XCTAssertFalse(info.isPlaying)
        XCTAssertEqual(info.rate, 0, "P84-1: not playing is rate 0")
    }

    func testThePublishedRateIsOneWhilePlayingAndZeroOtherwise() {
        let playing = NowPlayingInfo(
            title: "T", composer: nil, durationSeconds: 10, elapsedSeconds: 1, isPlaying: true
        )
        let paused = NowPlayingInfo(
            title: "T", composer: nil, durationSeconds: 10, elapsedSeconds: 1, isPlaying: false
        )
        XCTAssertEqual(playing.rate, 1.0)
        XCTAssertEqual(paused.rate, 0)
    }

    func testATempoChangeRepublishesDurationAndElapsedAtRateOne() async throws {
        let playback = try await openPiece()
        let fileLength = playback.totalMicroseconds
        playback.seek(toMicroseconds: fileLength / 2)
        await playback.setTempoPercent(50)
        await settle()

        let info = try XCTUnwrap(centers.published.last ?? nil)
        XCTAssertEqual(
            info.durationSeconds, Double(fileLength * 2) / 1_000_000,
            "Half speed doubles the published duration"
        )
        XCTAssertEqual(
            info.elapsedSeconds, Double(fileLength) / 1_000_000,
            "The same beat, now twice as far in"
        )
        XCTAssertFalse(info.isPlaying)
        XCTAssertEqual(info.rate, 0, "The tempo is never the published rate")
    }

    /// The playhead advancing is Control Center's to extrapolate; the ticker
    /// sampling it every frame must not republish.
    func testPlayingOnWithoutEventsDoesNotRepublish() async throws {
        let playback = try await openPiece()
        playback.play()
        try await Task.sleep(nanoseconds: 150_000_000)
        let before = centers.published.count
        let positionBefore = playback.positionMicroseconds

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(centers.published.count, before, "No event, so no publish")
        if playback.isPlaying {
            XCTAssertGreaterThan(playback.positionMicroseconds, positionBefore, "…while it played on")
            XCTAssertEqual((centers.published.last ?? nil)?.rate, 1.0)
        }
        playback.stop()
    }

    func testClosingThePieceClearsNowPlayingAndOpeningAnotherReplacesIt() async throws {
        let first = try await openPiece(measureCount: 8)
        await settle()
        XCTAssertEqual((centers.published.last ?? nil)?.title, first.piece.title)

        model.closePlayback()
        await settle()
        XCTAssertEqual(centers.published.last.map { $0 == nil }, true, "Close clears it")

        let second = try await openPiece(measureCount: 4, composer: nil)
        await settle()
        let info = try XCTUnwrap(centers.published.last ?? nil)
        XCTAssertEqual(info.title, second.piece.title)
        XCTAssertNil(info.composer)
    }

    // MARK: Export (P84-5)

    /// A render in flight is on its own offline engine; the remote commands
    /// reach the live transport only and the export finishes untouched.
    func testRemoteCommandsDuringAnExportLeaveTheExportAlone() async throws {
        let playback = try await openPiece(measureCount: 40)
        let url = directory.appending(path: "during-remote.wav")
        playback.export.chooseDestination = { _, _, done in done(url) }
        playback.export.chooseDestinationAndStart()
        XCTAssertTrue(playback.export.isExporting)

        XCTAssertEqual(try send(.togglePlayPause), .success)
        XCTAssertEqual(try send(.changePlaybackPosition(seconds: 3)), .success)
        XCTAssertEqual(try send(.skipForward), .success)
        XCTAssertEqual(try send(.stop), .success)

        var finished = false
        for _ in 0..<2_000 {
            if case .finished = playback.export.phase { finished = true; break }
            if case .failed(let failure) = playback.export.phase {
                return XCTFail("The export failed: \(failure.summary)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(finished, "The export should finish despite the remote commands")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}

/// Records what `NowPlayingControl` registers and publishes.
@MainActor
private final class FakeCenters: NowPlayingCenters {
    private(set) var handler: (@MainActor (RemoteTransportCommand) -> MPRemoteCommandHandlerStatus)?
    private(set) var registrationCount = 0
    private(set) var published: [NowPlayingInfo?] = []

    func registerCommands(
        _ handler: @escaping @MainActor (RemoteTransportCommand) -> MPRemoteCommandHandlerStatus
    ) {
        registrationCount += 1
        self.handler = handler
    }

    func publish(_ info: NowPlayingInfo?) {
        published.append(info)
    }
}
