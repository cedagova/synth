import XCTest
@testable import Synth
import SynthKit

/// Playback ▸ Go to Rehearsal Mark and the loop's mark choices (#93), driven
/// through the same `PlaybackModel` methods the menu and the loop controls
/// call, on a piece imported into a real store in a temporary container.
///
/// `RehearsalMarkMenu` lists exactly `PlaybackModel.rehearsalMarks` and is
/// disabled when it is empty, so that list is the menu state asserted here.
@MainActor
final class RehearsalMarkWiringTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(container: AppContainer(rootURL: directory))
        await model.bootstrap()
        guard model.store != nil else {
            return XCTFail("The store did not open; nothing below can be meaningful.")
        }
        model.closeInstrumentCatalog()
    }

    override func tearDown() async throws {
        model?.closePlayback()
        model = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: The fixture

    /// Four measures of one part; `A` over measure 1 and `B` over measure 3
    /// unless `withMarks` is false.
    private static func score(withMarks: Bool) -> String {
        func mark(_ text: String) -> String {
            withMarks
                ? "<direction><direction-type><rehearsal>\(text)</rehearsal></direction-type></direction>"
                : ""
        }
        let note = "<note><pitch><step>C</step><octave>3</octave></pitch>"
            + "<duration>16</duration><type>whole</type></note>"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <part-list>
                <score-part id="P1"><part-name>Cello</part-name></score-part>
              </part-list>
              <part id="P1">
                <measure number="1">
                  <attributes>
                    <divisions>4</divisions>
                    <key><fifths>0</fifths></key>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                    <clef><sign>F</sign><line>4</line></clef>
                  </attributes>
                  \(mark("A"))\(note)
                </measure>
                <measure number="2">\(note)</measure>
                <measure number="3">\(mark("B"))\(note)</measure>
                <measure number="4">\(note)</measure>
              </part>
            </score-partwise>
            """
    }

    private func openPreparedPiece(withMarks: Bool) async throws -> PlaybackModel {
        let source = directory.appending(path: "fixture.musicxml")
        try Data(Self.score(withMarks: withMarks).utf8).write(to: source)

        let library = try XCTUnwrap(model.library)
        await library.importPieces(from: [source])
        let piece = try XCTUnwrap(library.pieces.first, "The fixture should have imported")

        model.openPlayback(for: piece)
        let playback = try XCTUnwrap(model.playback)
        await playback.prepare()
        XCTAssertTrue(playback.isReady)
        return playback
    }

    // MARK: The menu

    func testAPieceWithMarksListsThemInScoreOrder() async throws {
        let playback = try await openPreparedPiece(withMarks: true)
        XCTAssertEqual(playback.rehearsalMarks.map(\.menuTitle), ["A (measure 1)", "B (measure 3)"])
    }

    func testAPieceWithoutMarksDisablesTheMenu() async throws {
        let playback = try await openPreparedPiece(withMarks: false)
        XCTAssertTrue(playback.rehearsalMarks.isEmpty, "An empty list is what disables the item")
    }

    func testChoosingAMarkSeeksToItsMeasure() async throws {
        let playback = try await openPreparedPiece(withMarks: true)
        let b = try XCTUnwrap(playback.rehearsalMarks.last)

        playback.goToRehearsalMark(b)

        XCTAssertEqual(playback.position?.measureNumber, "3")
        XCTAssertEqual(playback.position?.playbackMeasureIndex, 2)
        XCTAssertEqual(
            playback.positionMicroseconds,
            playback.navigator?.microseconds(forMeasureNumber: "3")
        )
    }

    // MARK: The loop

    func testFromAToBLoopsSectionA() async throws {
        let playback = try await openPreparedPiece(withMarks: true)
        let a = playback.rehearsalMarks[0], b = playback.rehearsalMarks[1]

        playback.setLoopStart(atRehearsalMark: a)
        XCTAssertNil(playback.loop, "A start alone waits for an end")
        XCTAssertEqual(playback.loopFromField, "1")

        playback.setLoopEnd(beforeRehearsalMark: b)
        let loop = try XCTUnwrap(playback.loop)
        XCTAssertEqual(loop.startMeasureNumber, "1")
        XCTAssertEqual(loop.endMeasureNumber, "2")
        XCTAssertEqual(loop.endMicroseconds, playback.navigator?.microseconds(forRehearsalMark: b.mark))
    }

    func testTheLastSectionLoopsToTheEndOfThePiece() async throws {
        let playback = try await openPreparedPiece(withMarks: true)

        playback.setLoopEndAtPieceEnd()
        playback.setLoopStart(atRehearsalMark: playback.rehearsalMarks[1])

        let loop = try XCTUnwrap(playback.loop)
        XCTAssertEqual(loop.displayText, "measures 3–4")
        XCTAssertEqual(loop.endMicroseconds, playback.totalMicroseconds)
    }

    func testEndingBeforeAMarkWithNoStartLoopsFromTheBeginning() async throws {
        let playback = try await openPreparedPiece(withMarks: true)

        playback.setLoopEnd(beforeRehearsalMark: playback.rehearsalMarks[1])

        XCTAssertEqual(playback.loop?.displayText, "measures 1–2")
    }

    func testNothingCanEndBeforeAMarkOnTheFirstMeasure() async throws {
        let playback = try await openPreparedPiece(withMarks: true)

        playback.setLoopEnd(beforeRehearsalMark: playback.rehearsalMarks[0])

        XCTAssertNil(playback.loop)
        XCTAssertEqual(playback.loopToField, "")
        XCTAssertEqual(
            playback.statusMessage,
            "A is on the first measure; a loop cannot end before it."
        )
    }
}
