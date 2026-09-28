import AVFoundation
import XCTest
@testable import SynthKit

/// Issue #90: "Export Stems…" writes one file per audible line through the
/// same engine graph as the mix, pre-master and in 32-bit float, published
/// into a folder all or nothing.
///
/// The headline claim is arithmetic on real files: the stems of a multi-line
/// fixture, decoded by the system decoder and summed, reproduce the
/// master-bypassed mix within `sumTolerance`.
final class AudioStemExportTests: XCTestCase {
    /// Largest per-sample difference allowed between the summed stems and the
    /// master-bypassed mix: −120 dBFS (measured: about 3e-8). The renders are the same deterministic
    /// graph per line, so the only difference is float summation order (the
    /// bus adds lines in one order, the test in another) — far below this.
    static let sumTolerance: Float = 1e-6

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "AudioStemExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private func fugue(measures: Int = 8) throws -> PerformanceTimeline {
        try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: measures)
        )
    }

    private func twoLines() throws -> PerformanceTimeline {
        try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
    }

    /// A mix with every line doing something different: levels, pans, room
    /// sends and depths — and the produced master on, which the stems must
    /// bypass.
    private func mixRequest(
        _ timeline: PerformanceTimeline,
        mixer: [ScoreLineID: LineMixerState]? = nil,
        masterGain: Float = 1,
        settings: AudioExportSettings = .standard
    ) -> AudioExportRequest {
        let varied = Dictionary(uniqueKeysWithValues: timeline.lines.enumerated().map { index, line in
            (line.id, LineMixerState(
                volume: [0.8, 1.3, 0.6, 1.1][index % 4],
                pan: [-0.6, 0.4, 0.0, 0.9][index % 4],
                isMuted: false,
                isSoloed: false,
                roomSend: [0.3, 0.0, 0.5, 0.2][index % 4],
                depth: [0.0, 0.4, 0.2, 0.7][index % 4]
            ))
        })
        return AudioExportRequest(
            timeline: timeline,
            voices: .uniform(SynthPatchVoiceProvider()),
            mixer: mixer ?? varied,
            masterGain: masterGain,
            producedMaster: .standard,
            settings: settings
        )
    }

    private func folder(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    // MARK: Summation (the acceptance criterion)

    /// Summing the stems reproduces the master-bypassed full mix.
    func testTheStemsSumToTheMasterBypassedMix() throws {
        let timeline = try fugue()
        XCTAssertGreaterThanOrEqual(timeline.lines.count, 3, "The fixture should be multi-line.")
        let mix = mixRequest(timeline)

        let reference = directory.appending(path: "mix-bypassed.wav")
        try AudioExporter(request: AudioExportRequest(
            timeline: mix.timeline, voices: mix.voices, mixer: mix.mixer,
            masterGain: mix.masterGain, producedMaster: mix.producedMaster,
            settings: mix.settings, bypassesMasterStage: true, sampleEncoding: .float32
        )).run(to: reference)

        let out = try folder("stems")
        let stems = AudioStemExportRequest(mix: mix, pieceTitle: "Fugue")
        let result = try AudioStemExporter(request: stems).run(into: out)
        XCTAssertEqual(result.files.count, timeline.lines.count)

        let expected = try AudioExportTests.decode(reference)
        var left = [Float](repeating: 0, count: expected.left.count)
        var right = left
        for file in result.files {
            let stem = try AudioExportTests.decode(file.url)
            XCTAssertEqual(stem.left.count, left.count, "A stem is not the length of the mix.")
            XCTAssertGreaterThan(
                AudioExportTests.rootMeanSquare(stem.left) + AudioExportTests.rootMeanSquare(stem.right),
                0.0001, "\(file.url.lastPathComponent) is silent."
            )
            for index in left.indices {
                left[index] += stem.left[index]
                right[index] += stem.right[index]
            }
        }

        var worst: Float = 0
        for index in left.indices {
            worst = max(worst, abs(left[index] - expected.left[index]),
                        abs(right[index] - expected.right[index]))
        }
        print("Stem sum vs master-bypassed mix: worst sample deviation \(worst)")
        XCTAssertGreaterThan(AudioExportTests.rootMeanSquare(expected.left), 0.001)
        XCTAssertLessThanOrEqual(
            worst, Self.sumTolerance,
            "Summed stems differ from the master-bypassed mix by \(worst) (tolerance \(Self.sumTolerance))."
        )
    }

    /// The bypass is the whole master stage: with it, the produced master and
    /// the ceiling change nothing, so the render is the raw line sum.
    func testTheBypassedRenderIgnoresTheProducedMasterAndTheCeiling() throws {
        let timeline = try twoLines()
        func render(_ produced: ProducedMasterSettings, gain: Float) throws -> [Float] {
            let url = directory.appending(path: "bypass-\(produced.isEnabled)-\(gain).wav")
            try AudioExporter(request: AudioExportRequest(
                timeline: timeline, voices: .uniform(SynthPatchVoiceProvider()),
                masterGain: gain, producedMaster: produced,
                bypassesMasterStage: true, sampleEncoding: .float32
            )).run(to: url)
            return try AudioExportTests.decode(url).left
        }
        let off = try render(.off, gain: 1)
        XCTAssertEqual(try render(.standard, gain: 1), off, "The produced master reached a bypassed render.")

        // Linear all the way through: 8× the gain is 8× every sample, which a
        // ceiling anywhere in the path would break.
        let loud = try render(.off, gain: 8)
        XCTAssertGreaterThan(loud.map(abs).max() ?? 0, 1, "The fixture should exceed full scale at 8×.")
        for (a, b) in zip(loud, off) {
            XCTAssertEqual(a, b * 8, accuracy: 1e-5)
        }
    }

    // MARK: Which lines get a stem

    func testOnlyTheLinesTheMixPlaysGetAStem() throws {
        let timeline = try fugue()
        let ids = timeline.lines.map(\.id)
        var mixer = Dictionary(uniqueKeysWithValues: ids.map { ($0, LineMixerState.neutral) })

        mixer[ids[0]]?.isMuted = true
        XCTAssertEqual(
            AudioStemExportRequest(mix: mixRequest(timeline, mixer: mixer), pieceTitle: "F").stems.map(\.lineID),
            Array(ids.dropFirst()), "A muted line got a stem."
        )

        // While anything is soloed only soloed lines play — and mute still wins.
        mixer[ids[1]]?.isSoloed = true
        mixer[ids[2]]?.isSoloed = true
        mixer[ids[2]]?.isMuted = true
        XCTAssertEqual(
            AudioStemExportRequest(mix: mixRequest(timeline, mixer: mixer), pieceTitle: "F").stems.map(\.lineID),
            [ids[1]]
        )
    }

    func testEverythingMutedReportsNothingToExportAndWritesNothing() throws {
        let timeline = try twoLines()
        var muted = LineMixerState.neutral
        muted.isMuted = true
        let request = AudioStemExportRequest(
            mix: mixRequest(timeline, mixer: Dictionary(uniqueKeysWithValues: timeline.lines.map { ($0.id, muted) })),
            pieceTitle: "Two"
        )
        XCTAssertTrue(request.stems.isEmpty)
        let out = try folder("muted")
        XCTAssertThrowsError(try AudioStemExporter(request: request).run(into: out)) {
            XCTAssertEqual($0 as? AudioExportError, .nothingAudible)
        }
        XCTAssertEqual(try contents(of: out), [])
    }

    /// Each stem keeps its own fader and pan: a line panned hard left is
    /// silent on the right of its stem.
    func testAStemKeepsItsLinesPan() throws {
        let timeline = try twoLines()
        let ids = timeline.lines.map(\.id)
        var left = LineMixerState.neutral
        left.pan = -1
        let request = AudioStemExportRequest(
            mix: mixRequest(timeline, mixer: [ids[0]: left, ids[1]: .neutral]), pieceTitle: "Two"
        )
        let result = try AudioStemExporter(request: request).run(into: try folder("pan"))
        let first = try AudioExportTests.decode(result.files[0].url)
        XCTAssertGreaterThan(AudioExportTests.rootMeanSquare(first.left), 0.001)
        XCTAssertLessThan(AudioExportTests.rootMeanSquare(first.right), 1e-6)
    }

    // MARK: Float files

    /// Stems are 32-bit float in either container, and a stem above full
    /// scale round-trips without clipping.
    func testStemsAreFloatAndKeepPeaksAboveFullScale() throws {
        let timeline = try twoLines()
        for format in AudioExportFormat.allCases {
            // 16-bit on the mix side on purpose: the stems ignore it.
            let settings = AudioExportSettings(format: format, sampleRate: .rate48000, bitDepth: .bits16)
            var loud = LineMixerState.neutral
            loud.volume = LineMixerState.maximumVolume
            let request = AudioStemExportRequest(
                mix: mixRequest(
                    timeline,
                    mixer: Dictionary(uniqueKeysWithValues: timeline.lines.map { ($0.id, loud) }),
                    masterGain: 8,
                    settings: settings
                ),
                pieceTitle: "Loud"
            )
            XCTAssertEqual(request.fileDescription, "\(format.displayName) · 48 kHz · 32-bit float")
            let result = try AudioStemExporter(request: request).run(into: try folder("float-\(format)"))

            for file in result.files {
                XCTAssertEqual(file.encoding, .float32)
                XCTAssertFalse(file.didClip)
                let decoded = try AVAudioFile(forReading: file.url)
                // Flags rather than `commonFormat`: AIFF-C float is big-endian,
                // which AVAudioFormat reports as "other" even though it is float.
                let description = decoded.fileFormat.streamDescription.pointee
                XCTAssertNotEqual(description.mFormatFlags & kAudioFormatFlagIsFloat, 0, "\(format) stem is not float.")
                XCTAssertEqual(description.mBitsPerChannel, 32)
                XCTAssertEqual(decoded.fileFormat.sampleRate, 48_000)
                XCTAssertEqual(decoded.length, file.frameCount)

                let audio = try AudioExportTests.decode(file.url)
                let peak = (audio.left + audio.right).map(abs).max() ?? 0
                XCTAssertGreaterThan(peak, 1, "The fixture should exceed full scale.")
                XCTAssertEqual(peak, file.peakLevel, "The stored peak is not the rendered peak: it was clipped.")
                XCTAssertEqual(
                    Int64(try Data(contentsOf: file.url).count), file.byteCount,
                    "The header's promised size does not match the file."
                )
            }
        }
    }

    // MARK: All or nothing

    func testCancellingBeforeTheFirstBlockLeavesNothing() throws {
        let out = try folder("cancel-early")
        let cancellation = AudioExportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try AudioStemExporter(
            request: AudioStemExportRequest(mix: mixRequest(try twoLines()), pieceTitle: "Two")
        ).run(into: out, cancellation: cancellation)) {
            XCTAssertEqual($0 as? AudioExportError, .cancelled)
        }
        XCTAssertEqual(try contents(of: out), [])
    }

    /// A cancel after one stem is completely staged and the next is part-way
    /// leaves no stem — complete or partial — in the folder.
    func testCancellingPartWayThroughTheBatchLeavesNoStems() throws {
        let out = try folder("cancel-midway")
        let request = AudioStemExportRequest(mix: mixRequest(try fugue(measures: 8)), pieceTitle: "Fugue")
        XCTAssertGreaterThanOrEqual(request.stems.count, 2)

        let cancellation = AudioExportCancellation()
        let seen = StemSightings()
        XCTAssertThrowsError(try AudioStemExporter(request: request).run(
            into: out,
            progress: { step in
                seen.record(step)
                if step.stemIndex == 1, step.stem.renderedFrames > AudioExporter.blockFrames {
                    cancellation.cancel()
                }
            },
            cancellation: cancellation
        )) { XCTAssertEqual($0 as? AudioExportError, .cancelled) }

        XCTAssertTrue(seen.finishedFirstStem, "The first stem should have been fully rendered first.")
        XCTAssertEqual(try contents(of: out), [], "A cancelled batch left files behind.")
    }

    /// A write failure on a later stem publishes none of the earlier ones.
    func testAFailedStemPublishesNothing() throws {
        let out = try folder("fails")
        XCTAssertThrowsError(try AudioStemExporter(
            request: AudioStemExportRequest(mix: mixRequest(try twoLines()), pieceTitle: "Two")
        ).run(into: out, opener: FailingSecondOpener())) { error in
            guard case .writeFailed = error as? AudioExportError else {
                return XCTFail("Expected a write failure, got \(error)")
            }
        }
        XCTAssertEqual(try contents(of: out), [])
    }

    /// An existing file is never replaced without the owner's confirmation —
    /// and the refusal comes before any render.
    func testExistingFilesAreNotReplacedWithoutConfirmation() throws {
        let out = try folder("existing")
        let request = AudioStemExportRequest(mix: mixRequest(try twoLines()), pieceTitle: "Two")
        let kept = out.appending(path: request.stems[1].fileName)
        try Data("keep me".utf8).write(to: kept)
        XCTAssertEqual(request.existingFileNames(in: out), [request.stems[1].fileName])

        let started = Counter()
        XCTAssertThrowsError(try AudioStemExporter(request: request).run(
            into: out, progress: { _ in _ = started.increment() }
        )) { error in
            XCTAssertEqual(
                error as? AudioExportError,
                .wouldReplaceExistingFiles(
                    folder: out.standardizedFileURL.path(percentEncoded: false),
                    names: [request.stems[1].fileName]
                )
            )
        }
        XCTAssertEqual(started.value, 0, "It rendered before refusing.")
        XCTAssertEqual(try Data(contentsOf: kept), Data("keep me".utf8))
        XCTAssertEqual(try contents(of: out), [request.stems[1].fileName])

        // Confirmed: every stem is written, the old file replaced.
        let result = try AudioStemExporter(request: request).run(
            into: out, confirmedReplacements: [request.stems[1].fileName]
        )
        XCTAssertEqual(try contents(of: out), request.stems.map(\.fileName).sorted())
        XCTAssertNotEqual(try Data(contentsOf: kept), Data("keep me".utf8))
        XCTAssertEqual(result.files.map { $0.url.lastPathComponent }, request.stems.map(\.fileName))
    }

    /// A publish that fails part-way takes back what it added and restores
    /// what it replaced.
    func testAPublishThatFailsPartWayRestoresTheFolder() throws {
        let out = try folder("rollback")
        let names = ["A.wav", "B.wav"]
        try Data("original A".utf8).write(to: out.appending(path: "A.wav"))

        let staging = try AudioStemStaging(folder: out, fileNames: names, fileManager: .default)
        try Data("new A".utf8).write(to: staging.file(at: 0).url)
        // B is never staged, so its move fails after A's has succeeded.

        XCTAssertThrowsError(try staging.publish(confirmedReplacements: ["A.wav"])) { error in
            guard case .publishFailed = error as? AudioExportError else {
                return XCTFail("Expected a publish failure, got \(error)")
            }
        }
        XCTAssertEqual(try contents(of: out), ["A.wav"])
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "A.wav")), Data("original A".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.replacementDirectory.path(percentEncoded: false)))
    }

    /// Confirming one name does not license replacing another: a file that
    /// appears at a stem's name while the batch renders is refused at publish,
    /// and neither it nor the confirmed file is touched.
    func testAFileThatAppearsAfterConfirmationIsNotReplaced() throws {
        let out = try folder("newcomer")
        let request = AudioStemExportRequest(mix: mixRequest(try twoLines()), pieceTitle: "Two")
        let confirmed = out.appending(path: request.stems[0].fileName)
        let newcomer = out.appending(path: request.stems[1].fileName)
        try Data("confirmed".utf8).write(to: confirmed)

        let once = Counter()
        XCTAssertThrowsError(try AudioStemExporter(request: request).run(
            into: out,
            confirmedReplacements: [request.stems[0].fileName],
            progress: { _ in
                if once.increment() == 1 { try? Data("newcomer".utf8).write(to: newcomer) }
            }
        )) { error in
            XCTAssertEqual(
                error as? AudioExportError,
                .wouldReplaceExistingFiles(
                    folder: out.standardizedFileURL.path(percentEncoded: false),
                    names: [request.stems[1].fileName]
                )
            )
        }
        XCTAssertGreaterThan(once.value, 0, "The newcomer should have arrived mid-render.")
        XCTAssertEqual(try Data(contentsOf: confirmed), Data("confirmed".utf8))
        XCTAssertEqual(try Data(contentsOf: newcomer), Data("newcomer".utf8))
        XCTAssertEqual(try contents(of: out), request.stems.map(\.fileName).sorted())

        // An unconfirmed existing name is also refused before any render.
        XCTAssertThrowsError(try AudioStemExporter(request: request).run(
            into: out, confirmedReplacements: [request.stems[0].fileName]
        )) { guard case .wouldReplaceExistingFiles = $0 as? AudioExportError else {
            return XCTFail("Expected a refusal, got \($0)")
        } }
    }

    /// If a replaced original cannot be put back, it is kept — never deleted
    /// with the temporary folder — and the error says where it is.
    func testAnOriginalThatCannotBePutBackIsKeptAndNamed() throws {
        let out = try folder("unrestorable")
        try Data("original A".utf8).write(to: out.appending(path: "A.wav"))
        let fileManager = RestoreRefusingFileManager()

        let staging = try AudioStemStaging(folder: out, fileNames: ["A.wav", "B.wav"], fileManager: fileManager)
        try Data("new A".utf8).write(to: staging.file(at: 0).url)
        // B is never staged, so the batch fails after A is replaced, and the
        // file manager then refuses to put the original A back.

        var backupFolder: String?
        XCTAssertThrowsError(try staging.publish(confirmedReplacements: ["A.wav"])) { error in
            guard case .publishFailedOriginalsKept(_, _, let names, let folder) = error as? AudioExportError else {
                return XCTFail("Expected the originals-kept failure, got \(error)")
            }
            XCTAssertEqual(names, ["A.wav"])
            backupFolder = folder
            XCTAssertTrue(
                (error as? LocalizedError)?.recoverySuggestion?.contains(folder) ?? false,
                "The error does not say where the original is."
            )
        }
        let kept = URL(filePath: try XCTUnwrap(backupFolder)).appending(path: "A.wav")
        XCTAssertEqual(try Data(contentsOf: kept), Data("original A".utf8), "The original was lost.")
        XCTAssertEqual(try contents(of: out), [], "The new stem was left in the folder.")

        // The exporter's own cleanup after a failure must not delete it either.
        staging.discard()
        XCTAssertEqual(try Data(contentsOf: kept), Data("original A".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.file(at: 0).url.path(percentEncoded: false)))
        try? FileManager.default.removeItem(at: staging.replacementDirectory)
    }

    func testAMissingFolderFailsClearly() throws {
        let missing = directory.appending(path: "nope")
        XCTAssertThrowsError(try AudioStemExporter(
            request: AudioStemExportRequest(mix: mixRequest(try twoLines()), pieceTitle: "Two")
        ).run(into: missing)) { error in
            guard case .destinationUnusable = error as? AudioExportError else {
                return XCTFail("Expected an unusable destination, got \(error)")
            }
        }
    }

    // MARK: Progress

    func testProgressCoversTheWholeBatchMonotonically() throws {
        let request = AudioStemExportRequest(mix: mixRequest(try fugue(measures: 2)), pieceTitle: "F")
        let seen = StemSightings()
        try AudioStemExporter(request: request).run(into: try folder("progress"), progress: { seen.record($0) })
        let fractions = seen.steps.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "Batch progress went backwards.")
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(Set(seen.steps.map(\.stemIndex)), Set(request.stems.indices))
        XCTAssertLessThanOrEqual(fractions.first ?? 1, 1 / Double(request.stems.count))
    }

    // MARK: Naming

    func testStemNamesUsePieceAndLineAndAreDistinctAndValid() {
        let names = AudioExportNaming.stemFileNames(
            pieceTitle: "Suite: No. 1",
            lineNames: ["Violin", "violin", "Cello/Bass", "", "Violin", "Violin 2"],
            format: .wav
        )
        XCTAssertEqual(names, [
            "Suite- No. 1 — Violin.wav",
            "Suite- No. 1 — violin 2.wav",
            "Suite- No. 1 — Cello-Bass.wav",
            "Suite- No. 1 — Line 4.wav",
            "Suite- No. 1 — Violin 3.wav",
            "Suite- No. 1 — Violin 2 2.wav",
        ])
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count)

        let long = AudioExportNaming.stemFileNames(
            pieceTitle: String(repeating: "é", count: 200),
            lineNames: ["x", "x"],
            format: .aiff
        )
        XCTAssertEqual(Set(long).count, 2)
        for name in long {
            XCTAssertLessThanOrEqual(name.utf8.count, AudioExportNaming.maximumFileNameBytes)
            XCTAssertTrue(name.hasSuffix(".aiff"))
        }
    }

    /// Renames reach the file names; a line without one keeps its own name.
    func testStemNamesHonourTheOwnersRenames() throws {
        let timeline = try twoLines()
        let ids = timeline.lines.map(\.id)
        let request = AudioStemExportRequest(
            mix: mixRequest(timeline), pieceTitle: "Two Lines", lineNames: [ids[0]: "Soprano"]
        )
        XCTAssertEqual(request.stems.map(\.name), ["Soprano", timeline.lines[1].name])
        XCTAssertEqual(request.stems[0].fileName, "Two Lines — Soprano.wav")
    }

    // MARK: The mix export is unchanged

    /// A mix request is still integer PCM at its own depth, with the master
    /// stage in, and its header is the pre-#90 44-byte PCM header.
    func testTheMixExportDefaultsAreUnchanged() throws {
        let request = mixRequest(try twoLines(), settings: .cdQuality)
        XCTAssertEqual(request.sampleEncoding, .integer(.bits16))
        XCTAssertFalse(request.bypassesMasterStage)

        let url = directory.appending(path: "mix.wav")
        let result = try AudioExporter(request: request).run(to: url)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(AudioExportTests.littleUInt16(bytes, 20), 1, "The mix is no longer PCM.")
        XCTAssertEqual(AudioExportTests.littleUInt16(bytes, 34), 16)
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(result.encoding, .integer(.bits16))
        XCTAssertLessThan(result.peakLevel, 1, "The ceiling is no longer on the mix.")
    }

    /// The stem exporter renders only through `AudioExporter`, the way the mix
    /// does — no render path of its own.
    func testTheStemExporterHasNoRenderPathOfItsOwn() throws {
        let source = try String(
            contentsOf: try AudioExportTests.sourceFile("AudioStemExport.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("AudioExporter(request: stemRequest).render("))
        for forbidden in [
            "renderOffline", "PlaybackEngine(", "synth_audio_core_render", "AVAudioSourceNode",
            "sin(", "AVAudioFile", "AVAudioConverter"
        ] {
            XCTAssertFalse(source.contains(forbidden), "AudioStemExport.swift mentions \(forbidden).")
        }
    }
}

// MARK: - Test doubles

/// Refuses to move anything out of the staging's `Replaced` folder, which is
/// what a restore does — the one move a failed publish must not lose.
private final class RestoreRefusingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.deletingLastPathComponent().lastPathComponent == "Replaced" {
            throw NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "A file with that name already exists."]
            )
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// Opens the first staged file normally and fails the second the way a full
/// disk does.
private final class FailingSecondOpener: StagingFileOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0

    func openForAppending(at url: URL) throws -> AppendableFile {
        lock.lock()
        opened += 1
        let count = opened
        lock.unlock()
        if count >= 2 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                userInfo: [NSLocalizedDescriptionKey: "There is no space left on the disk."]
            )
        }
        return try FileSystemStagingFileOpener().openForAppending(at: url)
    }
}

private final class StemSightings: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AudioStemExportProgress] = []

    func record(_ step: AudioStemExportProgress) {
        lock.lock()
        recorded.append(step)
        lock.unlock()
    }

    var steps: [AudioStemExportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var finishedFirstStem: Bool {
        steps.contains { $0.stemIndex == 0 && $0.stem.renderedFrames == $0.stem.totalFrames }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
