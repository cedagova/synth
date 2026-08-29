import XCTest
@testable import SynthKit

/// Where the export's thread ownership is actually proved, in CI.
///
/// **Why this file exists.** `PlaybackEngine` is single-owner and not internally
/// synchronised; its own doc comment says it is `Sendable` so that this leaf's
/// export can own one on a background thread, "not so that two threads can share
/// one". An export is therefore the first place in the app where an engine
/// legitimately leaves the main thread — and the suite's existing threading
/// guardrails (`RealtimePlaybackTests`, `PresetRenderTests`,
/// `CuratedInstrumentAssetTests`) are all gated behind
/// `SYNTH_REALTIME_GUARDRAIL=1` and therefore do **not** run in CI. A claim that
/// only holds when someone remembers to set an environment variable is not a
/// guardrail.
///
/// So everything here runs unconditionally, uses no audio hardware, and each
/// test names one of the three things the ownership boundary has to be:
///
/// 1. the exporting engine is owned by exactly one thread, and that thread is
///    not the main one when the app runs an export;
/// 2. cancelling from another thread while the render is in flight is safe and
///    leaves nothing behind; and
/// 3. no live-playback engine is touched by an export, concurrently or at all.
final class AudioExportConcurrencyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "AudioExportConcurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func timeline(measures: Int = 6) throws -> PerformanceTimeline {
        try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: measures)
        )
    }

    private func request(_ timeline: PerformanceTimeline) -> AudioExportRequest {
        AudioExportRequest(
            timeline: timeline,
            voices: .uniform(SynthPatchVoiceProvider()),
            settings: .cdQuality
        )
    }

    // MARK: 1 — one thread owns the engine, and it is not the main one

    /// The export runs entirely on a background thread, and the engine it built
    /// was never touched from anywhere else.
    ///
    /// `ownershipChecks` is the count of times `run(...)` re-verified the
    /// engine's owning thread — one per block. Asserting it is greater than one
    /// is what stops this from passing on a render that never looped.
    func testAnExportRunsWhollyOnTheThreadThatStartedIt() throws {
        let request = request(try timeline())
        let url = directory.appending(path: "background.wav")

        let outcome = Outcome()
        let finished = expectation(description: "export finished")
        Thread.detachNewThread {
            do {
                outcome.succeed(try AudioExporter(request: request).run(to: url))
            } catch {
                outcome.fail(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 120)

        let result = try outcome.value()
        XCTAssertFalse(
            result.ranOnMainThread,
            "The export ran on the main thread; a long render would freeze the window."
        )
        XCTAssertGreaterThan(
            result.ownershipChecks, 1,
            "The ownership guard ran \(result.ownershipChecks) times, so it proved nothing."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// Several exports at once each own their own engine and produce correct,
    /// identical files.
    ///
    /// The engine is not internally synchronised, so if an export shared any
    /// state with another — a cached graph, a static program, a global C engine
    /// — this is where the files would come out different or the run would
    /// crash. Identical output from four concurrent renders of one configuration
    /// is a much stronger statement than one render being deterministic.
    func testConcurrentExportsDoNotShareEngineStateAndAgreeExactly() throws {
        let request = request(try timeline(measures: 4))
        let count = 4

        let finished = expectation(description: "all exports finished")
        finished.expectedFulfillmentCount = count
        let outcomes = (0..<count).map { _ in Outcome() }
        let urls = (0..<count).map { directory.appending(path: "concurrent-\($0).wav") }

        for index in 0..<count {
            let url = urls[index]
            let outcome = outcomes[index]
            Thread.detachNewThread {
                do {
                    outcome.succeed(try AudioExporter(request: request).run(to: url))
                } catch {
                    outcome.fail(error)
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 240)

        var contents: [Data] = []
        for (index, outcome) in outcomes.enumerated() {
            let result = try outcome.value()
            XCTAssertFalse(result.ranOnMainThread, "Export \(index) ran on the main thread.")
            contents.append(try Data(contentsOf: urls[index]))
        }
        for (index, data) in contents.enumerated().dropFirst() {
            XCTAssertEqual(
                data, contents[0],
                "Concurrent export \(index) differed from the first; the exports share state."
            )
        }
    }

    // MARK: 2 — cancelling from another thread is safe

    /// Cancel from the main thread while a background export is mid-render.
    ///
    /// This is the exact shape of the UI's Cancel button: the render owns its
    /// engine on one thread and the only object the two threads share is the
    /// cancellation flag. The run must end promptly, report `.cancelled`, and
    /// leave neither a destination file nor a staged sibling.
    func testCancellingFromTheMainThreadMidRenderIsSafeAndLeavesNothing() throws {
        let request = request(try timeline(measures: 10))
        let url = directory.appending(path: "cancelled.wav")

        let cancellation = AudioExportCancellation()
        let started = expectation(description: "render under way")
        started.assertForOverFulfill = false
        let finished = expectation(description: "export returned")
        let outcome = Outcome()

        Thread.detachNewThread {
            do {
                outcome.succeed(try AudioExporter(request: request).run(
                    to: url,
                    progress: { _ in started.fulfill() },
                    cancellation: cancellation
                ))
            } catch {
                outcome.fail(error)
            }
            finished.fulfill()
        }

        wait(for: [started], timeout: 60)
        XCTAssertTrue(Thread.isMainThread, "The cancel has to come from the main thread to mean anything.")
        // Hammered rather than pressed once: cancelling is idempotent, and an
        // owner holding the key down must not be a different code path.
        for _ in 0..<50 { cancellation.cancel() }
        XCTAssertTrue(cancellation.isCancelled)

        wait(for: [finished], timeout: 60)
        XCTAssertEqual(
            outcome.error as? AudioExportError, .cancelled,
            "A cancel from another thread did not stop the export cleanly."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "A cancelled export left a file at the destination."
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false)
            ),
            [],
            "A cancelled export left a staged file behind."
        )
    }

    /// The flag itself, hammered from many threads at once.
    ///
    /// Small, and worth having: it is the only mutable state two threads share
    /// in the whole export, so its correctness is the whole of the concurrency
    /// argument above.
    func testTheCancellationFlagIsSafeUnderConcurrentUse() {
        let cancellation = AudioExportCancellation()
        let finished = expectation(description: "hammering done")
        finished.expectedFulfillmentCount = 8

        for worker in 0..<8 {
            Thread.detachNewThread {
                for _ in 0..<20_000 {
                    if worker.isMultiple(of: 2) {
                        _ = cancellation.isCancelled
                    } else {
                        cancellation.cancel()
                    }
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 60)
        XCTAssertTrue(cancellation.isCancelled)
    }

    // MARK: 3 — the live engine is never touched

    /// A background export leaves the engine the owner is listening to exactly
    /// where it was.
    ///
    /// The live engine here is in offline mode because CI is headless, which
    /// changes nothing about the claim: it is the same object, the same program,
    /// the same transport state and the same playhead that real-time playback
    /// owns. The export renders concurrently on another thread, and afterwards
    /// the live engine's program identity, transport, position and mixer are all
    /// unchanged.
    func testAnExportDoesNotTouchTheEngineTheOwnerIsListeningTo() throws {
        let timeline = try timeline()

        // The "live" engine: loaded, positioned, with a mix on it.
        let live = PlaybackEngine(voiceProvider: SynthPatchVoiceProvider())
        try live.setRenderMode(.offline(sampleRate: 48_000))
        try live.load(timeline: timeline)
        live.seek(toMicroseconds: 750_000)
        live.mixer(forLineAt: 0)?.gain = 0.5
        live.masterGain = 0.75

        let programBefore = try XCTUnwrap(live.loadedProgram)
        let identityBefore = ObjectIdentifier(programBefore)
        let positionBefore = live.playbackPositionFrame
        let stateBefore = live.transportState
        let gainBefore = try XCTUnwrap(live.mixer(forLineAt: 0)).gain

        let url = directory.appending(path: "beside-live.wav")
        let request = request(timeline)
        let finished = expectation(description: "export finished")
        let outcome = Outcome()
        Thread.detachNewThread {
            do {
                outcome.succeed(try AudioExporter(request: request).run(to: url))
            } catch {
                outcome.fail(error)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 120)
        _ = try outcome.value()

        let programAfter = try XCTUnwrap(live.loadedProgram)
        XCTAssertEqual(
            ObjectIdentifier(programAfter), identityBefore,
            "The export replaced the live engine's program."
        )
        XCTAssertEqual(live.playbackPositionFrame, positionBefore, "The export moved the playhead.")
        XCTAssertEqual(live.transportState, stateBefore, "The export changed the transport state.")
        XCTAssertEqual(
            try XCTUnwrap(live.mixer(forLineAt: 0)).gain, gainBefore, accuracy: 0.0001,
            "The export changed the live mix."
        )
        XCTAssertEqual(live.masterGain, 0.75, accuracy: 0.0001, "The export changed the master gain.")
    }

    /// The structural reason the test above can never start failing quietly:
    /// an export cannot be handed a `PlaybackEngine` at all.
    ///
    /// `AudioExportRequest` carries a timeline, a voice assignment and mixer
    /// *values*. If a future change gave it an engine — or a closure that could
    /// capture one — the "no live engine is touched" claim would rest on
    /// discipline rather than on the type. This reads the source back, the same
    /// way `RealtimeSafetyTests` reads the render callback back.
    func testAnExportRequestCannotCarryAnEngineOrACallbackThatCouldCaptureOne() throws {
        let source = try String(
            contentsOf: try AudioExportTests.sourceFile("AudioExport.swift"), encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "public struct AudioExportRequest: Sendable {"),
            "AudioExportRequest was renamed; this guard needs updating with it."
        )
        let end = try XCTUnwrap(source.range(of: "// MARK: - Progress, cancellation, results"))
        let declaration = String(source[start.lowerBound..<end.lowerBound])

        for stored in declaration.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ $0.hasPrefix("public let ") || $0.hasPrefix("let ") || $0.hasPrefix("var ") })
        {
            XCTAssertFalse(
                stored.contains("PlaybackEngine"),
                "AudioExportRequest stores an engine (\(stored)); an export must build its own."
            )
            XCTAssertFalse(
                stored.contains("->"),
                "AudioExportRequest stores a closure (\(stored)); it could capture the live engine "
                    + "and be called from the export's thread."
            )
        }
    }

    /// The exporter's engine is created inside `run(...)` and never escapes.
    ///
    /// The lifetime argument in the doc comment is only true if `run` really is
    /// the only place a `PlaybackEngine` is made and nothing stores it. A stored
    /// property or a returned engine would let a second thread reach it, so both
    /// are pinned here.
    func testTheExporterBuildsItsEngineInsideTheRunAndNeverStoresIt() throws {
        let source = try String(
            contentsOf: try AudioExportTests.sourceFile("AudioExport.swift"), encoding: .utf8
        )
        let constructions = source.components(separatedBy: "PlaybackEngine(").count - 1
        XCTAssertEqual(
            constructions, 1,
            "The exporter builds \(constructions) engines; exactly one, inside the render, is the "
                + "whole of the single-owner argument."
        )
        XCTAssertTrue(
            source.contains("let engine = PlaybackEngine(voices: request.voices)"),
            "The engine is no longer a local of the render function."
        )
        XCTAssertFalse(
            source.contains("var engine: PlaybackEngine") || source.contains("let engine: PlaybackEngine"),
            "The exporter stores its engine as a property; it must be a local that dies with the run."
        )
    }
}

// MARK: - Test doubles

/// One thread's result, read from another. `Result` is not `Sendable` here
/// because `AudioExportResult` travels with it, so the lock is explicit.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AudioExportResult?
    private var failure: Error?

    func succeed(_ value: AudioExportResult) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func value(file: StaticString = #filePath, line: UInt = #line) throws -> AudioExportResult {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return try XCTUnwrap(result, "The export produced neither a result nor an error.", file: file, line: line)
    }
}
