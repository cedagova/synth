import AVFoundation
import XCTest
@testable import SynthKit

/// Issue #25 (REQ-026): "the current piece exports with its active preset to
/// WAV or AIFF at CD quality or better, faithful to live playback including the
/// current humanization state; failures report clearly and leave no partial
/// file."
///
/// Every claim here is a measurement on real bytes. The determinism criteria are
/// digest comparisons rather than tolerances, following `OfflineRenderTests`:
/// an equality claim checked with a tolerance is not an equality claim. The
/// format criteria are checked twice on purpose — once by parsing the header
/// this code wrote, and once by handing the file to `AVAudioFile`, which is the
/// same decoder every other app on the Mac reaches for. The first says the
/// bytes are what we meant; only the second says another player can open them.
final class AudioExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "AudioExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private func fixtureTimeline(
        settings: RealizationSettings = .literal
    ) throws -> PerformanceTimeline {
        try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture(), settings: settings)
    }

    private func request(
        _ timeline: PerformanceTimeline,
        settings: AudioExportSettings = .cdQuality
    ) -> AudioExportRequest {
        AudioExportRequest(
            timeline: timeline,
            voices: .uniform(SynthPatchVoiceProvider()),
            settings: settings
        )
    }

    private func destination(_ name: String) -> URL {
        directory.appending(path: name)
    }

    // MARK: Repeat-export identity (REQ-026)

    /// **The headline criterion.** Export the same configuration twice; the two
    /// files are byte-identical.
    ///
    /// Whole-file rather than payload-only, because a header that varied — a
    /// timestamp, a writer signature — would make the files differ for a
    /// listener's checksum even with identical audio, and the issue asks for
    /// "identical audio content" from the owner's point of view.
    func testExportingTheSameConfigurationTwiceProducesIdenticalFiles() throws {
        let timeline = try fixtureTimeline()

        let first = destination("first.wav")
        let second = destination("second.wav")
        let firstResult = try AudioExporter(request: request(timeline)).run(to: first)
        let secondResult = try AudioExporter(request: request(timeline)).run(to: second)

        XCTAssertGreaterThan(firstResult.frameCount, 0, "The export produced no frames at all.")
        XCTAssertEqual(firstResult.frameCount, secondResult.frameCount)
        XCTAssertEqual(
            try Data(contentsOf: first), try Data(contentsOf: second),
            "Two exports of one unchanged configuration differed; the export is not deterministic."
        )
    }

    /// The same for AIFF, because the two writers quantize through the same code
    /// but lay bytes out differently, and determinism is a property of both.
    func testExportingTheSameConfigurationTwiceToAIFFProducesIdenticalFiles() throws {
        let timeline = try fixtureTimeline()
        let settings = AudioExportSettings(format: .aiff, sampleRate: .rate44100, bitDepth: .bits16)

        let first = destination("first.aiff")
        let second = destination("second.aiff")
        try AudioExporter(request: request(timeline, settings: settings)).run(to: first)
        try AudioExporter(request: request(timeline, settings: settings)).run(to: second)

        XCTAssertEqual(
            try Data(contentsOf: first), try Data(contentsOf: second),
            "Two AIFF exports of one unchanged configuration differed."
        )
    }

    /// A silent export would pass every determinism test perfectly, so prove the
    /// file contains the piece.
    func testTheExportedFileContainsAudioRatherThanSilence() throws {
        let timeline = try fixtureTimeline()
        let url = destination("audible.wav")
        let result = try AudioExporter(request: request(timeline)).run(to: url)

        XCTAssertGreaterThan(result.peakLevel, 0.01, "The export is effectively silent.")
        XCTAssertFalse(result.didClip, "The export reached full scale; the mix has no headroom.")

        let decoded = try Self.decode(url)
        XCTAssertGreaterThan(
            Self.rootMeanSquare(decoded.left), 0.001,
            "The file decodes to silence even though the render was not silent."
        )
    }

    // MARK: Export equals the live path's offline render (REQ-026)

    /// **The equality criterion.** The exported file, decoded back, is exactly
    /// the quantization of `PlaybackEngine.renderTimelineOffline` — the very
    /// call `OfflineRenderTests` uses to prove the live graph's behaviour.
    ///
    /// Sample-exact rather than statistical: both sides are integers, so any
    /// difference at all means the export took a different route through the
    /// engine than live playback does.
    func testTheExportedSamplesEqualAnOfflineRenderOfTheLivePath() throws {
        let timeline = try fixtureTimeline()
        let settings = AudioExportSettings.cdQuality

        let url = destination("equality.wav")
        try AudioExporter(request: request(timeline, settings: settings)).run(to: url)

        // The live path, rendered through the same public entry point the
        // playback tests use, at the export's own rate.
        let live = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: settings.sampleRate.hertz
        )
        let writer = AudioFileWriter(settings: settings, frameCount: Int64(live.frameCount))
        let expectedPayload = writer.encode(left: live.left[...], right: live.right[...])

        let exported = try Data(contentsOf: url)
        let headerCount = writer.header().count
        XCTAssertEqual(
            exported.count, headerCount + expectedPayload.count,
            "The exported file is not the length the live render implies."
        )
        XCTAssertEqual(
            exported.suffix(from: headerCount), expectedPayload,
            "The exported samples differ from an offline render of the live path."
        )
    }

    /// The structural half of the same claim: there is no second render path to
    /// drift from the first.
    ///
    /// `AudioExport.swift` must pull frames only through `PlaybackEngine`. This
    /// reads the shipped source back, the way `RealtimeSafetyTests` reads the
    /// render callback back, so that adding a private DSP loop to the exporter
    /// fails here rather than being caught by a listener a year later.
    func testTheExporterHasNoRenderPathOfItsOwn() throws {
        let source = try String(
            contentsOf: try Self.sourceFile("AudioExport.swift"), encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("engine.renderOffline(frameCount: wanted)"),
            "The exporter no longer pulls frames from PlaybackEngine."
        )
        // Every symbol that would mean a second implementation of what the C
        // core already does.
        for forbidden in [
            "synth_audio_core_render", "AVAudioSourceNode", "sin(", "for frame in",
            "AVAudioFile", "AVAudioConverter"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "AudioExport.swift mentions \(forbidden); an export must render only through "
                    + "PlaybackEngine, or REQ-026's equality stops being structural."
            )
        }
    }

    // MARK: Humanization (REQ-012 carried into the export)

    /// Humanization off and on produce correspondingly literal and humanized
    /// files, and each matches live playback of *that* state.
    ///
    /// Two assertions, and the second is the one that matters: files that merely
    /// differ would also differ if the export were reading the wrong field, so
    /// each file is checked against the offline render of its own timeline.
    func testHumanizationOffAndOnExportDifferentlyAndEachMatchesItsOwnLivePath() throws {
        let musicXML = MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 4)
        let literal = try AudioRenderFixtures.timeline(musicXML, settings: .literal)
        let humanized = try AudioRenderFixtures.timeline(
            musicXML,
            settings: RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        )

        XCTAssertNotEqual(
            literal.lines.flatMap { $0.events.map(\.onsetMicroseconds) },
            humanized.lines.flatMap { $0.events.map(\.onsetMicroseconds) },
            "The fixture realized identically both ways, so this test proves nothing."
        )

        let settings = AudioExportSettings.cdQuality
        let literalURL = destination("literal.wav")
        let humanizedURL = destination("humanized.wav")
        try AudioExporter(request: request(literal, settings: settings)).run(to: literalURL)
        try AudioExporter(request: request(humanized, settings: settings)).run(to: humanizedURL)

        XCTAssertNotEqual(
            try Data(contentsOf: literalURL), try Data(contentsOf: humanizedURL),
            "Humanization off and on exported to identical files."
        )

        for (url, timeline, label) in [
            (literalURL, literal, "literal"), (humanizedURL, humanized, "humanized")
        ] {
            let live = try PlaybackEngine.renderTimelineOffline(
                timeline, sampleRate: settings.sampleRate.hertz
            )
            let writer = AudioFileWriter(settings: settings, frameCount: Int64(live.frameCount))
            let expected = writer.encode(left: live.left[...], right: live.right[...])
            let exported = try Data(contentsOf: url)
            XCTAssertEqual(
                exported.suffix(from: writer.header().count), expected,
                "The \(label) export does not match live playback of the \(label) state."
            )
        }
    }

    // MARK: Format and quality (REQ-026's "CD quality or better")

    /// The settings surface cannot express anything below CD quality.
    func testEverySettingCombinationMeetsTheCDQualityFloor() {
        for format in AudioExportFormat.allCases {
            for rate in AudioExportSampleRate.allCases {
                for depth in AudioExportBitDepth.allCases {
                    let settings = AudioExportSettings(
                        format: format, sampleRate: rate, bitDepth: depth
                    )
                    XCTAssertTrue(
                        settings.meetsCDQualityFloor,
                        "\(settings.displayName) is below 44.1 kHz / 16-bit."
                    )
                }
            }
        }
        XCTAssertEqual(AudioExportSettings.cdQuality.sampleRate.rawValue, 44_100)
        XCTAssertEqual(AudioExportSettings.cdQuality.bitDepth.rawValue, 16)
    }

    /// The WAV header is exactly what a RIFF/WAVE reader expects, field by
    /// field, at every offered depth.
    func testTheWAVHeaderIsWellFormedAtEveryDepth() throws {
        let timeline = try fixtureTimeline()

        for depth in AudioExportBitDepth.allCases {
            let settings = AudioExportSettings(
                format: .wav, sampleRate: .rate44100, bitDepth: depth
            )
            let url = destination("header-\(depth.rawValue).wav")
            let result = try AudioExporter(request: request(timeline, settings: settings)).run(to: url)
            let data = try Data(contentsOf: url)

            XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
            XCTAssertEqual(Self.littleUInt32(data, 4), UInt32(data.count - 8), "RIFF size")
            XCTAssertEqual(Self.littleUInt32(data, 16), 16, "fmt chunk size")
            XCTAssertEqual(Self.littleUInt16(data, 20), 1, "format tag should be PCM")
            XCTAssertEqual(Self.littleUInt16(data, 22), 2, "channel count")
            XCTAssertEqual(Self.littleUInt32(data, 24), 44_100, "sample rate")
            XCTAssertEqual(
                Self.littleUInt32(data, 28), UInt32(44_100 * settings.bytesPerFrame), "byte rate"
            )
            XCTAssertEqual(Self.littleUInt16(data, 32), UInt16(settings.bytesPerFrame), "block align")
            XCTAssertEqual(Self.littleUInt16(data, 34), UInt16(depth.rawValue), "bit depth")
            XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
            XCTAssertEqual(
                Self.littleUInt32(data, 40),
                UInt32(result.frameCount * Int64(settings.bytesPerFrame)),
                "data chunk size"
            )
            XCTAssertEqual(Int64(data.count), result.byteCount, "reported size")
        }
    }

    /// The AIFF header likewise — including the 80-bit extended sample rate,
    /// which is the field a hand-written AIFF writer gets wrong.
    func testTheAIFFHeaderIsWellFormedAtEveryDepth() throws {
        let timeline = try fixtureTimeline()

        for depth in AudioExportBitDepth.allCases {
            let settings = AudioExportSettings(
                format: .aiff, sampleRate: .rate48000, bitDepth: depth
            )
            let url = destination("header-\(depth.rawValue).aiff")
            let result = try AudioExporter(request: request(timeline, settings: settings)).run(to: url)
            let data = try Data(contentsOf: url)

            XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "FORM")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "AIFF")
            XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "COMM")
            XCTAssertEqual(Self.bigUInt32(data, 4), UInt32(data.count - 8), "FORM size")
            XCTAssertEqual(Self.bigUInt32(data, 16), 18, "COMM chunk size")
            XCTAssertEqual(Self.bigUInt16(data, 20), 2, "channel count")
            XCTAssertEqual(Self.bigUInt32(data, 22), UInt32(result.frameCount), "frame count")
            XCTAssertEqual(Self.bigUInt16(data, 26), UInt16(depth.rawValue), "bit depth")
            XCTAssertEqual(String(decoding: data[38..<42], as: UTF8.self), "SSND")
            XCTAssertEqual(
                Self.bigUInt32(data, 42),
                UInt32(8 + result.frameCount * Int64(settings.bytesPerFrame)),
                "SSND chunk size"
            )
            XCTAssertEqual(Self.bigUInt32(data, 46), 0, "SSND offset")
            XCTAssertEqual(Self.bigUInt32(data, 50), 0, "SSND block size")
        }
    }

    /// The 80-bit extended encoding, checked against the values every AIFF file
    /// in the world carries.
    func testTheExtendedSampleRateEncodingMatchesTheKnownConstants() {
        // 44100 = 1.0772705078125 × 2^15 → exponent 16398 (0x400E)
        XCTAssertEqual(
            [UInt8](AudioFileWriter.extended80(44_100)),
            [0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(
            [UInt8](AudioFileWriter.extended80(48_000)),
            [0x40, 0x0E, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(
            [UInt8](AudioFileWriter.extended80(96_000)),
            [0x40, 0x0F, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
    }

    /// **The claim the header parse cannot make: another player can open it.**
    ///
    /// `AVAudioFile` is the system decoder — the one QuickTime Player, Music and
    /// every other Mac app reach for. If it reads back the right rate, channel
    /// count, depth and length, the file is a real file and not merely one whose
    /// header this suite agrees with.
    func testEveryFormatAndDepthOpensInTheSystemDecoderWithTheRightProperties() throws {
        let timeline = try fixtureTimeline()

        for format in AudioExportFormat.allCases {
            for depth in AudioExportBitDepth.allCases {
                let settings = AudioExportSettings(
                    format: format, sampleRate: .rate44100, bitDepth: depth
                )
                let url = destination("decode-\(format.rawValue)-\(depth.rawValue).\(format.fileExtension)")
                let result = try AudioExporter(request: request(timeline, settings: settings)).run(to: url)

                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(
                    file.fileFormat.sampleRate, 44_100, accuracy: 0.001,
                    "\(settings.displayName): the decoder read a different sample rate."
                )
                XCTAssertEqual(file.fileFormat.channelCount, 2, "\(settings.displayName): channels")
                XCTAssertEqual(
                    file.length, result.frameCount,
                    "\(settings.displayName): the decoder found a different number of frames."
                )
                XCTAssertEqual(
                    file.fileFormat.streamDescription.pointee.mBitsPerChannel,
                    UInt32(depth.rawValue),
                    "\(settings.displayName): the decoder read a different bit depth."
                )
            }
        }
    }

    /// WAV and AIFF of the same render decode to the same audio.
    ///
    /// The two writers share the quantizer and differ only in byte order, so a
    /// byte-order slip in one of them would show up here as two files that
    /// sound different — which no header check would catch.
    func testWAVAndAIFFOfTheSameRenderDecodeToTheSameAudio() throws {
        let timeline = try fixtureTimeline()

        let wav = destination("same.wav")
        let aiff = destination("same.aiff")
        try AudioExporter(request: request(
            timeline, settings: AudioExportSettings(format: .wav, sampleRate: .rate44100, bitDepth: .bits16)
        )).run(to: wav)
        try AudioExporter(request: request(
            timeline, settings: AudioExportSettings(format: .aiff, sampleRate: .rate44100, bitDepth: .bits16)
        )).run(to: aiff)

        let fromWAV = try Self.decode(wav)
        let fromAIFF = try Self.decode(aiff)
        XCTAssertEqual(fromWAV.left.count, fromAIFF.left.count)
        XCTAssertEqual(
            fromWAV.left, fromAIFF.left,
            "The WAV and the AIFF of one render decode to different left channels."
        )
        XCTAssertEqual(fromWAV.right, fromAIFF.right, "…and different right channels.")
    }

    /// Quantization saturates rather than wrapping, which is the difference
    /// between a hot mix sounding loud and it sounding like a fuzz box.
    func testQuantizationSaturatesAtFullScaleInsteadOfWrapping() {
        XCTAssertEqual(AudioFileWriter.quantize(1.0, maximum: 32_767, minimum: -32_768), 32_767)
        XCTAssertEqual(AudioFileWriter.quantize(-1.0, maximum: 32_767, minimum: -32_768), -32_768)
        XCTAssertEqual(AudioFileWriter.quantize(4.0, maximum: 32_767, minimum: -32_768), 32_767)
        XCTAssertEqual(AudioFileWriter.quantize(-4.0, maximum: 32_767, minimum: -32_768), -32_768)
        XCTAssertEqual(AudioFileWriter.quantize(0, maximum: 32_767, minimum: -32_768), 0)
        XCTAssertEqual(AudioFileWriter.quantize(.nan, maximum: 32_767, minimum: -32_768), 0)
        XCTAssertEqual(AudioFileWriter.quantize(.infinity, maximum: 32_767, minimum: -32_768), 0)
    }

    // MARK: The mixer travels with the export

    /// Muting a line in the preset mutes it in the file. Without this, an export
    /// would be of the piece rather than of the owner's *mix* of it.
    func testTheExportHonoursThePresetMixer() throws {
        let timeline = try fixtureTimeline()
        let lineIDs = timeline.lines.map(\.id)
        XCTAssertEqual(lineIDs.count, 2, "The fixture should have two lines.")

        let full = destination("full.wav")
        try AudioExporter(request: request(timeline)).run(to: full)

        var muted = LineMixerState.neutral
        muted.isMuted = true
        let mutedRequest = AudioExportRequest(
            timeline: timeline,
            voices: .uniform(SynthPatchVoiceProvider()),
            mixer: [lineIDs[0]: muted, lineIDs[1]: .neutral],
            settings: .cdQuality
        )
        let half = destination("half.wav")
        try AudioExporter(request: mutedRequest).run(to: half)

        let fullAudio = try Self.decode(full)
        let halfAudio = try Self.decode(half)
        XCTAssertLessThan(
            Self.rootMeanSquare(halfAudio.left), Self.rootMeanSquare(fullAudio.left),
            "Muting a line in the preset did not make the export quieter, so the mix is not reaching it."
        )
        XCTAssertGreaterThan(
            Self.rootMeanSquare(halfAudio.left), 0.0001,
            "Muting one line silenced the whole export."
        )
    }

    // MARK: Atomicity — cancel, disk-full, unusable destination

    /// A cancel leaves no partial file and says so.
    func testCancellingLeavesNoFileAtAllAndReportsClearly() throws {
        let timeline = try fixtureTimeline()
        let url = destination("cancelled.wav")

        let cancellation = AudioExportCancellation()
        cancellation.cancel()   // already cancelled: the first block never runs

        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(to: url, cancellation: cancellation)
        ) { error in
            XCTAssertEqual(error as? AudioExportError, .cancelled)
            let localized = error as? LocalizedError
            XCTAssertEqual(localized?.errorDescription, "The export was cancelled.")
            XCTAssertNotNil(localized?.recoverySuggestion)
        }
        assertNothingWasLeftBehind(at: url)
    }

    /// A cancel that arrives *after* some audio has been written still leaves
    /// nothing — the case that would catch an implementation that wrote straight
    /// to the destination.
    func testCancellingPartWayThroughStillLeavesNoFile() throws {
        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 8)
        )
        let url = destination("cancelled-midway.wav")

        let cancellation = AudioExportCancellation()
        let seen = Counter()
        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(
                to: url,
                progress: { _ in
                    // Two blocks of real audio are on disk in the staged file
                    // before this fires.
                    if seen.increment() >= 2 { cancellation.cancel() }
                },
                cancellation: cancellation
            )
        ) { XCTAssertEqual($0 as? AudioExportError, .cancelled) }

        XCTAssertGreaterThanOrEqual(seen.value, 2, "The export should have rendered some audio first.")
        assertNothingWasLeftBehind(at: url)
    }

    /// A full disk, injected the way `InstrumentDownloadTests` injects it: the
    /// production write path, with a writer that throws exactly the `ENOSPC`
    /// `NSError` Foundation throws when the disk is genuinely full.
    func testAFullDiskLeavesNoPartialFileAndExplainsItself() throws {
        let timeline = try fixtureTimeline()
        let url = destination("full-disk.wav")

        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(
                to: url, opener: FullDiskOpener(bytesBeforeFailure: 4_096)
            )
        ) { error in
            guard case .writeFailed(_, let reason)? = error as? AudioExportError else {
                return XCTFail("Expected a write failure, got \(error)")
            }
            XCTAssertTrue(
                reason.lowercased().contains("space"),
                "The failure should name the real reason; got “\(reason)”."
            )
            let localized = try? XCTUnwrap(error as? LocalizedError)
            XCTAssertTrue(
                localized?.recoverySuggestion?.contains("disk space") == true,
                "The owner should be told to free up space."
            )
        }
        assertNothingWasLeftBehind(at: url)
    }

    /// A disk that fills at the *flush* rather than at a write.
    ///
    /// Separate from the test above, and it caught a real gap: closing a file
    /// handle is a write, so a handle holding buffered bytes reports `ENOSPC`
    /// from `close(2)` rather than from `write(2)`. That path was reaching the
    /// owner as a bare POSIX string with no recovery, and — worse — it was the
    /// one failure that could still have published a file whose tail never
    /// landed.
    func testADiskThatFillsAtTheFlushFailsTheExportAndExplainsItself() throws {
        let timeline = try fixtureTimeline()
        let url = destination("full-at-close.wav")

        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(
                to: url, opener: FullDiskOpener(bytesBeforeFailure: .max, failsOnClose: true)
            )
        ) { error in
            guard case .writeFailed(_, let reason)? = error as? AudioExportError else {
                return XCTFail("Expected a write failure, got \(error)")
            }
            XCTAssertTrue(
                reason.lowercased().contains("space"),
                "The flush failure should name the real reason; got “\(reason)”."
            )
            XCTAssertTrue(
                (error as? LocalizedError)?.recoverySuggestion?.contains("disk space") == true,
                "The owner should be told to free up space here too."
            )
        }
        assertNothingWasLeftBehind(at: url)
    }

    /// A disk with no room for the staged file at all — the failure lands at
    /// `open(2)` rather than at a write, and must still read as a full disk
    /// rather than as "choose another folder", because the owner's folder is
    /// not the one that is full.
    func testADiskWithNoRoomToEvenStartFailsAsAWriteFailure() throws {
        let timeline = try fixtureTimeline()
        let url = destination("no-room.wav")

        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(
                to: url, opener: FullDiskOpener(bytesBeforeFailure: 0, failsOnOpen: true)
            )
        ) { error in
            guard case .writeFailed? = error as? AudioExportError else {
                return XCTFail("Expected a write failure, got \(error)")
            }
            XCTAssertTrue(
                (error as? LocalizedError)?.recoverySuggestion?.contains("disk space") == true,
                "The owner should be told to free up space, not to pick another folder."
            )
        }
        assertNothingWasLeftBehind(at: url)
    }

    /// **The strongest form of the atomicity claim:** a failed overwrite leaves
    /// the *previous* export exactly as it was.
    func testAFailedExportLeavesAnExistingFileUntouched() throws {
        let timeline = try fixtureTimeline()
        let url = destination("existing.wav")

        try AudioExporter(request: request(timeline)).run(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try AudioExporter(request: request(timeline)).run(
                to: url, opener: FullDiskOpener(bytesBeforeFailure: 4_096)
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: url), before,
            "A failed export changed the file that was already there."
        )
        XCTAssertEqual(try siblings(), ["existing.wav"], "A staged file was left behind.")
    }

    /// A successful overwrite does replace it.
    func testASuccessfulExportReplacesAnExistingFile() throws {
        let url = destination("replaced.wav")

        try AudioExporter(request: request(try fixtureTimeline())).run(to: url)
        let short = try Data(contentsOf: url)

        let longer = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 6)
        )
        try AudioExporter(request: request(longer)).run(to: url)

        XCTAssertNotEqual(try Data(contentsOf: url), short, "The second export did not replace the first.")
        XCTAssertEqual(try siblings(), ["replaced.wav"], "A staged file was left behind.")
    }

    /// A destination in a folder that does not exist fails before anything is
    /// rendered, and says which folder.
    func testAMissingDestinationFolderFailsClearlyAndWritesNothing() throws {
        let timeline = try fixtureTimeline()
        let url = directory.appending(path: "no-such-folder").appending(path: "x.wav")

        XCTAssertThrowsError(try AudioExporter(request: request(timeline)).run(to: url)) { error in
            guard case .destinationUnusable(let path, _)? = error as? AudioExportError else {
                return XCTFail("Expected a destination failure, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("no-such-folder"), "The message should name the folder.")
        }
        XCTAssertEqual(try siblings(), [], "Nothing should have been written.")
    }

    // MARK: Progress

    /// Progress reaches 1 exactly once, never goes backwards, and describes the
    /// piece rather than the file.
    func testProgressRunsMonotonicallyToCompletion() throws {
        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 6)
        )
        let url = destination("progress.wav")

        let recorder = ProgressRecorder()
        let result = try AudioExporter(request: request(timeline)).run(
            to: url, progress: { recorder.record($0) }
        )

        let steps = recorder.steps
        XCTAssertGreaterThan(steps.count, 2, "A multi-block render should report several times.")
        XCTAssertEqual(steps.last?.fraction, 1.0, "Progress never reached completion.")
        XCTAssertEqual(steps.last?.renderedFrames, result.frameCount)
        XCTAssertEqual(
            steps.last?.totalSeconds ?? 0, result.seconds, accuracy: 0.0001,
            "The reported length should be the piece's, not the file's."
        )
        for (previous, next) in zip(steps, steps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next.renderedFrames, previous.renderedFrames, "Progress went backwards."
            )
        }
    }

    // MARK: Naming

    /// **Everything the app suggests can actually be created.**
    ///
    /// The property, not the mechanism: the suggested name must fit `NAME_MAX`,
    /// and the file staging derives from it must too. It held only by accident
    /// once — the suggestion cap and the staged sibling's cap were derived
    /// separately and disagreed by 48 bytes — so it is asserted directly, and
    /// the assertion survives the staging scheme changing underneath it.
    func testEverySuggestedNameCanActuallyBeCreated() throws {
        for format in AudioExportFormat.allCases {
            for titleLength in [1, 60, 200, 400, 4_000] {
                for scalar in ["a", "é", "字"] {
                    let suggested = AudioExportNaming.suggestedFileName(
                        pieceTitle: String(repeating: scalar, count: titleLength),
                        presetName: String(repeating: scalar, count: titleLength),
                        format: format
                    )
                    XCTAssertLessThanOrEqual(
                        suggested.utf8.count, AudioExportNaming.maximumFileNameBytes,
                        "The suggestion is longer than any macOS filesystem accepts."
                    )
                    // The filesystem is the authority, not the arithmetic.
                    let url = destination(suggested)
                    XCTAssertTrue(
                        FileManager.default.createFile(
                            atPath: url.path(percentEncoded: false), contents: Data()
                        ),
                        "“\(suggested.prefix(24))…” (\(suggested.utf8.count) bytes) could not be created."
                    )
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// A name the *owner* typed, right at the filesystem's own limit, exports.
    ///
    /// End to end and onto a real filesystem, because the bug this exists for
    /// is `ENAMETOOLONG` from `open(2)`, which no test of the naming functions
    /// alone can reach — and because it is also the case that would break if
    /// staging ever went back to wrapping the destination's name.
    func testADestinationNameAtTheFilesystemLimitStillExports() throws {
        let timeline = try fixtureTimeline()

        // 125 two-byte characters plus one one-byte character plus ".wav".
        let stem = String(repeating: "é", count: 125) + "a"
        let name = "\(stem).wav"
        XCTAssertEqual(name.utf8.count, 255, "The fixture is not at the limit it exists to test.")

        let url = destination(name)
        let result = try AudioExporter(request: request(timeline)).run(to: url)

        XCTAssertEqual(result.url.lastPathComponent, name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        XCTAssertEqual(try siblings(), [name], "Something was left beside the export.")
        XCTAssertEqual(Int64(try Data(contentsOf: url).count), result.byteCount)
    }

    // MARK: Where the bytes are staged

    /// **The staging never touches the destination's folder.**
    ///
    /// This is the claim the sandbox depends on. A save panel grants an
    /// extension for the exact path the owner picked; a hand-rolled `open(2)`
    /// at a differently named file beside it is not covered by anything Apple
    /// documents, so an export that passed every test here could still have
    /// failed on the owner's Desktop. Staging goes to the system's
    /// item-replacement directory instead, and this asserts it: while the export
    /// is mid-render, the destination's folder contains nothing at all.
    func testNothingIsEverWrittenIntoTheDestinationsFolderUntilThePublish() throws {
        let timeline = try AudioRenderFixtures.timeline(
            MusicXMLScoreFixtures.keyboardFugueExposition(measureCount: 8)
        )
        let url = destination("staged-elsewhere.wav")

        let seen = Counter()
        let sightings = FolderSightings()
        let result = try AudioExporter(request: request(timeline)).run(
            to: url,
            progress: { [directory] _ in
                seen.increment()
                sightings.record(
                    (try? FileManager.default.contentsOfDirectory(
                        atPath: directory!.path(percentEncoded: false)
                    )) ?? ["<unreadable>"]
                )
            }
        )

        XCTAssertGreaterThan(seen.value, 2, "The render was too short to observe.")
        for (index, contents) in sightings.observed.enumerated() {
            XCTAssertEqual(
                contents, [],
                "Block \(index) saw \(contents) in the destination's folder; staging must not "
                    + "write there, because a save panel's grant does not cover it."
            )
        }
        XCTAssertEqual(try siblings(), ["staged-elsewhere.wav"])
        XCTAssertEqual(Int64(try Data(contentsOf: url).count), result.byteCount)
    }

    /// The staged file is on the destination's own volume, which is what keeps
    /// the publish a rename rather than a copy — and therefore atomic.
    func testStagingSitsOnTheSameVolumeAsTheDestination() throws {
        let url = destination("volume.wav")
        let staging = try AudioExportStaging(destination: url, fileManager: .default)
        defer { staging.discard() }

        func volume(_ candidate: URL) throws -> (any NSObjectProtocol)? {
            try candidate.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        }
        let stagedVolume = try XCTUnwrap(volume(staging.replacementDirectory))
        let destinationVolume = try XCTUnwrap(volume(directory))
        XCTAssertTrue(
            stagedVolume.isEqual(destinationVolume),
            "The staged file is on another volume, so the publish would be a copy, not a rename."
        )
        XCTAssertFalse(
            staging.stagedURL.deletingLastPathComponent().standardizedFileURL
                == url.deletingLastPathComponent().standardizedFileURL,
            "Staging is back in the destination's own folder."
        )
        XCTAssertEqual(
            staging.stagedURL.lastPathComponent, url.lastPathComponent,
            "The staged file should carry the destination's own name."
        )
    }

    /// Two exports to the same destination name at once do not collide, without
    /// needing a unique file name of their own.
    func testTwoStagingsForOneDestinationDoNotCollide() throws {
        let url = destination("shared-name.wav")
        let first = try AudioExportStaging(destination: url, fileManager: .default)
        let second = try AudioExportStaging(destination: url, fileManager: .default)
        defer { first.discard(); second.discard() }

        XCTAssertNotEqual(
            first.stagedURL, second.stagedURL,
            "Two concurrent exports of one name would write over each other."
        )
    }

    // MARK: The container's own size limit

    /// **A render too long for the container is refused, not written badly.**
    ///
    /// RIFF and IFF both describe their sizes in 32 bits, so past 4 GiB a
    /// header can only state a length the file then exceeds. That is the one
    /// failure this leaf must never produce: a file that reports success and
    /// decodes wrong somewhere else. Checked on the writer, where the decision
    /// is made, and through the exporter, where it has to be acted on.
    func testARenderTooLongForTheContainerIsRefusedBeforeAnythingIsWritten() throws {
        let limit = AudioFileWriter.maximumFileByteCount

        for format in AudioExportFormat.allCases {
            let settings = AudioExportSettings(
                format: format, sampleRate: .rate96000, bitDepth: .bits24
            )
            // One frame past what the container can describe.
            let frames = limit / Int64(settings.bytesPerFrame) + 1
            let writer = AudioFileWriter(settings: settings, frameCount: frames)
            XCTAssertTrue(
                writer.exceedsContainerLimit,
                "\(format.displayName) accepted \(frames) frames, which it cannot describe."
            )
            XCTAssertLessThanOrEqual(
                AudioFileWriter(
                    settings: settings, frameCount: (limit - Int64(writer.headerByteCount)) / Int64(settings.bytesPerFrame)
                ).totalByteCount,
                limit,
                "The largest accepted render is itself over the limit."
            )
        }

        // …and the exporter refuses it, with a message that names the piece's
        // length and the way out. Reached without rendering two hours of audio
        // by making the writer's own limit the thing under test above and the
        // exporter's guard the thing under test here.
        let settings = AudioExportSettings(format: .wav, sampleRate: .rate96000, bitDepth: .bits24)
        let frames = limit / Int64(settings.bytesPerFrame) + 1
        let writer = AudioFileWriter(settings: settings, frameCount: frames)
        let error = AudioExportError.tooLongForContainer(
            format: .wav,
            minutes: Int((Double(frames) / settings.sampleRate.hertz / 60).rounded()),
            byteCount: writer.totalByteCount,
            limitByteCount: limit
        )
        let summary = try XCTUnwrap((error as LocalizedError).errorDescription)
        XCTAssertTrue(summary.contains("WAV"), "The message should name the format: “\(summary)”")
        XCTAssertTrue(
            summary.contains("minutes"), "The message should name the length: “\(summary)”"
        )
        let recovery = try XCTUnwrap((error as LocalizedError).recoverySuggestion)
        XCTAssertTrue(
            recovery.contains("lower sample rate"),
            "The owner should be told how to get an export that works: “\(recovery)”"
        )
        XCTAssertTrue(recovery.contains("Nothing was written."))
    }

    /// Everything the app can actually export today is comfortably inside the
    /// limit, so the guard above is a boundary rather than a restriction.
    func testARealisticExportIsNowhereNearTheContainerLimit() throws {
        let timeline = try fixtureTimeline()
        let settings = AudioExportSettings(format: .wav, sampleRate: .rate96000, bitDepth: .bits24)
        let url = destination("headroom.wav")
        let result = try AudioExporter(request: request(timeline, settings: settings)).run(to: url)

        XCTAssertLessThan(result.byteCount, AudioFileWriter.maximumFileByteCount / 1_000)
    }

    func testTheSuggestedFileNameCombinesPieceAndPresetSafely() {
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(
                pieceTitle: "Prelude in C", presetName: "Chamber", format: .wav
            ),
            "Prelude in C — Chamber.wav"
        )
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(
                pieceTitle: "Prelude in C", presetName: nil, format: .aiff
            ),
            "Prelude in C.aiff"
        )
        // A title with a path separator in it must not become a path.
        let dangerous = AudioExportNaming.suggestedFileName(
            pieceTitle: "BWV 846/1: Prelude", presetName: nil, format: .wav
        )
        XCTAssertFalse(dangerous.contains("/"), "A slash in the title escaped into the file name.")
        XCTAssertFalse(dangerous.contains(":"), "A colon in the title escaped into the file name.")
        XCTAssertEqual(
            AudioExportNaming.suggestedFileName(pieceTitle: "   ", presetName: nil, format: .wav),
            "Untitled piece.wav"
        )
        // A pathological title still yields a name a filesystem accepts.
        let long = AudioExportNaming.suggestedFileName(
            pieceTitle: String(repeating: "é", count: 400), presetName: "P", format: .aiff
        )
        XCTAssertLessThanOrEqual(long.utf8.count, AudioExportNaming.maximumFileNameBytes)
        XCTAssertTrue(long.hasSuffix(".aiff"))
    }

    // MARK: Helpers

    /// Neither the destination nor any staged sibling exists.
    private func assertNothingWasLeftBehind(
        at url: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "A partial file was left at the destination.", file: file, line: line
        )
        XCTAssertEqual(
            (try? siblings()) ?? ["<unreadable>"], [],
            "A staged file was left behind in the destination folder.", file: file, line: line
        )
    }

    /// Everything in the test directory, hidden entries included — a staged file
    /// is dot-prefixed, so `skipsHiddenFiles` would hide the very thing this
    /// checks for.
    private func siblings() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .sorted()
    }

    /// A shipped `SynthKit` source file, found the way `NoNetworkBaselineTests`
    /// finds one: by walking up from this file to the directory holding
    /// `Synth.xcodeproj`. Relative hops from `#filePath` would break under any
    /// build that mirrors the sources somewhere else.
    static func sourceFile(_ name: String) throws -> URL {
        var candidate = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = candidate.appending(path: "Synth.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                return candidate.appending(path: "SynthKit").appending(path: name)
            }
            candidate = candidate.deletingLastPathComponent()
        }
        // Never skipped: a guard that cannot find what it guards is a failure.
        throw SourceFileNotFound(name: name, searchedUpwardsFrom: #filePath)
    }

    struct SourceFileNotFound: Error, CustomStringConvertible {
        let name: String
        let searchedUpwardsFrom: String
        var description: String {
            "Could not find SynthKit/\(name) above \(searchedUpwardsFrom); "
                + "the export's structural guards cannot run."
        }
    }

    /// Decode a written file back through the system decoder, as deinterleaved
    /// float — the form every other measurement in the audio suites works in.
    static func decode(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: file.fileFormat.sampleRate,
            channels: file.fileFormat.channelCount
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioExportError.nothingToRender
        }
        try file.read(into: buffer)

        let frames = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData else { return ([], []) }
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let right = buffer.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: frames))
            : left
        return (left, right)
    }

    /// Energy in a decoded channel. `AudioRenderFixtures.rms` takes a time
    /// window; a whole-file figure is what every claim here wants.
    static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in samples { total += Double(sample) * Double(sample) }
        return (total / Double(samples.count)).squareRoot()
    }

    static func littleUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func littleUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }

    static func bigUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func bigUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[offset + $1]) }
    }
}

// MARK: - Test doubles

/// A writer that accepts `bytesBeforeFailure` bytes and then fails exactly the
/// way Foundation does when the volume is full.
///
/// The same technique `AssetStaging`'s `AppendableFile` protocol exists for, and
/// the same `NSError` domain and code — so what is under test is the production
/// failure path, not a bespoke one.
private struct FullDiskOpener: StagingFileOpening {
    let bytesBeforeFailure: Int
    /// Fail at the flush instead of at a write — where a handle holding
    /// buffered bytes actually reports a full disk.
    var failsOnClose = false

    /// Fail before a handle exists at all, which is what a volume with no room
    /// left does to `open(2)`.
    var failsOnOpen = false

    func openForAppending(at url: URL) throws -> AppendableFile {
        if failsOnOpen {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOSPC),
                userInfo: [NSLocalizedDescriptionKey: "There is no space left on the disk."]
            )
        }
        let real = try FileSystemStagingFileOpener().openForAppending(at: url)
        return FullDiskFile(
            underlying: real, budget: bytesBeforeFailure, failsOnClose: failsOnClose
        )
    }
}

private final class FullDiskFile: AppendableFile {
    private let underlying: AppendableFile
    private var remaining: Int
    private let failsOnClose: Bool

    init(underlying: AppendableFile, budget: Int, failsOnClose: Bool = false) {
        self.underlying = underlying
        self.remaining = budget
        self.failsOnClose = failsOnClose
    }

    private static var outOfSpace: NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "There is no space left on the disk."]
        )
    }

    func append(_ data: Data) throws {
        guard data.count <= remaining else {
            // Write what fits first, so the staged file genuinely contains
            // partial audio when the failure lands.
            if remaining > 0 { try underlying.append(data.prefix(remaining)) }
            remaining = 0
            throw Self.outOfSpace
        }
        remaining -= data.count
        try underlying.append(data)
    }

    func close() throws {
        try underlying.close()
        if failsOnClose { throw Self.outOfSpace }
    }
}

/// Progress arrives on the export's thread; these two collect it without racing
/// the test's own reads.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AudioExportProgress] = []

    func record(_ step: AudioExportProgress) {
        lock.lock()
        recorded.append(step)
        lock.unlock()
    }

    var steps: [AudioExportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// What the destination's folder contained at each progress step, collected
/// from the render thread.
private final class FolderSightings: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func record(_ contents: [String]) {
        lock.lock()
        recorded.append(contents.sorted())
        lock.unlock()
    }

    var observed: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
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
