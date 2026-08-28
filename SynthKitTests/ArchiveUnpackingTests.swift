import Foundation
import XCTest
@testable import SynthKit

/// The two archive readers, and the path checks that stop an archive writing
/// outside the folder it is unpacking into.
final class ArchiveUnpackingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "synth-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func destinationRoot() throws -> URL {
        let url = root.appending(path: "installed")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertExpandedTree(at destination: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, expected) in ArchiveFixtures.expectedContents {
            let url = destination.appending(path: path)
            let actual = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(actual, expected, "\(path) did not unpack correctly", file: file, line: line)
        }
    }

    // MARK: tar.xz

    func testUnpacksATarXZAndStripsItsWrapperDirectory() throws {
        let archive = try write(ArchiveFixtures.tarXZ, named: "fixture.tar.xz")
        let destination = try destinationRoot()

        try ArchiveUnpacking.unpackTarXZ(
            at: archive,
            into: ArchiveUnpacking.DirectoryDestination(rootURL: destination),
            strippingComponents: 1,
            libraryID: "test", assetID: "fixture.tar.xz"
        )

        try assertExpandedTree(at: destination)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appending(path: "wrapper").path(percentEncoded: false)
            ),
            "stripComponents: 1 left the wrapper directory in place."
        )
    }

    func testATruncatedTarXZIsRefusedRatherThanPartlyInstalled() throws {
        var truncated = ArchiveFixtures.tarXZ
        truncated.removeLast(truncated.count / 3)
        let archive = try write(truncated, named: "truncated.tar.xz")
        let destination = try destinationRoot()

        XCTAssertThrowsError(
            try ArchiveUnpacking.unpackTarXZ(
                at: archive,
                into: ArchiveUnpacking.DirectoryDestination(rootURL: destination),
                strippingComponents: 1,
                libraryID: "test", assetID: "truncated.tar.xz"
            ),
            "A truncated archive must not unpack quietly."
        )
    }

    // MARK: zip

    func testUnpacksAZip() throws {
        let archive = try write(ArchiveFixtures.zip, named: "fixture.zip")
        let destination = try destinationRoot()

        try ArchiveUnpacking.unpackZip(
            at: archive,
            into: ArchiveUnpacking.DirectoryDestination(rootURL: destination),
            strippingComponents: 0,
            libraryID: "test", assetID: "fixture.zip"
        )

        try assertExpandedTree(at: destination)
    }

    func testAZipWithNoIndexIsRefused() throws {
        let archive = try write(Data(repeating: 0x41, count: 4_096), named: "notazip.zip")
        let destination = try destinationRoot()

        XCTAssertThrowsError(
            try ArchiveUnpacking.unpackZip(
                at: archive,
                into: ArchiveUnpacking.DirectoryDestination(rootURL: destination),
                strippingComponents: 0,
                libraryID: "test", assetID: "notazip.zip"
            )
        ) { error in
            guard case InstrumentInstallError.archiveRejected = error else {
                return XCTFail("Expected archiveRejected, got \(error)")
            }
        }
    }

    func testAZipMemberIsStoppedWhileItExpands() throws {
        // A member whose index understates its size is refused, and refused
        // *during* the write rather than after it. Unreachable through the
        // catalog, because the archive's own digest is pinned — the point of
        // the bound is that it does not depend on that.
        let archive = try write(ArchiveFixtures.zip, named: "fixture.zip")
        let destination = try destinationRoot()
        let counting = CountingDestination(
            underlying: ArchiveUnpacking.DirectoryDestination(rootURL: destination)
        )

        XCTAssertThrowsError(
            try ArchiveUnpacking.unpackZip(
                at: archive, into: counting, strippingComponents: 0,
                libraryID: "test", assetID: "fixture.zip",
                declaredSizeOverride: 4
            )
        ) { error in
            guard case InstrumentInstallError.archiveRejected(_, _, let reason) = error else {
                return XCTFail("Expected archiveRejected, got \(error)")
            }
            XCTAssertTrue(reason.contains("expands to more than"))
        }

        XCTAssertLessThanOrEqual(
            counting.bytesWritten, 4 + 256 * 1024,
            """
            The member kept being written past its declared size. A bound that \
            only fires once the file is closed is no bound at all against the \
            case it exists for.
            """
        )
    }

    // MARK: Member paths

    func testAMemberThatClimbsOutOfTheLibraryFolderIsRefused() {
        for hostile in ["../elsewhere/evil.wav", "Samples/../../evil.wav", "a/../../b"] {
            XCTAssertThrowsError(
                try ArchiveUnpacking.safeRelativePath(
                    hostile, strippingComponents: 0, libraryID: "l", assetID: "a"
                ),
                "\(hostile) was allowed."
            ) { error in
                guard case InstrumentInstallError.archiveRejected = error else {
                    return XCTFail("Expected archiveRejected for \(hostile), got \(error)")
                }
            }
        }
    }

    func testAnAbsoluteMemberPathIsRefused() {
        XCTAssertThrowsError(
            try ArchiveUnpacking.safeRelativePath(
                "/etc/passwd", strippingComponents: 0, libraryID: "l", assetID: "a"
            )
        )
    }

    func testWindowsSeparatorsAreNormalisedRatherThanTakenLiterally() throws {
        let path = try ArchiveUnpacking.safeRelativePath(
            #"wrapper\Samples\a.wav"#, strippingComponents: 1, libraryID: "l", assetID: "a"
        )
        XCTAssertEqual(path, "Samples/a.wav")
    }

    func testArchiveMetadataMembersAreSkipped() throws {
        XCTAssertNil(
            try ArchiveUnpacking.safeRelativePath(
                "__MACOSX/._a.wav", strippingComponents: 0, libraryID: "l", assetID: "a"
            )
        )
        XCTAssertNil(
            try ArchiveUnpacking.safeRelativePath(
                "Samples/.DS_Store", strippingComponents: 0, libraryID: "l", assetID: "a"
            )
        )
        XCTAssertNil(
            try ArchiveUnpacking.safeRelativePath(
                "wrapper/", strippingComponents: 1, libraryID: "l", assetID: "a"
            ),
            "The stripped wrapper directory itself is nothing to create."
        )
    }

    // MARK: Streaming decode

    /// Counts what actually reached the disk, so "stopped while expanding" is
    /// checked rather than assumed.
    final class CountingDestination: ArchiveUnpacking.Destination {
        let underlying: ArchiveUnpacking.Destination
        private(set) var bytesWritten = 0

        init(underlying: ArchiveUnpacking.Destination) { self.underlying = underlying }

        func createDirectory(_ relativePath: String) throws {
            try underlying.createDirectory(relativePath)
        }

        func beginFile(_ relativePath: String) throws -> AppendableFile {
            Counter(underlying: try underlying.beginFile(relativePath), destination: self)
        }

        fileprivate func add(_ count: Int) { bytesWritten += count }

        private final class Counter: AppendableFile {
            let underlying: AppendableFile
            weak var destination: CountingDestination?

            init(underlying: AppendableFile, destination: CountingDestination) {
                self.underlying = underlying
                self.destination = destination
            }

            func append(_ data: Data) throws {
                destination?.add(data.count)
                try underlying.append(data)
            }

            func close() throws { try underlying.close() }
        }
    }

    func testTheXZDecoderHandlesAStreamLargerThanItsBuffers() throws {
        // 3 MB of varied bytes, so the decode loop refills its input and drains
        // its output many times over rather than fitting in one pass.
        var source = Data()
        var state: UInt64 = 12_345
        for _ in 0..<(3 * 1024 * 1024) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            source.append(UInt8((state >> 33) & 0xFF))
        }

        // Round-trip through the tar reader by wrapping it in the fixture's own
        // shape would need an xz encoder, which `Compression` does provide.
        let compressed = try XCTUnwrap(
            (source as NSData).compressed(using: .lzma) as Data?,
            "Could not produce an LZMA stream to decode."
        )

        var decoded = Data()
        var offset = 0
        let produced = try StreamingInflate.decode(
            format: .xz,
            read: {
                guard offset < compressed.count else { return Data() }
                let end = min(offset + 64 * 1024, compressed.count)
                defer { offset = end }
                return Data(compressed[(compressed.startIndex + offset)..<(compressed.startIndex + end)])
            },
            write: { decoded.append($0) }
        )

        XCTAssertEqual(produced, Int64(source.count))
        XCTAssertEqual(decoded, source, "The streamed decode did not reproduce the input.")
    }
}
