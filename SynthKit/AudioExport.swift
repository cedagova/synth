import Foundation

/// Renders a prepared performance to a WAV or AIFF file (REQ-026).
///
/// **There is no render code in this file.** That is the whole design, and it
/// is what makes "export equals live playback" a structural fact instead of a
/// promise to keep two implementations in step. AD2 says the app has one graph
/// with two modes; `PlaybackEngine.rebuildGraph` is the only constructor and
/// `renderOffline` is the only way to pull frames out of it without hardware.
/// So an export is `PlaybackEngine` in `.offline` mode plus a file writer, and
/// the only thing this type adds is *when* to stop, *where* to put the bytes,
/// and *how* to leave nothing behind when it fails.
///
/// ## Thread ownership
///
/// `PlaybackEngine` is single-owner and not internally synchronised. An export
/// is the one place in the app that legitimately runs one off the main thread,
/// so that a long render keeps the UI responsive and cancelable — and that is
/// exactly the kind of claim that rots silently.
///
/// So the ownership is enforced rather than documented:
///
/// * the engine is **created inside `run(...)`** and destroyed before it
///   returns, so no other thread has ever held a reference to it;
/// * `run(...)` records the thread that created it and re-checks the identity
///   before every render block, throwing `.engineCrossedThreads` rather than
///   racing if it ever changes; and
/// * the only object shared with another thread is
///   `AudioExportCancellation`, whose entire mutable state is one `Bool`
///   behind one lock.
///
/// The live-playback engine is untouched: an export takes a `PerformanceTimeline`,
/// a `LineVoiceAssignment` and mixer *values*, never a `PlaybackEngine`.
/// `AudioExportConcurrencyTests` runs all three of these claims in CI.
public struct AudioExporter: Sendable {
    /// Frames pulled from the graph per progress step.
    ///
    /// Four render blocks' worth. Big enough that the per-call buffer setup in
    /// `renderOffline` is noise, small enough that a cancel lands within a few
    /// milliseconds of CPU and the progress bar moves about sixty times over a
    /// four-minute piece at 48 kHz.
    public static let blockFrames: Int64 = 16_384

    public let request: AudioExportRequest

    public init(request: AudioExportRequest) {
        self.request = request
    }

    /// Render and publish, blocking the calling thread until it is done.
    ///
    /// Synchronous on purpose: the caller decides which thread owns this work,
    /// and a synchronous body is what lets the engine's lifetime be exactly one
    /// stack frame on exactly one thread.
    ///
    /// - Parameters:
    ///   - destination: where the finished file goes. Its directory must exist.
    ///   - progress: called on **this** thread after every block. Keep it cheap;
    ///     a UI caller should hop to the main actor inside it.
    ///   - cancellation: polled between blocks. Safe to cancel from any thread.
    ///   - opener: how staged bytes are written. The default writes real files;
    ///     `AudioExportTests` substitutes one that fails the way a full disk
    ///     does, so the atomicity claim is proved against the production path.
    @discardableResult
    public func run(
        to destination: URL,
        progress: (@Sendable (AudioExportProgress) -> Void)? = nil,
        cancellation: AudioExportCancellation = AudioExportCancellation(),
        opener: StagingFileOpening = FileSystemStagingFileOpener(),
        fileManager: FileManager = .default
    ) throws -> AudioExportResult {
        let started = Date()
        let staging = try AudioExportStaging(
            destination: destination, fileManager: fileManager
        )

        do {
            let result = try renderAndStage(
                staging: staging,
                progress: progress,
                cancellation: cancellation,
                opener: opener,
                fileManager: fileManager,
                started: started
            )
            return result
        } catch {
            // Every failure path lands here, cancel included: the staged file
            // goes and the destination is never touched. This is the whole of
            // "a failed export leaves no partial file".
            staging.discard()
            throw error
        }
    }

    private func renderAndStage(
        staging: AudioExportStaging,
        progress: (@Sendable (AudioExportProgress) -> Void)?,
        cancellation: AudioExportCancellation,
        opener: StagingFileOpening,
        fileManager: FileManager,
        started: Date
    ) throws -> AudioExportResult {
        // ── The engine's whole life starts here and ends at the end of this
        // function. `owner` is the thread that built it.
        let owner = Thread.current
        let ranOnMainThread = owner.isMainThread

        let engine = PlaybackEngine(voices: request.voices)
        try engine.setRenderMode(.offline(sampleRate: request.settings.sampleRate.hertz))
        try engine.load(timeline: request.timeline)

        guard let program = engine.loadedProgram else {
            throw AudioExportError.nothingToRender
        }
        request.applyMixer(to: engine)
        engine.play()

        let totalFrames = program.totalFrames
        guard totalFrames > 0 else { throw AudioExportError.nothingToRender }

        let writer = AudioFileWriter(settings: request.settings, frameCount: totalFrames)
        let file = try staging.open(with: opener)
        defer { try? file.close() }

        try staging.write(writer.header(), to: file)

        var rendered: Int64 = 0
        var ownershipChecks = 0
        var peak: Float = 0

        while rendered < totalFrames {
            if cancellation.isCancelled { throw AudioExportError.cancelled }

            ownershipChecks += 1
            guard Thread.current === owner else {
                throw AudioExportError.engineCrossedThreads
            }

            let wanted = min(Self.blockFrames, totalFrames - rendered)
            let block = try engine.renderOffline(frameCount: wanted)
            guard block.frameCount > 0 else {
                throw AudioExportError.renderStopped(
                    atFrame: rendered, expectedFrames: totalFrames
                )
            }
            for sample in block.left where abs(sample) > peak { peak = abs(sample) }
            for sample in block.right where abs(sample) > peak { peak = abs(sample) }

            try staging.write(
                writer.encode(left: block.left[...], right: block.right[...]), to: file
            )
            rendered += Int64(block.frameCount)

            progress?(
                AudioExportProgress(
                    renderedFrames: min(rendered, totalFrames),
                    totalFrames: totalFrames,
                    sampleRate: request.settings.sampleRate.hertz,
                    elapsed: Date().timeIntervalSince(started)
                )
            )
        }

        guard rendered == totalFrames else {
            throw AudioExportError.renderStopped(
                atFrame: rendered, expectedFrames: totalFrames
            )
        }

        // The last chance to stop before anything is observable at the
        // destination: a cancel that arrived during the final block still
        // leaves nothing behind.
        if cancellation.isCancelled { throw AudioExportError.cancelled }

        try file.close()
        try staging.publish()

        return AudioExportResult(
            url: staging.destination,
            settings: request.settings,
            frameCount: totalFrames,
            byteCount: writer.totalByteCount,
            peakLevel: peak,
            duration: Date().timeIntervalSince(started),
            ranOnMainThread: ranOnMainThread,
            ownershipChecks: ownershipChecks
        )
    }
}

// MARK: - What is being exported

/// One export's complete input: the same three things live playback renders
/// from, plus the file settings.
///
/// **Values only, deliberately.** There is no `PlaybackEngine` here and no
/// closure over the app's models, so a request can cross to a background thread
/// with nothing to race on and it is impossible for an export to reach into the
/// engine the owner is listening to.
public struct AudioExportRequest: Sendable {
    /// The realized performance — already carries the humanization setting that
    /// produced it, which is why an export cannot disagree with live playback
    /// about how humanized the piece is.
    public let timeline: PerformanceTimeline

    /// One sound per line, frozen. The same assignment
    /// `PresetPerformance.voiceAssignment` gives the live engine, minus the
    /// live-edit channels, which an export must not have: a render is of the
    /// sounds as the library stores them.
    public let voices: LineVoiceAssignment

    /// The active preset's mixer, addressed by line identity.
    public let mixer: [ScoreLineID: LineMixerState]

    public let masterGain: Float

    public let settings: AudioExportSettings

    public init(
        timeline: PerformanceTimeline,
        voices: LineVoiceAssignment,
        mixer: [ScoreLineID: LineMixerState] = [:],
        masterGain: Float = 1,
        settings: AudioExportSettings = .standard
    ) {
        self.timeline = timeline
        self.voices = voices
        self.mixer = mixer
        self.masterGain = masterGain
        self.settings = settings
    }

    /// Every line of the loaded program written, including ones the preset does
    /// not mention — the same rule `PresetPerformance.applyMixer` follows, and
    /// for the same reason: an unwritten strip would inherit whatever the fresh
    /// program happened to start at.
    func applyMixer(to engine: PlaybackEngine) {
        guard let program = engine.loadedProgram else { return }
        for (index, lineID) in program.lineIDs.enumerated() {
            guard let strip = engine.mixer(forLineAt: index) else { continue }
            let state = mixer[lineID] ?? .neutral
            strip.gain = Float(state.volume)
            strip.pan = Float(state.pan)
            strip.isMuted = state.isMuted
            strip.isSoloed = state.isSoloed
            strip.roomSend = Float(state.roomSend)
        }
        engine.masterGain = masterGain
    }
}

/// Builds a request from a resolved preset, so the app has one call rather than
/// four things to remember to line up.
extension PresetPerformance {
    /// This preset as an export request: the frozen sounds it resolves to and
    /// the mix it stores.
    ///
    /// - Parameter instruments: the sampled-instrument cache. Passing the app's
    ///   own is what makes an instrument line export as its samples rather than
    ///   as silence.
    public func exportRequest(
        timeline: PerformanceTimeline,
        settings: AudioExportSettings,
        instruments: SampledInstrumentLibrary? = nil
    ) -> AudioExportRequest {
        AudioExportRequest(
            timeline: timeline,
            // `live: nil` on purpose. A live channel renders whatever the sound
            // editor currently holds; an export renders what the library
            // stores. Everything else — which provider a line gets, whether a
            // missing instrument is silent or substituted — is
            // `ResolvedLine.voiceProvider`'s single decision, shared with
            // live playback.
            voices: voiceAssignment(instruments: instruments, live: nil),
            mixer: Dictionary(
                lines.map { ($0.lineID, $0.mixer) }, uniquingKeysWith: { first, _ in first }
            ),
            masterGain: 1,
            settings: settings
        )
    }
}

// MARK: - Progress, cancellation, results

/// How far an export has got.
public struct AudioExportProgress: Sendable, Equatable {
    public let renderedFrames: Int64
    public let totalFrames: Int64
    public let sampleRate: Double
    /// Wall-clock seconds since the export started.
    public let elapsed: TimeInterval

    public init(
        renderedFrames: Int64, totalFrames: Int64, sampleRate: Double, elapsed: TimeInterval
    ) {
        self.renderedFrames = renderedFrames
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.elapsed = elapsed
    }

    /// 0…1.
    public var fraction: Double {
        totalFrames > 0 ? min(1, max(0, Double(renderedFrames) / Double(totalFrames))) : 0
    }

    /// Seconds of music written so far.
    public var renderedSeconds: Double {
        sampleRate > 0 ? Double(renderedFrames) / sampleRate : 0
    }

    public var totalSeconds: Double {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }

    /// How much faster than real time this is going, or nil before there is
    /// enough elapsed time to say anything meaningful.
    public var speedMultiple: Double? {
        guard elapsed > 0.25, renderedSeconds > 0 else { return nil }
        return renderedSeconds / elapsed
    }
}

/// The one thing an export shares with the thread that started it.
///
/// A class rather than a flag on the exporter because cancelling is inherently
/// cross-thread: the owner presses Cancel on the main thread while the render
/// owns another. One `Bool` behind one `NSLock` is the entire shared state, so
/// there is nothing else for the two threads to disagree about.
public final class AudioExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Ask the export to stop. Idempotent, and safe from any thread.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// What a finished export produced.
public struct AudioExportResult: Sendable, Equatable {
    public let url: URL
    public let settings: AudioExportSettings
    public let frameCount: Int64
    public let byteCount: Int64
    /// Largest absolute sample in the render, so a clipped export is a number
    /// rather than something the owner discovers by listening.
    public let peakLevel: Float
    /// Wall-clock seconds the export took.
    public let duration: TimeInterval

    /// Whether the render ran on the main thread. False in the app, and asserted
    /// so in `AudioExportConcurrencyTests`.
    public let ranOnMainThread: Bool

    /// How many times the engine's owning thread was verified during the run.
    /// One per block; zero would mean the loop never ran.
    public let ownershipChecks: Int

    public var seconds: Double {
        settings.sampleRate.hertz > 0 ? Double(frameCount) / settings.sampleRate.hertz : 0
    }

    /// True when the render reached digital full scale, which for a float graph
    /// means the mix was over unity somewhere.
    public var didClip: Bool { peakLevel >= 1.0 }
}

// MARK: - Failures

/// Everything that can stop an export, in the owner's words.
public enum AudioExportError: Error, Equatable {
    /// The owner pressed Cancel.
    case cancelled

    /// There is no loaded program, or it is zero frames long.
    case nothingToRender

    /// The destination's directory is missing or refused the staged file.
    case destinationUnusable(path: String, reason: String)

    /// A write failed. A full disk lands here.
    case writeFailed(path: String, reason: String)

    /// The finished file could not be moved into place.
    case publishFailed(path: String, reason: String)

    /// The graph stopped producing frames before the program's own length.
    case renderStopped(atFrame: Int64, expectedFrames: Int64)

    /// The ownership guard fired: the engine was touched from a second thread.
    /// Structurally unreachable; present so that it cannot become reachable
    /// silently.
    case engineCrossedThreads
}

extension AudioExportError: LocalizedError {
    private static func display(_ path: String) -> String {
        HomeRelativePath.display(path, relativeTo: HomeRelativePath.realHomeDirectory)
    }

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The export was cancelled."
        case .nothingToRender:
            return "This piece has nothing to export yet."
        case .destinationUnusable(let path, let reason):
            return "Synth could not write to \(Self.display(path)). \(reason)"
        case .writeFailed(let path, let reason):
            return "Synth could not finish writing the export at \(Self.display(path)). \(reason)"
        case .publishFailed(let path, let reason):
            return "Synth could not save the finished export to \(Self.display(path)). \(reason)"
        case .renderStopped(let frame, let expected):
            return "The render stopped after \(frame) of \(expected) frames."
        case .engineCrossedThreads:
            return "The export's audio engine was used from more than one thread."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cancelled:
            return "Nothing was written. The file you were exporting to is unchanged."
        case .nothingToRender:
            return "Wait for the piece to finish opening, then try again."
        case .destinationUnusable:
            return "Choose another folder and try again. Nothing was written."
        case .writeFailed:
            return """
                Free up disk space and export again. The incomplete file has been \
                removed, and any file already at that name is untouched.
                """
        case .publishFailed:
            return "Check that the folder still exists and export again. Nothing was written."
        case .renderStopped, .engineCrossedThreads:
            return "Try the export again. Nothing was written."
        }
    }

    /// True when the owner stopped it, rather than something going wrong.
    public var isCancellation: Bool { self == .cancelled }
}

// MARK: - Staging

/// The staged file an export writes into, and the one rename that publishes it.
///
/// **Same shape as `AssetStagingArea`, for the same reason.** Bytes are written
/// to a hidden sibling of the destination and the finished file appears in one
/// `rename(2)`; there is no instant at which the destination exists and is
/// incomplete, and a crash, a cancel or a full disk leaves the destination
/// exactly as it was — including untouched if a previous export of the same
/// name is already there.
///
/// A *sibling*, not a file in Synth's own container, and that is deliberate:
/// `rename(2)` is only atomic within one filesystem, so staging next to the
/// destination is the only placement that is atomic for an export to an
/// external drive as well as to the owner's Documents folder. It is also what
/// `Data.write(options: .atomic)` does, which is why a save panel's grant
/// covers it.
struct AudioExportStaging {
    let destination: URL
    let stagedURL: URL
    private let fileManager: FileManager

    init(destination: URL, fileManager: FileManager) throws {
        self.destination = destination.standardizedFileURL
        self.fileManager = fileManager

        let directory = self.destination.deletingLastPathComponent()
        // Without the trim the owner is shown a path with a trailing slash,
        // which reads as a typo in a sentence.
        var directoryPath = directory.path(percentEncoded: false)
        while directoryPath.count > 1, directoryPath.hasSuffix("/") { directoryPath.removeLast() }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directoryPath, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AudioExportError.destinationUnusable(
                path: directoryPath,
                reason: "That folder does not exist."
            )
        }

        // Dot-prefixed and uniquely named: invisible in Finder, and two exports
        // of the same piece at once cannot collide on it.
        let name = ".\(self.destination.lastPathComponent).synth-partial-\(UUID().uuidString)"
        self.stagedURL = directory.appending(path: name)
    }

    func open(with opener: StagingFileOpening) throws -> AppendableFile {
        // A leftover from a previous run cannot exist under a fresh UUID, but
        // opening for *append* over one would silently concatenate two exports,
        // so the guarantee is made structural rather than assumed.
        if fileManager.fileExists(atPath: stagedURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: stagedURL)
        }
        do {
            return try opener.openForAppending(at: stagedURL)
        } catch {
            throw AudioExportError.destinationUnusable(
                path: stagedURL.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    func write(_ data: Data, to file: AppendableFile) throws {
        guard !data.isEmpty else { return }
        do {
            try file.append(data)
        } catch {
            throw AudioExportError.writeFailed(
                path: stagedURL.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// The moment the export becomes a file: one rename over the destination.
    func publish() throws {
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                // `replaceItemAt` is the sanctioned overwrite: it renames the
                // staged file into place and only then removes the old one, so
                // an overwrite that fails leaves the previous export intact
                // rather than deleting it first and hoping.
                _ = try fileManager.replaceItemAt(destination, withItemAt: stagedURL)
            } else {
                try fileManager.moveItem(at: stagedURL, to: destination)
            }
        } catch {
            throw AudioExportError.publishFailed(
                path: destination.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// Throw the staged bytes away. Best effort, and never touches the
    /// destination.
    func discard() {
        guard fileManager.fileExists(atPath: stagedURL.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: stagedURL)
        } catch {
            NSLog("Synth: could not clean up the staged export at %@: %@",
                  stagedURL.path(percentEncoded: false),
                  (error as NSError).localizedDescription)
        }
    }
}
