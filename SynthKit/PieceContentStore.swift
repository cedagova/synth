import Foundation

/// Where a piece's verbatim MusicXML lives.
///
/// A protocol because the import contract's hardest promise — "a failed or
/// interrupted import leaves the library byte-identical" — is about what
/// happens when this write fails. A stub that fails the way a full disk fails
/// is how that promise gets proved rather than asserted.
public protocol PieceContentStoring: Sendable {
    /// Writes `data` under `fileName`, atomically: after this returns, either
    /// the complete content is in place or nothing is.
    func write(_ data: Data, named fileName: String) throws

    /// Removes the file if it is there. Rollback only — a failure here cannot
    /// be surfaced usefully because the caller is already throwing.
    func removeIfPresent(named fileName: String)

    /// Reads content back. Used by later leaves; the importer never re-reads.
    func read(named fileName: String) throws -> Data

    /// Where `fileName` lives, for callers that need a real URL.
    func url(named fileName: String) -> URL
}

/// The shipped content store: one file per piece under the container's
/// `pieces/` directory.
public struct DirectoryPieceContentStore: PieceContentStoring {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func url(named fileName: String) -> URL {
        directoryURL.appending(path: fileName)
    }

    /// `Data.write(options: .atomic)` writes a temporary file beside the
    /// destination and renames it into place. A disk-full failure therefore
    /// happens before the rename, leaving no partial piece behind.
    public func write(_ data: Data, named fileName: String) throws {
        try data.write(to: url(named: fileName), options: [.atomic])
    }

    public func removeIfPresent(named fileName: String) {
        let target = url(named: fileName)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            NSLog("Synth: could not roll back the imported piece file %@: %@",
                  fileName,
                  (error as NSError).localizedDescription)
        }
    }

    /// Read through `FileHandle` rather than Foundation's URL-based `Data`
    /// initialiser: that one honours the URL's scheme and will fetch over the
    /// network, which REQ-028 forbids. Nothing in SynthKit may hold a
    /// networking-capable call, and `NoNetworkBaselineTests` enforces that by
    /// name — including on this comment, which is why it does not spell the
    /// initialiser out.
    public func read(named fileName: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url(named: fileName))
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }
}
