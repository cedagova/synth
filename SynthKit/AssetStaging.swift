import CryptoKit
import Foundation

/// Where bytes land while they are still arriving, and how they are proved
/// before they count.
///
/// The atomicity promise — "no partial asset state is ever observable" — is a
/// property of this file plus one `rename(2)`. Nothing is ever written inside
/// `assets/<library>/`; downloads go to `assets/.staging/<library>/`, and the
/// installed directory appears in one atomic move once every byte of every
/// asset has been verified. A crash, a disk-full, a checksum mismatch or a
/// quit leaves debris under `.staging/` and an untouched `assets/`.
///
/// That same staging directory is what makes resume free: an interrupted
/// transfer's `.part` file is still there next launch, its length is how many
/// bytes we already have, and the manager asks the server for the rest. There
/// is no resume state in the database to get out of step with the disk,
/// because the disk *is* the state.

// MARK: - Writing a file, and failing to

/// A file being appended to.
///
/// A protocol for exactly one reason: the disk-full acceptance criterion. A
/// test cannot fill the owner's disk, but it can substitute a writer that
/// throws the same `ENOSPC` `NSError` Foundation throws when the disk is
/// genuinely full — and then the code path under test is the real one.
public protocol AppendableFile: AnyObject {
    /// Appends `data` to the end of the file.
    func append(_ data: Data) throws

    /// Flushes and closes. Safe to call twice.
    func close() throws
}

/// The shipped writer: a `FileHandle` positioned at the end of the file.
public final class FileHandleAppendableFile: AppendableFile {
    private var handle: FileHandle?

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func append(_ data: Data) throws {
        guard let handle else { return }
        try handle.write(contentsOf: data)
    }

    public func close() throws {
        guard let handle else { return }
        self.handle = nil
        try handle.close()
    }
}

/// Opens append-mode writers over real files.
public protocol StagingFileOpening: Sendable {
    /// Opens `url` for appending, creating it when it does not exist.
    func openForAppending(at url: URL) throws -> AppendableFile
}

public struct FileSystemStagingFileOpener: StagingFileOpening {
    public init() {}

    public func openForAppending(at url: URL) throws -> AppendableFile {
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw InstrumentInstallError.stagingWriteFailed(
                    path: path, reason: "the file could not be created"
                )
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return FileHandleAppendableFile(handle: handle)
    }
}

// MARK: - Digests

/// Computes an `AssetDigest` over a stream of chunks.
///
/// Both algorithms are streaming, which is what lets a 412 MB archive be
/// verified without ever being held in memory. The git variant differs only in
/// its prefix: git hashes `"blob <byteCount>\0"` and then the content, so the
/// byte count has to be known up front — which it is, because the catalog pins
/// it.
public struct StreamingAssetDigest {
    private let algorithm: AssetDigest.Algorithm
    private var sha256 = SHA256()
    private var sha1 = Insecure.SHA1()

    /// - Parameter totalByteCount: the complete asset's size, needed for the
    ///   git blob prefix. Ignored by SHA-256.
    public init(algorithm: AssetDigest.Algorithm, totalByteCount: Int64) {
        self.algorithm = algorithm
        if algorithm == .gitBlobSHA1 {
            sha1.update(data: Data("blob \(totalByteCount)\0".utf8))
        }
    }

    public mutating func update(_ data: Data) {
        switch algorithm {
        case .sha256: sha256.update(data: data)
        case .gitBlobSHA1: sha1.update(data: data)
        }
    }

    public consuming func finalizeHexString() -> String {
        switch algorithm {
        case .sha256:
            return sha256.finalize().map { String(format: "%02x", $0) }.joined()
        case .gitBlobSHA1:
            return sha1.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

// MARK: - Errors

/// Everything that can go wrong between "the bytes arrived" and "the library is
/// installed".
public enum InstrumentInstallError: Error, Equatable, Sendable {
    /// The staging directory could not be made.
    case stagingDirectoryUnavailable(path: String, reason: String)

    /// A staged file could not be written. Disk-full lands here.
    case stagingWriteFailed(path: String, reason: String)

    /// The bytes arrived intact in count but wrong in content.
    case digestMismatch(
        libraryID: String, assetID: String, algorithm: String, expected: String, actual: String
    )

    /// An archive member tried to escape the library root, or the archive was
    /// malformed.
    case archiveRejected(libraryID: String, assetID: String, reason: String)

    /// The final rename into place failed.
    case installFailed(libraryID: String, reason: String)

    /// The library is not in this build's catalog.
    case unknownLibrary(libraryID: String)
}

extension InstrumentInstallError: LocalizedError {
    private static func display(_ path: String) -> String {
        HomeRelativePath.display(path, relativeTo: HomeRelativePath.realHomeDirectory)
    }

    public var errorDescription: String? {
        switch self {
        case .stagingDirectoryUnavailable(let path, let reason):
            return "Synth could not prepare its download folder at \(Self.display(path)). \(reason)"
        case .stagingWriteFailed(let path, let reason):
            return "Synth could not write the download at \(Self.display(path)). \(reason)"
        case .digestMismatch(_, let assetID, let algorithm, let expected, let actual):
            return """
                The downloaded file \(assetID) does not match its \(algorithm). \
                Expected \(expected.prefix(16))…, got \(actual.prefix(16))….
                """
        case .archiveRejected(_, let assetID, let reason):
            return "Synth refused the downloaded archive \(assetID). \(reason)"
        case .installFailed(let libraryID, let reason):
            return "Synth could not finish installing \(libraryID). \(reason)"
        case .unknownLibrary(let libraryID):
            return "This version of Synth does not know an instrument library called \(libraryID)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .stagingDirectoryUnavailable, .stagingWriteFailed:
            return """
                Free up disk space and press Retry. Nothing was installed, and \
                your existing instruments are untouched.
                """
        case .digestMismatch:
            return """
                The incomplete download has been discarded. Press Retry to \
                fetch it again from the start.
                """
        case .archiveRejected:
            return "The download has been discarded. Press Retry to fetch it again."
        case .installFailed:
            return "Check available disk space and press Retry."
        case .unknownLibrary:
            return "Update Synth."
        }
    }

    /// True when pressing Retry could reasonably work.
    public var isRetryable: Bool {
        switch self {
        case .unknownLibrary: return false
        default: return true
        }
    }
}

// MARK: - The staging area

/// The `assets/.staging/` tree: one directory per library in flight.
///
/// `@unchecked Sendable` because of `FileManager`, which Foundation does not
/// mark `Sendable` even though the shared instance is documented as thread-safe
/// for these operations. Everything else here is a `let`.
public struct AssetStagingArea: @unchecked Sendable {
    /// Directory name inside `assets/`. Dot-prefixed so it never looks like an
    /// installed library, and so `installedLibraryDirectories` can skip it by
    /// the same rule that skips `.DS_Store`.
    public static let directoryName = ".staging"

    /// Root of the whole asset tree — the container's `assets/`.
    public let assetsRootURL: URL

    private let opener: StagingFileOpening
    private let fileManager: FileManager

    public init(
        assetsRootURL: URL,
        opener: StagingFileOpening = FileSystemStagingFileOpener(),
        fileManager: FileManager = .default
    ) {
        self.assetsRootURL = assetsRootURL
        self.opener = opener
        self.fileManager = fileManager
    }

    /// Where a finished library lives.
    public func installedURL(forLibraryID libraryID: String) -> URL {
        assetsRootURL.appending(path: libraryID)
    }

    /// Where a library's in-flight bytes live.
    public func stagingURL(forLibraryID libraryID: String) -> URL {
        assetsRootURL.appending(path: Self.directoryName).appending(path: libraryID)
    }

    /// Where one asset's *in-flight* bytes live.
    ///
    /// Named by a hash of the asset identifier rather than by the identifier
    /// itself, because an identifier is allowed to be a repository path with
    /// slashes, spaces and `#` in it, and none of that is a file name.
    public func partURL(forLibraryID libraryID: String, assetID: String) -> URL {
        stagingURL(forLibraryID: libraryID)
            .appending(path: Self.stagingFileName(forAssetID: assetID))
    }

    /// Where an asset's bytes live **once their digest has passed**.
    ///
    /// Two names rather than one, and this is the whole of why: a resumed run
    /// has to decide whether a staged file is finished, and *"it is the right
    /// length"* is not the same claim as *"it is the right bytes"*. A part file
    /// can reach full length and never be checked — the process can die between
    /// the last write and the digest comparison — and a mismatched part can
    /// survive a discard that itself failed. Under a single name either of those
    /// is silently installed by the next run, which would make a checksum
    /// mismatch **not** fail closed across a relaunch.
    ///
    /// So the rename to this name happens only after the digest matches, and
    /// only a file with this name counts as complete. "Complete" then means
    /// "verified" by construction rather than by a comment claiming it.
    public func verifiedURL(forLibraryID libraryID: String, assetID: String) -> URL {
        stagingURL(forLibraryID: libraryID)
            .appending(path: Self.verifiedFileName(forAssetID: assetID))
    }

    /// The in-flight file name for an asset identifier.
    public static func stagingFileName(forAssetID assetID: String) -> String {
        digestName(forAssetID: assetID) + ".part"
    }

    /// The verified file name for an asset identifier.
    public static func verifiedFileName(forAssetID assetID: String) -> String {
        digestName(forAssetID: assetID) + ".verified"
    }

    static func digestName(forAssetID assetID: String) -> String {
        SHA256Digest.hexString(Data(assetID.utf8))
    }

    /// Promotes a part file to its verified name. Called only once the pinned
    /// digest has matched.
    public func markVerified(forLibraryID libraryID: String, assetID: String) throws {
        let source = partURL(forLibraryID: libraryID, assetID: assetID)
        let destination = verifiedURL(forLibraryID: libraryID, assetID: assetID)
        do {
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

    /// What is on disk for `assetID`, and whether it has been proved.
    ///
    /// This is the whole of resume state. It is read from the filesystem rather
    /// than remembered anywhere, so it cannot disagree with reality after a
    /// crash, a manual deletion, or a copy of the container onto another Mac.
    public func stagedState(forLibraryID libraryID: String, assetID: String)
        -> (byteCount: Int64, isVerified: Bool)
    {
        let verified = byteCount(of: verifiedURL(forLibraryID: libraryID, assetID: assetID))
        if verified > 0 { return (verified, true) }
        return (byteCount(of: partURL(forLibraryID: libraryID, assetID: assetID)), false)
    }

    /// Bytes on disk for `assetID`, proved or not. For progress only.
    public func stagedByteCount(forLibraryID libraryID: String, assetID: String) -> Int64 {
        stagedState(forLibraryID: libraryID, assetID: assetID).byteCount
    }

    private func byteCount(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return 0 }
        return Int64(size)
    }

    /// Creates the library's staging directory if it is missing.
    public func prepareStaging(forLibraryID libraryID: String) throws {
        let url = stagingURL(forLibraryID: libraryID)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InstrumentInstallError.stagingDirectoryUnavailable(
                path: url.path(percentEncoded: false),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// Opens an asset's `.part` file for appending.
    public func openPart(forLibraryID libraryID: String, assetID: String) throws -> AppendableFile {
        try opener.openForAppending(at: partURL(forLibraryID: libraryID, assetID: assetID))
    }

    /// Throws away one asset's staged bytes, verified or not, so the next
    /// attempt starts clean.
    ///
    /// Used when a digest fails and when a server ignores a range request: in
    /// both cases what is on disk is not a prefix of what we want.
    ///
    /// Best-effort, and that is now safe: a failed removal leaves a `.part`
    /// file, which the next run resumes rather than trusts. Before the
    /// verified/unverified split, a failed removal here left a full-length file
    /// that the next run would have installed unchecked.
    public func discardPart(forLibraryID libraryID: String, assetID: String) {
        removeBestEffort(partURL(forLibraryID: libraryID, assetID: assetID))
        removeBestEffort(verifiedURL(forLibraryID: libraryID, assetID: assetID))
    }

    /// Throws away everything staged for a library.
    public func discardStaging(forLibraryID libraryID: String) {
        removeBestEffort(stagingURL(forLibraryID: libraryID))
    }

    /// Removes an installed library's files. The database row is the caller's
    /// problem; this is only the bytes.
    public func removeInstalled(libraryID: String) throws {
        let url = installedURL(forLibraryID: libraryID)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw InstrumentInstallError.installFailed(
                libraryID: libraryID, reason: (error as NSError).localizedDescription
            )
        }
    }

    /// The moment a library becomes installed: one rename of the assembled
    /// tree into `assets/<libraryID>/`.
    ///
    /// `moveItem` on the same volume is `rename(2)`, which is atomic — so there
    /// is no instant at which `assets/<libraryID>/` exists and is incomplete.
    /// An existing install is moved aside first and only deleted after the new
    /// one is in place, so a failure halfway through leaves the *old* library
    /// working rather than nothing at all.
    public func promoteStagedInstall(libraryID: String) throws {
        let staged = stagingURL(forLibraryID: libraryID)
        let installed = installedURL(forLibraryID: libraryID)
        let installedPath = installed.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: staged.path(percentEncoded: false)) else {
            throw InstrumentInstallError.installFailed(
                libraryID: libraryID, reason: "there was nothing staged to install"
            )
        }

        var displaced: URL?
        if fileManager.fileExists(atPath: installedPath) {
            let aside = assetsRootURL
                .appending(path: Self.directoryName)
                .appending(path: "\(libraryID).replacing-\(UInt64(Date().timeIntervalSince1970))")
            do {
                try fileManager.moveItem(at: installed, to: aside)
                displaced = aside
            } catch {
                throw InstrumentInstallError.installFailed(
                    libraryID: libraryID,
                    reason: "the previous copy could not be moved aside: "
                        + (error as NSError).localizedDescription
                )
            }
        }

        do {
            try fileManager.moveItem(at: staged, to: installed)
        } catch {
            // Put the old library back rather than leaving the owner with
            // neither.
            if let displaced {
                try? fileManager.moveItem(at: displaced, to: installed)
            }
            throw InstrumentInstallError.installFailed(
                libraryID: libraryID, reason: (error as NSError).localizedDescription
            )
        }

        if let displaced { removeBestEffort(displaced) }
    }

    /// Deletes staged trees for libraries that are not currently downloading.
    ///
    /// Called at launch. Debris from a killed process is *kept* for the library
    /// it belongs to — that is the resume — so this only removes staging for
    /// identifiers the catalog no longer contains.
    public func discardStagingForLibrariesNotIn(_ knownLibraryIDs: Set<String>) {
        let root = assetsRootURL.appending(path: Self.directoryName)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where !knownLibraryIDs.contains(entry.lastPathComponent) {
            removeBestEffort(entry)
        }
    }

    private func removeBestEffort(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            NSLog("Synth: could not clean up %@: %@",
                  url.path(percentEncoded: false),
                  (error as NSError).localizedDescription)
        }
    }
}
