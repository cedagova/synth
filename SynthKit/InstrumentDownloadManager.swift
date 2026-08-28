import Foundation

/// Downloading one curated library: progress, pause, resume, integrity, and an
/// install that is either complete or absent.
///
/// The manager holds no networking of its own — it is handed an
/// `AssetTransferring` — so the whole of the download policy is testable
/// against a local fixture server, and REQ-028's "only catalog assets touch the
/// network" is enforced by the one allow-listed file being somewhere else.
///
/// ## The order things happen in, and why
///
/// For each asset, in order:
///
/// 1. Ask the staging area how many bytes are already there. That number is the
///    resume point, and it comes from the file's length rather than from any
///    remembered state, so it survives a kill, a crash or a copy of the
///    container to another Mac.
/// 2. Fetch from that offset. If the server answers `200` instead of `206`, it
///    ignored the range: what is on disk is not a prefix of what is arriving,
///    so the part file is discarded and the write starts again at zero. Getting
///    this wrong is how a resumed download silently produces a file with a
///    duplicated head, which the digest would catch but only after another
///    2.5 GB.
/// 3. Hash while writing. A separate verification pass would mean reading every
///    byte back off the disk; hashing in the same loop costs nothing.
/// 4. Compare against the pinned digest. A mismatch discards the part file, so
///    the asset is immediately re-downloadable, and reports which asset and
///    which algorithm.
///
/// Then, once **every** asset has verified:
///
/// 5. Unpack any archives into the staging tree.
/// 6. Rename the staging tree into `assets/<libraryID>/` — one atomic
///    operation, and the first instant at which the library exists.
/// 7. Record the row.
///
/// Nothing before step 6 is visible as an installed library, which is the whole
/// of "no partial asset state is ever observable". A failure anywhere in 1–5
/// leaves `assets/<libraryID>/` exactly as it was — absent, or the previous
/// install — and leaves the verified part files in place so the next attempt
/// resumes rather than restarts.

// MARK: - Progress

/// A snapshot of one library's transfer.
public struct InstrumentDownloadProgress: Sendable, Equatable {
    public let libraryID: String

    /// Bytes verified or received so far, across every asset.
    public let completedByteCount: Int64

    /// Bytes the complete library will take.
    public let totalByteCount: Int64

    /// Assets fully downloaded and verified.
    public let completedAssetCount: Int

    public let totalAssetCount: Int

    /// What the manager is doing right now.
    public enum Phase: Sendable, Equatable {
        case downloading
        case verifying
        case unpacking
        case installing
        case finished
    }

    public let phase: Phase

    public init(
        libraryID: String,
        completedByteCount: Int64,
        totalByteCount: Int64,
        completedAssetCount: Int,
        totalAssetCount: Int,
        phase: Phase
    ) {
        self.libraryID = libraryID
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
        self.completedAssetCount = completedAssetCount
        self.totalAssetCount = totalAssetCount
        self.phase = phase
    }

    /// 0…1, or 0 when the total is unknown.
    public var fraction: Double {
        guard totalByteCount > 0 else { return 0 }
        return min(1, max(0, Double(completedByteCount) / Double(totalByteCount)))
    }
}

// MARK: - Manager

public final class InstrumentDownloadManager: @unchecked Sendable {
    private let store: InstrumentAssetStore
    private let transfer: AssetTransferring

    /// How many assets are fetched at once.
    ///
    /// The orchestral library is 2,539 separate files, and fetching them one at
    /// a time spends most of the wall clock on request round trips rather than
    /// on bytes. Six is enough to hide that and few enough to stay a polite
    /// guest on someone else's server.
    private let concurrentTransferLimit: Int

    public init(
        store: InstrumentAssetStore,
        transfer: AssetTransferring,
        concurrentTransferLimit: Int = 6
    ) {
        self.store = store
        self.transfer = transfer
        self.concurrentTransferLimit = max(1, concurrentTransferLimit)
    }

    /// Downloads, verifies and installs `library`.
    ///
    /// Resumes whatever is already staged. Cancelling the surrounding `Task`
    /// pauses it: verified and partial bytes stay on disk and the next call
    /// carries on from there.
    ///
    /// - Parameter progress: called on an unspecified thread as bytes land.
    public func install(
        _ library: CatalogLibrary,
        progress: @escaping @Sendable (InstrumentDownloadProgress) -> Void = { _ in }
    ) async throws {
        let staging = store.stagingArea
        try staging.prepareStaging(forLibraryID: library.identifier)

        let tally = ProgressTally(
            libraryID: library.identifier,
            totalByteCount: library.downloadByteCount,
            totalAssetCount: library.assets.count,
            report: progress
        )

        // An asset counts as done only when a previous run **proved** it: the
        // staging area renames a part file to its verified name after, and only
        // after, its digest matched. Length alone is not the test, and this is
        // not a nicety — a part file can reach full length and never be checked
        // if the process dies between the last write and the comparison, and a
        // mismatched part can outlive a discard that failed. Trusting length
        // would install either of those unchecked on the next run, which would
        // make a checksum mismatch stop failing closed across a relaunch.
        //
        // So: verified and the right length ⇒ done, and not re-hashed, because
        // it was hashed when it was written. Anything else is a prefix to resume
        // from, or — if it is somehow longer than the asset — discarded, since
        // it cannot be a prefix of anything.
        var pending: [CatalogAsset] = []
        for asset in library.assets {
            let staged = staging.stagedState(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
            if staged.isVerified, staged.byteCount == asset.byteCount {
                tally.assetAlreadyComplete(byteCount: asset.byteCount)
                continue
            }

            // A part that is already the pinned length but was never verified is
            // the killed-just-before-the-comparison case. Re-hashing it costs
            // one local read and saves re-fetching an asset that is probably
            // fine; if it is not fine it is discarded, so the wrong bytes are
            // never installed either way.
            if !staged.isVerified, staged.byteCount == asset.byteCount,
               (try? verifyStagedPart(asset, of: library)) == true {
                tally.assetAlreadyComplete(byteCount: asset.byteCount)
                continue
            }

            if staged.isVerified || staged.byteCount >= asset.byteCount {
                // A verified file of the wrong length, an over-long part, or a
                // full-length part that just failed re-hashing: none of them can
                // be a prefix of what is wanted.
                staging.discardPart(forLibraryID: library.identifier, assetID: asset.identifier)
            } else if staged.byteCount > 0 {
                tally.addResumedBytes(staged.byteCount)
            }
            pending.append(asset)
        }

        tally.report(phase: .downloading)

        if !pending.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                var running = 0

                func startOne() {
                    let asset = pending[next]
                    next += 1
                    running += 1
                    group.addTask { [self] in
                        try await fetchAndVerify(asset, of: library, tally: tally)
                    }
                }

                while next < pending.count, running < concurrentTransferLimit { startOne() }
                while running > 0 {
                    try await group.next()
                    running -= 1
                    if next < pending.count { startOne() }
                }
            }
        }

        try Task.checkCancellation()

        if library.assets.contains(where: { $0.payload.isArchive }) {
            tally.report(phase: .unpacking)
            try unpackArchives(of: library)
        }

        tally.report(phase: .installing)
        try materializeFiles(of: library)
        try staging.promoteStagedInstall(libraryID: library.identifier)
        try store.recordInstall(of: library)
        tally.report(phase: .finished)
    }

    /// Removes a library's files and row, so it can be downloaded again.
    public func remove(_ library: CatalogLibrary) throws {
        try store.removeInstalledLibrary(withID: library.identifier)
    }

    // MARK: One asset

    private func fetchAndVerify(
        _ asset: CatalogAsset, of library: CatalogLibrary, tally: ProgressTally
    ) async throws {
        try Task.checkCancellation()

        let staging = store.stagingArea
        // The scheme is the transfer's business, not this one's — see
        // `CatalogAsset.resolvedURL`.
        guard let url = asset.resolvedURL else {
            throw AssetTransferError.sourceRefused(host: asset.sourceURL, statusCode: 0)
        }

        let partURL = staging.partURL(
            forLibraryID: library.identifier, assetID: asset.identifier
        )
        let startOffset = staging.stagedState(
            forLibraryID: library.identifier, assetID: asset.identifier
        ).byteCount

        // A digest over the whole asset, so a resumed transfer has to rehash
        // the part already on disk. That is a local read at disk speed against
        // a remote fetch at network speed, and it is the only way a resumed
        // file gets the same integrity guarantee a fresh one does.
        var digest = StreamingAssetDigest(
            algorithm: asset.digest.algorithm, totalByteCount: asset.byteCount
        )
        if startOffset > 0 {
            try hashExistingPart(at: partURL, into: &digest)
        }

        let file = try staging.openPart(forLibraryID: library.identifier, assetID: asset.identifier)
        let sink = AssetWriteSink(
            file: file,
            digest: digest,
            alreadyOnDiskByteCount: startOffset,
            // Progress has to move *inside* an asset, not only between assets.
            // Driving the real app found this: the piano is a single 412 MB
            // archive, so per-asset reporting left it saying "Zero bytes of
            // 412 MB" for minutes while it downloaded perfectly.
            reportBytes: { delta in tally.addTransferredBytes(delta) }
        )

        do {
            try await transfer.fetch(
                url,
                startingAtByteOffset: startOffset,
                began: { response in
                    // The server ignored the range and is sending the lot. What
                    // is on disk is not a prefix of it, so start over rather
                    // than append a second copy of the head.
                    guard startOffset > 0, !response.isResumedRange else { return }
                    try sink.restartFromEmpty(
                        at: partURL,
                        algorithm: asset.digest.algorithm,
                        totalByteCount: asset.byteCount
                    )
                },
                receive: { chunk in try sink.write(chunk) }
            )
        } catch {
            try? sink.closeFile()
            throw error
        }

        try sink.closeFile()

        let writtenTotal = sink.totalByteCountOnDisk
        guard writtenTotal == asset.byteCount else {
            staging.discardPart(forLibraryID: library.identifier, assetID: asset.identifier)
            throw AssetTransferError.unexpectedByteCount(
                expected: asset.byteCount, received: writtenTotal
            )
        }

        let actual = sink.finalizeDigest()
        guard actual == asset.digest.hexValue else {
            // The content is wrong, so keeping it would make the next attempt
            // resume onto bad bytes. Discarding is what makes "reported, and
            // re-downloadable" true rather than "reported, and stuck".
            staging.discardPart(forLibraryID: library.identifier, assetID: asset.identifier)
            throw InstrumentInstallError.digestMismatch(
                libraryID: library.identifier,
                assetID: asset.identifier,
                algorithm: asset.digest.displayName,
                expected: asset.digest.hexValue,
                actual: actual
            )
        }

        try staging.markVerified(forLibraryID: library.identifier, assetID: asset.identifier)
        tally.assetFinished()
    }

    /// Hashes a full-length part file and promotes it if it matches.
    ///
    /// Returns false when it does not, leaving the file for the caller to
    /// discard.
    private func verifyStagedPart(_ asset: CatalogAsset, of library: CatalogLibrary) throws -> Bool {
        var digest = StreamingAssetDigest(
            algorithm: asset.digest.algorithm, totalByteCount: asset.byteCount
        )
        try hashExistingPart(
            at: store.stagingArea.partURL(
                forLibraryID: library.identifier, assetID: asset.identifier
            ),
            into: &digest
        )
        guard digest.finalizeHexString() == asset.digest.hexValue else { return false }
        try store.stagingArea.markVerified(
            forLibraryID: library.identifier, assetID: asset.identifier
        )
        return true
    }

    /// Rehashes an existing partial file so a resumed transfer's digest covers
    /// every byte, not only the new ones.
    private func hashExistingPart(at url: URL, into digest: inout StreamingAssetDigest) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(chunk)
        }
    }

    // MARK: Laying the library out

    /// Moves each verified `.part` file to the path the catalog installs it at.
    ///
    /// Done last, and inside the staging directory, so that until the final
    /// rename the only thing on disk is a tree of temporary files under
    /// `.staging/`. Moving rather than copying because these are gigabytes:
    /// a copy would need the disk space twice over and take as long again.
    ///
    /// The part files are named by a hash and the install paths are the
    /// catalog's own, so the two namespaces cannot collide inside the same
    /// staging directory.
    private func materializeFiles(of library: CatalogLibrary) throws {
        let staging = store.stagingArea
        let root = staging.stagingURL(forLibraryID: library.identifier)
        let fileManager = FileManager.default

        for asset in library.assets {
            guard case .file(let path) = asset.payload else { continue }
            let source = staging.verifiedURL(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
            let destination = root.appending(path: path)

            // Already in place from an install that failed after this point.
            if !fileManager.fileExists(atPath: source.path(percentEncoded: false)),
               fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                continue
            }

            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                throw InstrumentInstallError.stagingWriteFailed(
                    path: destination.path(percentEncoded: false),
                    reason: (error as NSError).localizedDescription
                )
            }
        }
    }

    // MARK: Archives

    private func unpackArchives(of library: CatalogLibrary) throws {
        let staging = store.stagingArea
        let root = staging.stagingURL(forLibraryID: library.identifier)
        let destination = ArchiveUnpacking.DirectoryDestination(rootURL: root)

        for asset in library.assets {
            let archiveURL = staging.verifiedURL(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
            switch asset.payload {
            case .file:
                continue
            case .tarXZArchive(let strip):
                try ArchiveUnpacking.unpackTarXZ(
                    at: archiveURL, into: destination, strippingComponents: strip,
                    libraryID: library.identifier, assetID: asset.identifier
                )
            case .zipArchive(let strip):
                try ArchiveUnpacking.unpackZip(
                    at: archiveURL, into: destination, strippingComponents: strip,
                    libraryID: library.identifier, assetID: asset.identifier
                )
            }
            // The archive itself is not part of the installed library, and
            // leaving it would double the library's footprint on disk.
            staging.discardPart(forLibraryID: library.identifier, assetID: asset.identifier)
        }
    }
}

// MARK: - Writing one asset

/// Appends bytes to a part file and hashes them on the way past.
///
/// A class with a lock because `AssetTransferring` may deliver chunks from its
/// own queue, and the digest is stateful.
private final class AssetWriteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AppendableFile?
    private var digest: StreamingAssetDigest
    private var received: Int64 = 0
    private var alreadyOnDisk: Int64
    private var finalHex: String?
    private let reportBytes: @Sendable (Int64) -> Void

    init(
        file: AppendableFile,
        digest: consuming StreamingAssetDigest,
        alreadyOnDiskByteCount: Int64,
        reportBytes: @escaping @Sendable (Int64) -> Void
    ) {
        self.file = file
        self.digest = digest
        self.alreadyOnDisk = alreadyOnDiskByteCount
        self.reportBytes = reportBytes
    }

    /// Bytes this transfer delivered, not counting a resumed prefix.
    var receivedByteCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// Everything the part file holds now: the resumed prefix plus this
    /// transfer, or just this transfer when the prefix had to be thrown away.
    var totalByteCountOnDisk: Int64 {
        lock.lock(); defer { lock.unlock() }
        return alreadyOnDisk + received
    }

    func write(_ chunk: Data) throws {
        lock.lock()
        guard let file else { lock.unlock(); return }
        do {
            try file.append(chunk)
        } catch {
            lock.unlock()
            throw error
        }
        digest.update(chunk)
        received += Int64(chunk.count)
        lock.unlock()
        reportBytes(Int64(chunk.count))
    }

    /// Throws away what is on disk and starts the file and the digest again.
    func restartFromEmpty(
        at url: URL, algorithm: AssetDigest.Algorithm, totalByteCount: Int64
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try file?.close()
        file = nil
        try? FileManager.default.removeItem(at: url)
        // Whatever was counted for this asset is no longer on disk.
        reportBytes(-(alreadyOnDisk + received))
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        else {
            throw InstrumentInstallError.stagingWriteFailed(
                path: url.path(percentEncoded: false),
                reason: "the partial download could not be reset"
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        file = FileHandleAppendableFile(handle: handle)
        digest = StreamingAssetDigest(algorithm: algorithm, totalByteCount: totalByteCount)
        received = 0
        alreadyOnDisk = 0
    }

    func closeFile() throws {
        lock.lock(); defer { lock.unlock() }
        let open = file
        file = nil
        try open?.close()
    }

    func finalizeDigest() -> String {
        lock.lock(); defer { lock.unlock() }
        if let finalHex { return finalHex }
        let hex = digest.finalizeHexString()
        // Replaced so the struct is not consumed twice if this is called again.
        digest = StreamingAssetDigest(algorithm: .sha256, totalByteCount: 0)
        finalHex = hex
        return hex
    }
}

// MARK: - Progress bookkeeping

/// Adds up bytes across concurrent transfers and publishes snapshots.
private final class ProgressTally: @unchecked Sendable {
    private let lock = NSLock()
    private let libraryID: String
    private let totalByteCount: Int64
    private let totalAssetCount: Int
    private let reportSnapshot: @Sendable (InstrumentDownloadProgress) -> Void

    /// Bytes already on disk when this run started: assets a previous run
    /// finished, plus the partial prefixes it left behind.
    private var carriedOverBytes: Int64 = 0

    /// Bytes this run has actually transferred.
    private var transferredBytes: Int64 = 0

    private var completedAssets = 0
    private var phase: InstrumentDownloadProgress.Phase = .downloading

    /// When a snapshot was last published. Thousands of chunks arrive per
    /// second across six concurrent transfers, and the owner cannot read a
    /// number that changes that fast — nor should the main actor be woken for
    /// each one.
    private var lastPublished = Date.distantPast

    init(
        libraryID: String,
        totalByteCount: Int64,
        totalAssetCount: Int,
        report: @escaping @Sendable (InstrumentDownloadProgress) -> Void
    ) {
        self.libraryID = libraryID
        self.totalByteCount = totalByteCount
        self.totalAssetCount = totalAssetCount
        self.reportSnapshot = report
    }

    func assetAlreadyComplete(byteCount: Int64) {
        lock.lock()
        carriedOverBytes += byteCount
        completedAssets += 1
        lock.unlock()
    }

    func addResumedBytes(_ count: Int64) {
        lock.lock()
        carriedOverBytes += count
        lock.unlock()
    }

    /// Called for every chunk written, from whichever transfer wrote it.
    func addTransferredBytes(_ delta: Int64) {
        lock.lock()
        transferredBytes += delta
        guard Date().timeIntervalSince(lastPublished) > 0.25 else {
            lock.unlock()
            return
        }
        lastPublished = Date()
        let snapshot = makeSnapshot()
        lock.unlock()
        reportSnapshot(snapshot)
    }

    func assetFinished() {
        lock.lock()
        completedAssets += 1
        lastPublished = Date()
        let snapshot = makeSnapshot()
        lock.unlock()
        reportSnapshot(snapshot)
    }

    func report(phase newPhase: InstrumentDownloadProgress.Phase) {
        lock.lock()
        phase = newPhase
        let snapshot = makeSnapshot()
        lock.unlock()
        reportSnapshot(snapshot)
    }

    /// Caller holds the lock.
    private func makeSnapshot() -> InstrumentDownloadProgress {
        InstrumentDownloadProgress(
            libraryID: libraryID,
            completedByteCount: max(0, min(totalByteCount, carriedOverBytes + transferredBytes)),
            totalByteCount: totalByteCount,
            completedAssetCount: completedAssets,
            totalAssetCount: totalAssetCount,
            phase: phase
        )
    }
}
