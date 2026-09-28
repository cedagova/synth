import Foundation

/// Exports one file per audible line — the piece's stems (#90).
///
/// **Still no render code.** Each stem is an ordinary `AudioExportRequest` for
/// the same timeline, voices and mixer as the mix, with that one line soloed,
/// rendered by `AudioExporter.render` — the loop the mix export uses. So a stem
/// is the same engine graph as playback, and the stems of a piece sum back to
/// its mix (plan decisions 1–4):
///
/// * **pre-master** — cohesion, calibration and the ceiling are all bypassed,
///   because none of them is linear and a per-program calibration of one line
///   is not that line's share of the mix;
/// * **only the lines the mix plays** — mute wins, and while anything is
///   soloed only soloed lines get a stem; each keeps its fader and pan;
/// * **32-bit float**, whatever the mix depth says, so a pre-master peak above
///   full scale is stored rather than clipped (AD-P6); and
/// * **all or nothing** — every stem is staged first and the batch is only
///   published once all of them rendered, never over an existing file unless
///   the caller says the owner confirmed it.
public struct AudioStemExporter: Sendable {
    public let request: AudioStemExportRequest

    public init(request: AudioStemExportRequest) {
        self.request = request
    }

    /// Render every stem and publish them together into `folder`, blocking the
    /// calling thread. Same threading contract as `AudioExporter.run`.
    ///
    /// - Parameters:
    ///   - folder: an existing directory.
    ///   - confirmedReplacements: the file names the owner confirmed may be
    ///     replaced — exactly the names `request.existingFileNames(in:)`
    ///     reported when they were asked. Any other existing stem name is
    ///     refused with `.wouldReplaceExistingFiles`: before anything is
    ///     rendered, and again at publish, so a file that appears during the
    ///     render is never replaced on the strength of an earlier answer.
    @discardableResult
    public func run(
        into folder: URL,
        confirmedReplacements: Set<String> = [],
        progress: (@Sendable (AudioStemExportProgress) -> Void)? = nil,
        cancellation: AudioExportCancellation = AudioExportCancellation(),
        opener: StagingFileOpening = FileSystemStagingFileOpener(),
        fileManager: FileManager = .default
    ) throws -> AudioStemExportResult {
        let started = Date()
        let stems = request.stems
        guard !stems.isEmpty else { throw AudioExportError.nothingAudible }

        let staging = try AudioStemStaging(
            folder: folder, fileNames: stems.map(\.fileName), fileManager: fileManager
        )
        do {
            try staging.refuseUnconfirmed(confirmedReplacements)

            var rendered: [(RenderedExport, AudioExportRequest)] = []
            for (index, stem) in stems.enumerated() {
                let stemRequest = request.request(for: stem)
                let result = try AudioExporter(request: stemRequest).render(
                    into: staging.file(at: index),
                    opener: opener,
                    cancellation: cancellation,
                    started: started,
                    progress: { step in
                        progress?(AudioStemExportProgress(
                            stemIndex: index, stemCount: stems.count, stemName: stem.name, stem: step
                        ))
                    }
                )
                rendered.append((result, stemRequest))
            }

            // Every stem is staged; the last point a cancel still leaves the
            // folder exactly as it was.
            if cancellation.isCancelled { throw AudioExportError.cancelled }
            try staging.publish(confirmedReplacements: confirmedReplacements)

            return AudioStemExportResult(
                folder: staging.folder,
                files: zip(rendered, staging.destinations).map { pair, url in
                    pair.0.result(url: url, request: pair.1, started: started)
                },
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            staging.discard()
            throw error
        }
    }
}

// MARK: - What is being exported

/// One stem: a line the mix plays, and the file it becomes.
public struct AudioStem: Sendable, Equatable, Identifiable {
    public let lineID: ScoreLineID
    /// The line's display name — the owner's rename when there is one.
    public let name: String
    public let fileName: String

    public var id: ScoreLineID { lineID }
}

/// A stem batch's complete input: the mix request it is cut from, plus what
/// the files are called.
public struct AudioStemExportRequest: Sendable {
    /// The mix export's own request, unchanged. Each stem is derived from it.
    public let mix: AudioExportRequest
    public let pieceTitle: String

    /// The lines the mix plays, in score order, each with its file name.
    public let stems: [AudioStem]

    /// - Parameter lineNames: display names by line (renames honoured); a line
    ///   without one uses the name the timeline carries.
    public init(
        mix: AudioExportRequest,
        pieceTitle: String,
        lineNames: [ScoreLineID: String] = [:]
    ) {
        self.mix = mix
        self.pieceTitle = pieceTitle

        let soloing = mix.timeline.lines.contains { mix.mixer[$0.id]?.isSoloed ?? false }
        let audible = mix.timeline.lines.filter {
            Self.isRouted(mix.mixer[$0.id] ?? .neutral, whileSoloing: soloing)
        }
        let names = audible.map { lineNames[$0.id] ?? $0.name }
        let fileNames = AudioExportNaming.stemFileNames(
            pieceTitle: pieceTitle, lineNames: names, format: mix.settings.format
        )
        self.stems = audible.indices.map {
            AudioStem(lineID: audible[$0].id, name: names[$0], fileName: fileNames[$0])
        }
    }

    /// The engine's routing rule: mute wins over solo, and an unsoloed line is
    /// silent while anything is soloed. `AssignmentDisplay.isRouted` states
    /// the panel's view of the same rule through this.
    public static func isRouted(_ state: LineMixerState, whileSoloing isSoloing: Bool) -> Bool {
        if state.isMuted { return false }
        return isSoloing ? state.isSoloed : true
    }

    /// What every stem file is: the mix's container and rate, 32-bit float.
    public var encoding: AudioSampleEncoding { .float32 }

    /// "WAV · 48 kHz · 32-bit float"
    public var fileDescription: String {
        "\(mix.settings.format.displayName) · \(mix.settings.sampleRate.displayName) · "
            + encoding.displayName
    }

    /// The render for one stem: the mix with only this line soloed, the
    /// master stage bypassed, written as float.
    public func request(for stem: AudioStem) -> AudioExportRequest {
        var mixer: [ScoreLineID: LineMixerState] = [:]
        for line in mix.timeline.lines {
            var state = mix.mixer[line.id] ?? .neutral
            state.isSoloed = line.id == stem.lineID
            if line.id == stem.lineID { state.isMuted = false }
            mixer[line.id] = state
        }
        return AudioExportRequest(
            timeline: mix.timeline,
            voices: mix.voices,
            mixer: mixer,
            masterGain: mix.masterGain,
            producedMaster: mix.producedMaster,
            tuning: mix.tuning,
            settings: mix.settings,
            bypassesMasterStage: true,
            sampleEncoding: encoding
        )
    }

    /// Stem file names already present in `folder`, so the app can ask before
    /// replacing them. Empty when there is nothing to confirm.
    public func existingFileNames(in folder: URL, fileManager: FileManager = .default) -> [String] {
        stems.map(\.fileName).filter {
            fileManager.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        }
    }
}

extension PresetPerformance {
    /// This preset's stems: its export request, named by piece and by each
    /// line's display name.
    public func stemExportRequest(
        timeline: PerformanceTimeline,
        settings: AudioExportSettings,
        pieceTitle: String,
        instruments: SampledInstrumentLibrary? = nil
    ) -> AudioStemExportRequest {
        AudioStemExportRequest(
            mix: exportRequest(timeline: timeline, settings: settings, instruments: instruments),
            pieceTitle: pieceTitle,
            lineNames: Dictionary(
                lines.map { ($0.lineID, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
        )
    }
}

// MARK: - Progress and result

/// How far a stem batch has got: which stem, and how far into it.
public struct AudioStemExportProgress: Sendable, Equatable {
    public let stemIndex: Int
    public let stemCount: Int
    public let stemName: String
    public let stem: AudioExportProgress

    public init(stemIndex: Int, stemCount: Int, stemName: String, stem: AudioExportProgress) {
        self.stemIndex = stemIndex
        self.stemCount = stemCount
        self.stemName = stemName
        self.stem = stem
    }

    /// 0…1 over the whole batch.
    public var fraction: Double {
        guard stemCount > 0 else { return 0 }
        return min(1, max(0, (Double(stemIndex) + stem.fraction) / Double(stemCount)))
    }
}

/// What a finished stem batch produced.
public struct AudioStemExportResult: Sendable, Equatable {
    public let folder: URL
    /// One per stem, in score order.
    public let files: [AudioExportResult]
    public let duration: TimeInterval

    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    public var seconds: Double { files.first?.seconds ?? 0 }
}

// MARK: - Naming

extension AudioExportNaming {
    /// `"Prelude in C — Violin I.wav"`, one per line, all distinct.
    ///
    /// Distinct the way the file system compares them — case- and
    /// normalization-insensitively, as APFS does by default — so two lines
    /// both called "Violin" become "… Violin.wav" and "… Violin 2.wav" rather
    /// than one file written over the other. Path characters are replaced like
    /// the mix export's, and every name fits `maximumSuggestedNameBytes`.
    public static func stemFileNames(
        pieceTitle: String,
        lineNames: [String],
        format: AudioExportFormat
    ) -> [String] {
        var title = sanitized(pieceTitle)
        if title.isEmpty { title = "Untitled piece" }

        var used: Set<String> = []
        return lineNames.enumerated().map { index, lineName in
            var line = sanitized(lineName)
            if line.isEmpty { line = "Line \(index + 1)" }
            let base = "\(title) — \(line)"

            var copy = 1
            while true {
                let suffix = copy == 1 ? "" : " \(copy)"
                let limit = maximumSuggestedNameBytes - format.fileExtension.utf8.count - 1
                    - suffix.utf8.count
                let stem = truncated(base, toByteCount: max(0, limit))
                    .trimmingCharacters(in: .whitespaces)
                let name = "\(stem)\(suffix).\(format.fileExtension)"
                let key = name.precomposedStringWithCanonicalMapping.lowercased()
                if used.insert(key).inserted { return name }
                copy += 1
            }
        }
    }
}

// MARK: - Staging

/// Every stem staged in one private directory on the folder's volume, and a
/// publish that puts all of them in place or none.
///
/// The single-file staging's guarantees, carried over to a batch: bytes go to
/// the system's item-replacement directory for the folder (same volume, so each
/// move is a `rename(2)`), and nothing appears in the folder until every stem
/// has rendered. A batch cannot be one rename, so the publish undoes itself if
/// any move fails: files it added are removed and files it replaced are put
/// back from where it had moved them.
///
/// **An original is never deleted unless the batch succeeded.** Replaced files
/// wait in `backupDirectory` until every stem is in place; if putting one back
/// fails, the backups are kept — cleanup skips them — and the error names
/// where they are.
struct AudioStemStaging {
    let folder: URL
    let destinations: [URL]
    let replacementDirectory: URL
    private let stagedURLs: [URL]
    private let fileManager: FileManager

    init(folder: URL, fileNames: [String], fileManager: FileManager) throws {
        self.folder = folder.standardizedFileURL
        self.fileManager = fileManager

        var folderPath = self.folder.path(percentEncoded: false)
        while folderPath.count > 1, folderPath.hasSuffix("/") { folderPath.removeLast() }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AudioExportError.destinationUnusable(
                path: folderPath, reason: "That folder does not exist."
            )
        }

        do {
            self.replacementDirectory = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: self.folder,
                create: true
            )
        } catch {
            throw AudioExportError.destinationUnusable(
                path: folderPath,
                reason: "Synth could not make a temporary folder on the same disk: "
                    + (error as NSError).localizedDescription
            )
        }
        let folderURL = self.folder
        let stagingURL = self.replacementDirectory
        self.destinations = fileNames.map { folderURL.appending(path: $0) }
        self.stagedURLs = fileNames.map { stagingURL.appending(path: $0) }
    }

    func file(at index: Int) -> StagedAudioFile {
        StagedAudioFile(url: stagedURLs[index], fileManager: fileManager)
    }

    func existingFileNames() -> [String] {
        destinations
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
            .map(\.lastPathComponent)
    }

    /// Where replaced originals wait until the batch has succeeded.
    var backupDirectory: URL { replacementDirectory.appending(path: "Replaced") }

    /// Refuses when a stem name exists in the folder that the owner did not
    /// confirm replacing.
    func refuseUnconfirmed(_ confirmed: Set<String>) throws {
        let unconfirmed = existingFileNames().filter { !confirmed.contains($0) }
        if !unconfirmed.isEmpty {
            throw AudioExportError.wouldReplaceExistingFiles(
                folder: folder.path(percentEncoded: false), names: unconfirmed
            )
        }
    }

    /// Move every staged stem into the folder, or leave it as it was.
    ///
    /// Replaces only files named in `confirmedReplacements`; any other file
    /// at a stem's name — one that appeared since the owner was asked — fails
    /// the batch before anything moves.
    func publish(confirmedReplacements: Set<String>) throws {
        try refuseUnconfirmed(confirmedReplacements)

        let existing = existingFileNames()
        let backups = backupDirectory
        var movedAside: [(original: URL, backup: URL)] = []
        var added: [URL] = []
        var current = folder
        do {
            if !existing.isEmpty {
                try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
                for name in existing {
                    let original = folder.appending(path: name)
                    current = original
                    let backup = backups.appending(path: name)
                    try fileManager.moveItem(at: original, to: backup)
                    movedAside.append((original, backup))
                }
            }
            // `moveItem` refuses an existing destination, so a file that
            // appeared since the check fails the batch instead of being
            // overwritten.
            for (staged, destination) in zip(stagedURLs, destinations) {
                current = destination
                try fileManager.moveItem(at: staged, to: destination)
                added.append(destination)
            }
        } catch {
            for url in added.reversed() { try? fileManager.removeItem(at: url) }
            var unrestored: [String] = []
            for entry in movedAside.reversed() {
                do {
                    try fileManager.moveItem(at: entry.backup, to: entry.original)
                } catch {
                    unrestored.append(entry.original.lastPathComponent)
                }
            }
            if !unrestored.isEmpty {
                // Kept, not cleaned up: this folder now holds the only copy.
                discard()
                throw AudioExportError.publishFailedOriginalsKept(
                    path: current.path(percentEncoded: false),
                    reason: (error as NSError).localizedDescription,
                    names: unrestored.reversed(),
                    backupFolder: backups.path(percentEncoded: false)
                )
            }
            discard()
            throw AudioExportError.publishFailed(
                path: current.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
        // Every stem is in place: the replaced originals were confirmed and
        // can go.
        removeReplacementDirectory()
    }

    /// Throw every staged stem away. Never touches the folder, and never
    /// deletes a replaced original that could not be put back: if
    /// `backupDirectory` holds anything, only the staged stems are removed.
    func discard() {
        let backups = backupDirectory.path(percentEncoded: false)
        let kept = (try? fileManager.contentsOfDirectory(atPath: backups)) ?? []
        guard !kept.isEmpty else { return removeReplacementDirectory() }
        for url in stagedURLs where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: url)
        }
        NSLog("Synth: kept %d replaced file(s) that could not be put back, in %@",
              kept.count, backups)
    }

    private func removeReplacementDirectory() {
        let path = replacementDirectory.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return }
        do {
            try fileManager.removeItem(at: replacementDirectory)
        } catch {
            NSLog("Synth: could not clean up the staged stems at %@: %@",
                  path, (error as NSError).localizedDescription)
        }
    }
}
