import CryptoKit
import Foundation
import XCTest
@testable import SynthKit

/// Everything the library holds, captured so a failed import can be proved to
/// have changed nothing.
///
/// "Byte-identical" is taken literally for content: every file under the
/// container is digested. The one deliberate exception is
/// `library.sqlite-shm`, SQLite's shared-memory index — scratch state that a
/// plain read may touch and that holds no library data. `library.sqlite` and
/// `library.sqlite-wal`, which do, are digested like everything else.
struct LibrarySnapshot: Equatable {
    /// Container-relative path to SHA-256, for every file in the container.
    let files: [String: String]

    /// The catalog's rows, which is the library as the app sees it.
    let pieces: [PieceRecord]

    static let excludedFileNames: Set<String> = ["\(AppContainer.databaseFileName)-shm"]

    static func capture(_ store: LibraryStore) throws -> LibrarySnapshot {
        LibrarySnapshot(
            files: try captureFiles(in: store.container.rootURL),
            pieces: try store.pieces.allPieces()
        )
    }

    private static func captureFiles(in root: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let enumerator = fileManager.enumerator(
            at: root.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw SnapshotFailure(reason: "could not enumerate \(rootPath)")
        }

        var digests: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let name = url.lastPathComponent
            guard !excludedFileNames.contains(name) else { continue }

            let relative = String(
                url.path(percentEncoded: false).dropFirst(rootPath.count)
            )
            let data = try Data(contentsOf: url)
            digests[relative] = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return digests
    }

    struct SnapshotFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { "Could not snapshot the library: \(reason)" }
    }
}

/// A content store that fails every write the way a full disk does.
struct FullDiskContentStore: PieceContentStoring {
    let directoryURL: URL

    static let error = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ENOSPC),
        userInfo: [NSLocalizedDescriptionKey: "There is not enough space on the disk."]
    )

    func write(_ data: Data, named fileName: String) throws {
        throw Self.error
    }

    func removeIfPresent(named fileName: String) {}

    func read(named fileName: String) throws -> Data {
        throw Self.error
    }

    func url(named fileName: String) -> URL {
        directoryURL.appending(path: fileName)
    }
}

/// A catalog that reads for real but refuses to insert, so the importer's
/// "undo the content file" path runs against a real container.
final class InsertRefusingCatalog: PieceCatalogWriting, @unchecked Sendable {
    static let error = NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ENOSPC),
        userInfo: [NSLocalizedDescriptionKey: "There is not enough space on the disk."]
    )

    private let wrapped: PieceCatalog
    private(set) var insertAttempts = 0

    init(wrapping catalog: PieceCatalog) {
        self.wrapped = catalog
    }

    func piece(withContentSHA256 digest: String) throws -> PieceRecord? {
        try wrapped.piece(withContentSHA256: digest)
    }

    func allPieces() throws -> [PieceRecord] {
        try wrapped.allPieces()
    }

    func pieceCount() throws -> Int {
        try wrapped.pieceCount()
    }

    func insert(_ record: PieceRecord) throws {
        insertAttempts += 1
        throw Self.error
    }
}

extension XCTestCase {
    /// Writes `data` into `directory` under `name` and returns its URL.
    func writeFixture(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }
}
