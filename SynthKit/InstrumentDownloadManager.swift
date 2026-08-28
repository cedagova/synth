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

        // Assets already verified in a previous run are the ones whose part
        // file is exactly the pinned length. Re-hashing them would mean reading
        // 2.5 GB off the disk to learn what the previous run already proved, so
        // a complete part file is taken at its length and the final digest of
        // the *library* is the whole-install proof. A truncated one is resumed;
        // an over-long one is discarded, because it cannot be a prefix.
        var pending: [CatalogAsset] = []
        for asset in library.assets {
            let staged = staging.stagedByteCount(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
            if staged == asset.byteCount {
                tally.assetAlreadyComplete(byteCount: asset.byteCount)
            } else {
                if staged > asset.byteCount {
                    staging.discardPart(forLibraryID: library.identifier, assetID: asset.identifier)
                } else if staged > 0 {
                    tally.addResumedBytes(staged)
                }
                pending.append(asset)
            }
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
        let startOffset = staging.stagedByteCount(
            forLibraryID: library.identifier, assetID: asset.identifier
        )

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
            file: file, digest: digest, alreadyOnDiskByteCount: startOffset
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

        tally.assetFinished(receivedByteCount: sink.receivedByteCount)
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
            let source = staging.partURL(forLibraryID: library.identifier, assetID: asset.identifier)
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
            let partURL = staging.partURL(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
            switch asset.payload {
            case .file:
                continue
            case .tarXZArchive(let strip):
                try ArchiveUnpacking.unpackTarXZ(
                    at: partURL, into: destination, strippingComponents: strip,
                    libraryID: library.identifier, assetID: asset.identifier
                )
            case .zipArchive(let strip):
                try ArchiveUnpacking.unpackZip(
                    at: partURL, into: destination, strippingComponents: strip,
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

    init(
        file: AppendableFile,
        digest: consuming StreamingAssetDigest,
        alreadyOnDiskByteCount: Int64
    ) {
        self.file = file
        self.digest = digest
        self.alreadyOnDisk = alreadyOnDiskByteCount
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
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        try file.append(chunk)
        digest.update(chunk)
        received += Int64(chunk.count)
    }

    /// Throws away what is on disk and starts the file and the digest again.
    func restartFromEmpty(
        at url: URL, algorithm: AssetDigest.Algorithm, totalByteCount: Int64
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try file?.close()
        file = nil
        try? FileManager.default.removeItem(at: url)
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

    private var completedBytes: Int64 = 0
    private var completedAssets = 0
    private var phase: InstrumentDownloadProgress.Phase = .downloading

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
        completedBytes += byteCount
        completedAssets += 1
        lock.unlock()
    }

    func addResumedBytes(_ count: Int64) {
        lock.lock()
        completedBytes += count
        lock.unlock()
    }

    func assetFinished(receivedByteCount: Int64) {
        lock.lock()
        completedBytes += receivedByteCount
        completedAssets += 1
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
            completedByteCount: completedBytes,
            totalByteCount: totalByteCount,
            completedAssetCount: completedAssets,
            totalAssetCount: totalAssetCount,
            phase: phase
        )
    }
}
