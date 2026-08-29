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

        // Refused here, before a byte is staged, because the alternative is a
        // header whose 32-bit size words saturate while the file keeps going —
        // a file that reports success and then decodes wrong somewhere else.
        // The exact length is already known, so this costs nothing.
        guard !writer.exceedsContainerLimit else {
            throw AudioExportError.tooLongForContainer(
                format: request.settings.format,
                minutes: Int((Double(totalFrames) / request.settings.sampleRate.hertz / 60).rounded()),
                byteCount: writer.totalByteCount,
                limitByteCount: AudioFileWriter.maximumFileByteCount
            )
        }

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

        // Closing is a write: a file handle can be holding buffered bytes, and
        // the flush is where a disk that filled during the last block actually
        // reports itself. Left unmapped, that failure reached the owner as a
        // bare POSIX message instead of "free up disk space"; and it must fail
        // the export rather than publishing a file whose tail never landed.
        try staging.close(file)
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

    /// The render would not fit in a WAV or AIFF container, whose size fields
    /// are 32-bit. Refused before anything is written.
    case tooLongForContainer(
        format: AudioExportFormat, minutes: Int, byteCount: Int64, limitByteCount: Int64
    )

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
        case .tooLongForContainer(let format, let minutes, _, _):
            return """
                This piece is about \(minutes) minutes long, which is more audio than a \
                \(format.displayName) file can hold at this sample rate and depth.
                """
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
        case .tooLongForContainer:
            return """
                Both WAV and AIFF store their length in 32 bits, so neither can go past \
                4 GB. Choose a lower sample rate or 16-bit depth and export again. \
                Nothing was written.
                """
        }
    }

    /// True when the owner stopped it, rather than something going wrong.
    public var isCancellation: Bool { self == .cancelled }
}

// MARK: - Staging

/// The staged file an export writes into, and the one rename that publishes it.
///
/// **Same guarantee as `AssetStagingArea`**: bytes go somewhere else entirely
/// and the finished file appears in one `rename(2)`, so there is no instant at
/// which the destination exists and is incomplete, and a crash, a cancel or a
/// full disk leaves the destination exactly as it was — including untouched if
/// a previous export of the same name is already there.
///
/// **Staged in the system's item-replacement directory, not beside the
/// destination.** The first version of this wrote a hidden sibling —
/// `.<name>.synth-partial-<UUID>` — next to the file the owner chose, on the
/// argument that a save panel's grant must cover it because that is what
/// `Data.write(options: .atomic)` does. Plausible, and nothing proved it: under
/// the App Sandbox, Powerbox issues its extension for the exact path the owner
/// picked, and whether a hand-rolled `open(2)` at an *arbitrarily named*
/// sibling falls inside that allowance is not something Apple documents. An
/// export that worked in every test and failed on the owner's Desktop would
/// have been the worst possible outcome for this leaf.
///
/// `FileManager.url(for: .itemReplacementDirectory, appropriateFor:)` removes
/// the question rather than arguing it. It is the documented companion to
/// `replaceItemAt(_:withItemAt:)` and it gives two things at once:
///
/// * a directory the app can always write, inside its own sandbox, so staging
///   needs no grant of its own; and
/// * a guarantee that the directory is **on the same volume** as the
///   destination, which is what keeps the publish a `rename(2)` — atomic — for
///   an export to an external drive as much as to the owner's Documents folder.
///
/// The publish is then the sanctioned safe-save API for an overwrite, and a
/// plain rename for a file that does not exist yet — which is exactly the
/// operation a save panel's grant exists to permit.
///
/// The staged file carries the destination's own name, so it also stops needing
/// a `NAME_MAX` budget of its own: the replacement directory is private, and a
/// name that fits at the destination fits there.
struct AudioExportStaging {
    let destination: URL
    let stagedURL: URL

    /// The private directory the staged file lives in, removed whichever way
    /// the export ends.
    let replacementDirectory: URL

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

        // `appropriateFor:` is what makes this the *destination's* volume, and
        // therefore what makes the publish a rename rather than a copy. A fresh
        // directory per call, so two exports of one name cannot collide without
        // needing a unique file name of their own.
        do {
            self.replacementDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: self.destination,
                create: true
            )
        } catch {
            throw AudioExportError.destinationUnusable(
                path: directoryPath,
                reason: "Synth could not make a temporary folder on the same disk: "
                    + (error as NSError).localizedDescription
            )
        }
        self.stagedURL = replacementDirectory.appending(
            path: self.destination.lastPathComponent
        )
    }

    func open(with opener: StagingFileOpening) throws -> AppendableFile {
        // The directory is freshly created, so nothing can be here; opening for
        // *append* over a leftover would silently concatenate two exports, so
        // the guarantee is made structural rather than assumed.
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

    /// Flushes and closes, reporting a failed flush as the write it is.
    func close(_ file: AppendableFile) throws {
        do {
            try file.close()
        } catch {
            throw AudioExportError.writeFailed(
                path: stagedURL.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// The moment the export becomes a file: one rename onto the destination.
    ///
    /// Two shapes, both documented, and neither of them a hand-rolled write at
    /// a path nobody granted:
    ///
    /// * **the destination exists** — `replaceItemAt` is the sanctioned
    ///   safe-save API. It renames the staged file into place and only then
    ///   removes the old one, so an overwrite that fails leaves the previous
    ///   export intact rather than deleting it first and hoping; and
    /// * **it does not** — a plain rename onto the path the owner named, which
    ///   is the operation a save panel's grant exists to permit.
    func publish() throws {
        defer { removeReplacementDirectory() }
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
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
        removeReplacementDirectory()
    }

    /// Removes the whole private directory, so a failed export leaves nothing
    /// anywhere rather than a temporary folder nobody will ever look in.
    private func removeReplacementDirectory() {
        let path = replacementDirectory.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return }
        do {
            try fileManager.removeItem(at: replacementDirectory)
        } catch {
            NSLog("Synth: could not clean up the staged export at %@: %@",
                  path, (error as NSError).localizedDescription)
        }
    }
}
