import XCTest
@testable import SynthKit

/// Issue #91 (LOOP091): "Loop range only" exports exactly the performed span
/// the loop plays, lets the last notes ring out, and names the file with the
/// printed range.
///
/// Every exactness claim is a byte comparison against a full export of the same
/// piece and preset — never a tolerance — because the plan's decision 5 is
/// "exact by pre-roll": the window must be the full export's own samples.
///
/// **The one stated exception** is the last `masterLookaheadFrames` frames
/// before the window end. The master's true-peak ceiling looks that far ahead,
/// so what it emits there already depends on the audio after the cut, which a
/// loop export deliberately changes (no new notes, everything released).
/// Everything before that stretch is compared byte for byte.
final class LoopRangeExportTests: XCTestCase {
    /// `SYNTH_MASTER_LOOKAHEAD_FRAMES`: how far the ceiling reads ahead.
    private static let masterLookaheadFrames = 64

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "LoopRangeExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Played order 1 2 3 4 2 3 5 6 7 8 1 2 3: printed measures 2 and 3 are
    /// heard three times, one whole note each, a different pitch per measure.
    private func repeatScore() throws -> CompiledScore {
        try AudioRenderFixtures.compiler.compile(
            pieceID: "loop-export", musicXML: MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        )
    }

    private struct Piece {
        let navigator: PlaybackNavigator
        let timeline: PerformanceTimeline
    }

    /// Humanized, so onsets sit off the barlines and a window boundary is not
    /// conveniently a silent sample.
    private func piece(settings: RealizationSettings = .standard) throws -> Piece {
        let score = try repeatScore()
        return Piece(
            navigator: PlaybackNavigator(score: score),
            timeline: AudioRenderFixtures.realizer.realize(score, settings: settings)
        )
    }

    /// The produced master on, so calibration, cohesion and the ceiling are
    /// all in the path the window has to reproduce.
    private func request(_ timeline: PerformanceTimeline, window: LoopRange? = nil) -> AudioExportRequest {
        AudioExportRequest(
            timeline: timeline,
            voices: .uniform(SynthPatchVoiceProvider()),
            producedMaster: .standard,
            settings: .cdQuality,
            window: window
        )
    }

    /// A loop over playback measures `first`…`last`, built the way the
    /// navigator builds one, so a specific pass of a repeat can be chosen.
    private func loop(_ navigator: PlaybackNavigator, _ first: Int, _ last: Int) throws -> LoopRange {
        LoopRange(
            startPlaybackMeasureIndex: first,
            endPlaybackMeasureIndex: last,
            startMicroseconds: try XCTUnwrap(navigator.microseconds(atPlaybackMeasureIndex: first)),
            endMicroseconds: try XCTUnwrap(navigator.endMicroseconds(ofPlaybackMeasureIndex: last)),
            startMeasureNumber: navigator.score.sourceMeasures[
                navigator.score.playbackMeasures[first].sourceMeasureIndex
            ].number,
            endMeasureNumber: navigator.score.sourceMeasures[
                navigator.score.playbackMeasures[last].sourceMeasureIndex
            ].number
        )
    }

    /// Export and return the audio payload (header stripped) and its frame count.
    private func export(
        _ request: AudioExportRequest, named name: String
    ) throws -> (payload: Data, frames: Int64, url: URL) {
        let url = directory.appending(path: name)
        let result = try AudioExporter(request: request).run(to: url)
        let header = AudioFileWriter(
            settings: request.settings, frameCount: result.frameCount
        ).header().count
        let data = try Data(contentsOf: url)
        return (data.suffix(from: header), result.frameCount, url)
    }

    private static let bytesPerFrame = 4  // stereo, 16-bit (cdQuality)

    private func frame(_ microseconds: Int64) -> Int64 {
        RenderProgram.frame(
            forMicroseconds: microseconds, sampleRate: AudioExportSettings.cdQuality.sampleRate.hertz
        )
    }

    /// The window's bytes against the same frames of the full export, from the
    /// window start to `masterLookaheadFrames` before its end.
    private func assertWindowMatchesFullExport(
        _ loop: LoopRange, in piece: Piece, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let full = try export(request(piece.timeline), named: "full-\(label).wav")
        let windowed = try export(request(piece.timeline, window: loop), named: "loop-\(label).wav")

        let start = Int(frame(loop.startMicroseconds))
        let end = Int(frame(loop.endMicroseconds))
        let compared = end - start - Self.masterLookaheadFrames
        XCTAssertGreaterThan(compared, 0, file: file, line: line)

        let fullBytes = full.payload.dropFirst(start * Self.bytesPerFrame)
            .prefix(compared * Self.bytesPerFrame)
        let windowBytes = windowed.payload.prefix(compared * Self.bytesPerFrame)
        XCTAssertEqual(windowBytes.count, compared * Self.bytesPerFrame, file: file, line: line)
        // Not XCTAssertEqual on the Data: a failure would print megabytes.
        if windowBytes != fullBytes {
            let firstDifference = zip(windowBytes, fullBytes).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset ?? -1
            XCTFail(
                "\(label): the loop export differs from the full export's frames "
                    + "at window frame \(firstDifference / Self.bytesPerFrame) of \(compared).",
                file: file, line: line
            )
        }
        // And the window is not trivially silent: the comparison proved something.
        XCTAssertTrue(windowBytes.contains { $0 != 0 }, "\(label): the window is silent.",
                      file: file, line: line)
    }

    // MARK: Exactness by pre-roll (plan decision 5)

    func testAPlainLoopIsByteIdenticalToTheFullExportsSameFrames() throws {
        let piece = try piece()
        // Printed 6–7, heard once, late in the piece: a long pre-roll.
        let loop = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "7"))
        XCTAssertEqual(loop.startPlaybackMeasureIndex, 7)
        try assertWindowMatchesFullExport(loop, in: piece, label: "plain")
    }

    /// Printed 2–3 on their *second* pass (playback 4–5, after the repeat). The
    /// same printed measures sound three times; the window must be the pass the
    /// loop plays, with the voice, room and master state that pass has.
    func testALoopInsideARepeatedSectionExportsTheHeardPassExactly() throws {
        let piece = try piece()
        let loop = try loop(piece.navigator, 4, 5)
        XCTAssertEqual(loop.startMeasureNumber, "2")
        XCTAssertEqual(loop.endMeasureNumber, "3")
        try assertWindowMatchesFullExport(loop, in: piece, label: "repeat-second-pass")
    }

    /// A loop resolved across the repeat jump (printed 4 → 5 plays 4 2 3 5).
    func testALoopAcrossTheRepeatJumpExportsThePerformedSpanExactly() throws {
        let piece = try piece()
        let loop = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "4", toMeasureNumber: "5"))
        XCTAssertEqual(loop.measureCount, 4, "4 2 3 5: the performed span, not the printed one.")
        try assertWindowMatchesFullExport(loop, in: piece, label: "across-repeat")
    }

    // MARK: Ring-out (plan decision 6)

    /// The file is the window plus the program's own capped release tail, and
    /// nothing starts after the window end — while the full export, over the
    /// same stretch, does start the next measure's note (the positive control).
    func testNoNoteStartsAfterTheWindowAndTheFileEndsAfterTheReleaseTail() throws {
        let piece = try piece(settings: .literal)
        let loop = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "6"))
        let full = try export(request(piece.timeline), named: "full-ring.wav")
        let windowed = try export(request(piece.timeline, window: loop), named: "loop-ring.wav")

        let rate = AudioExportSettings.cdQuality.sampleRate.hertz
        let start = frame(loop.startMicroseconds)
        let end = frame(loop.endMicroseconds)
        let tail = Int64((SynthPatchVoiceProvider().releaseTailSeconds * rate).rounded())
        XCTAssertEqual(windowed.frames, end - start + tail, "window + release tail, exactly")

        let loopAudio = try AudioExportTests.decode(windowed.url)
        let fullAudio = try AudioExportTests.decode(full.url)
        func ringOut(_ audio: (left: [Float], right: [Float]), from offset: Int) -> PlaybackEngine.RenderedAudio {
            let range = offset..<min(audio.left.count, offset + Int(tail))
            return PlaybackEngine.RenderedAudio(
                sampleRate: rate, left: Array(audio.left[range]), right: Array(audio.right[range])
            )
        }
        // Start a little after the cut: the released note's own decay is not an onset.
        let settle = Int(0.02 * rate)
        let loopTail = ringOut(loopAudio, from: Int(end - start) + settle)
        let fullTail = ringOut(fullAudio, from: Int(end) + settle)

        XCTAssertFalse(
            AudioRenderFixtures.detectedOnsetsMicroseconds(fullTail).isEmpty,
            "Control: the full export starts the next note in this stretch."
        )
        XCTAssertEqual(
            AudioRenderFixtures.detectedOnsetsMicroseconds(loopTail), [],
            "A note started after the loop's end."
        )
        // The next measure is B4; the loop is measure 6 = A4. None of B4 may sound.
        let nextPitch = AudioRenderFixtures.frequency(ofMIDINote: 71)
        let loopB4 = AudioRenderFixtures.energy(loopTail.left, atHertz: nextPitch, sampleRate: rate)
        let fullB4 = AudioRenderFixtures.energy(fullTail.left, atHertz: nextPitch, sampleRate: rate)
        XCTAssertLessThan(loopB4, fullB4 * 0.01, "The next measure's pitch leaked into the ring-out.")

        // It rings out rather than stopping dead: the window's last note is
        // still audible just after the cut, and gone by the end of the file.
        let justAfter = loopAudio.left[Int(end - start)..<Int(end - start) + settle]
        XCTAssertGreaterThan(AudioExportTests.rootMeanSquare(Array(justAfter)), 1e-4)
        let last = loopAudio.left.suffix(Int(0.1 * rate))
        XCTAssertLessThan(AudioExportTests.rootMeanSquare(Array(last)), 1e-4)
    }

    /// The cut is exactly "the performance with nothing after it": a note held
    /// across the window end is released there, the sustain pedal comes up
    /// there, nothing later starts. Proved byte for byte against a full export
    /// of that edited timeline, over the window *and* the ring-out.
    ///
    /// Produced master off, because calibration is measured from the timeline
    /// and the edited one would calibrate differently — which is exactly why
    /// the real feature cuts at render time instead (plan decision 6). The
    /// window ends mid-note, mid-pedal, on purpose.
    func testTheCutReleasesHeldNotesAndThePedalExactlyAsIfNothingFollowed() throws {
        let timeline = try AudioRenderFixtures.timeline(MusicXMLScoreFixtures.pedalStudy())
        XCTAssertFalse(timeline.lines.flatMap(\.pedalSpans).isEmpty)
        let cut = timeline.totalMicroseconds * 3 / 8  // inside measure 2: C4 held, pedal down
        XCTAssertTrue(timeline.lines.flatMap(\.events).contains {
            $0.onsetMicroseconds < cut && $0.endMicroseconds > cut
        }, "No note is held across the cut, so this test cannot see the release.")
        XCTAssertTrue(timeline.lines.flatMap(\.pedalSpans).contains {
            $0.startMicroseconds < cut && $0.endMicroseconds > cut
        }, "No pedal is down across the cut, so this test cannot see the lift.")
        let window = LoopRange(
            startPlaybackMeasureIndex: 0, endPlaybackMeasureIndex: 1,
            startMicroseconds: timeline.totalMicroseconds / 8, endMicroseconds: cut,
            startMeasureNumber: "1", endMeasureNumber: "2"
        )

        let edited = PerformanceTimeline(
            pieceID: timeline.pieceID,
            contentSHA256: timeline.contentSHA256,
            ticksPerQuarter: timeline.ticksPerQuarter,
            settings: timeline.settings,
            seed: timeline.seed,
            totalMicroseconds: timeline.totalMicroseconds,
            totalTicks: timeline.totalTicks,
            lines: timeline.lines.map { line in
                PerformanceLine(
                    id: line.id, name: line.name,
                    events: line.events.filter { $0.onsetMicroseconds < cut }.map {
                        PerformanceEvent(
                            onsetMicroseconds: $0.onsetMicroseconds,
                            durationMicroseconds: min($0.endMicroseconds, cut) - $0.onsetMicroseconds,
                            midiNoteNumber: $0.midiNoteNumber,
                            velocity: $0.velocity,
                            origin: $0.origin,
                            onsetTicks: $0.onsetTicks,
                            durationTicks: $0.durationTicks,
                            playbackMeasureIndex: $0.playbackMeasureIndex,
                            sourceMeasureIndex: $0.sourceMeasureIndex
                        )
                    },
                    pedalSpans: line.pedalSpans.filter { $0.startMicroseconds < cut }.map {
                        PerformancePedalSpan(
                            startMicroseconds: $0.startMicroseconds,
                            endMicroseconds: min($0.endMicroseconds, cut),
                            startTicks: $0.startTicks,
                            endTicks: $0.endTicks
                        )
                    }
                )
            },
            report: timeline.report
        )

        func plain(_ timeline: PerformanceTimeline, window: LoopRange? = nil) -> AudioExportRequest {
            AudioExportRequest(
                timeline: timeline, voices: .uniform(SynthPatchVoiceProvider()),
                settings: .cdQuality, window: window
            )
        }
        let windowed = try export(plain(timeline, window: window), named: "cut.wav")
        let reference = try export(plain(edited), named: "edited-full.wav")

        let start = Int(frame(window.startMicroseconds))
        let expected = reference.payload.dropFirst(start * Self.bytesPerFrame)
            .prefix(Int(windowed.frames) * Self.bytesPerFrame)
        XCTAssertEqual(expected.count, windowed.payload.count)
        XCTAssertTrue(
            windowed.payload.elementsEqual(expected),
            "The loop export's window and ring-out are not the edited performance's samples."
        )
    }

    /// A loop that ends where the piece ends is not cut: its tail is the full
    /// export's tail, byte for byte, and the file ends where the full one does.
    func testALoopEndingAtThePieceEndIsTheFullExportsTailExactly() throws {
        let piece = try piece()
        let lastIndex = piece.navigator.score.playbackMeasures.count - 1
        let loop = try loop(piece.navigator, lastIndex - 1, lastIndex)
        XCTAssertGreaterThanOrEqual(loop.endMicroseconds, piece.timeline.totalMicroseconds)

        let full = try export(request(piece.timeline), named: "full-end.wav")
        let windowed = try export(request(piece.timeline, window: loop), named: "loop-end.wav")
        let start = Int(frame(loop.startMicroseconds))
        XCTAssertEqual(windowed.frames, full.frames - Int64(start))
        XCTAssertTrue(
            windowed.payload.elementsEqual(full.payload.dropFirst(start * Self.bytesPerFrame)),
            "A loop to the piece end must be the full export's own last frames."
        )
    }

    /// No window: the full export, unchanged — same bytes as a request built
    /// before the window existed.
    func testWithoutAWindowTheExportIsTheWholePiece() throws {
        let piece = try piece()
        let plain = try export(request(piece.timeline), named: "plain.wav")
        let windowless = try export(
            request(piece.timeline).windowed(to: nil), named: "windowless.wav"
        )
        XCTAssertEqual(plain.payload, windowless.payload)
        let program = try RenderProgram(
            timeline: piece.timeline, sampleRate: AudioExportSettings.cdQuality.sampleRate.hertz
        )
        XCTAssertEqual(plain.frames, program.totalFrames)
    }

    // MARK: File name

    func testTheSuggestedNameCarriesThePrintedRange() throws {
        let piece = try piece()
        let loop = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "7"))
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(
                pieceTitle: "Prelude in C", presetName: "Chamber", format: .wav, range: loop
            ),
            "Prelude in C — Chamber mm. 6–7.wav"
        )
        let one = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "6"))
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(
                pieceTitle: "Prelude in C", presetName: nil, format: .aiff, range: one
            ),
            "Prelude in C m. 6.aiff"
        )
        // Without a range the name is what it always was.
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(pieceTitle: "Prelude in C", presetName: nil, format: .wav),
            "Prelude in C.wav"
        )
    }

    func testALongTitleIsShortenedBeforeTheRangeIs() throws {
        let piece = try piece()
        let loop = try XCTUnwrap(piece.navigator.loopRange(fromMeasureNumber: "6", toMeasureNumber: "7"))
        let name = AudioExportNaming.suggestedFileName(
            pieceTitle: String(repeating: "Sehr langsam ", count: 40),
            presetName: "Chamber", format: .wav, range: loop
        )
        XCTAssertLessThanOrEqual(name.utf8.count, AudioExportNaming.maximumFileNameBytes)
        XCTAssertTrue(name.hasSuffix(" mm. 6–7.wav"), name)
    }
}
