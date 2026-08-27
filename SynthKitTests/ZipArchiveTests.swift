import Foundation
import XCTest
@testable import SynthKit

final class ZipArchiveTests: XCTestCase {
    private let payload = Data(String(repeating: "<note>C</note>\n", count: 500).utf8)

    func testReadsStoredAndDeflatedEntries() throws {
        let archive = try ZipArchive.read(
            ZipBuilder.archive([
                .init(name: "stored.txt", data: payload, deflate: false),
                .init(name: "deflated.xml", data: payload, deflate: true)
            ])
        )

        XCTAssertEqual(archive.entries.map(\.name), ["stored.txt", "deflated.xml"])
        XCTAssertEqual(archive.entries[0].compressionMethod, 0)
        XCTAssertEqual(archive.entries[1].compressionMethod, 8)
        XCTAssertLessThan(
            archive.entries[1].compressedSize,
            payload.count,
            "The fixture must really be deflated, or the inflate path is untested"
        )

        for entry in archive.entries {
            XCTAssertEqual(try archive.contents(of: entry), payload)
        }
    }

    func testHandlesAnEmptyEntry() throws {
        let archive = try ZipArchive.read(ZipBuilder.archive([.init(name: "empty.txt", data: Data())]))
        let entry = try XCTUnwrap(archive.entry(named: "empty.txt"))

        XCTAssertEqual(try archive.contents(of: entry), Data())
    }

    func testFindsAnEntryCaseInsensitivelyWhenTheExactNameIsAbsent() throws {
        let archive = try ZipArchive.read(
            ZipBuilder.archive([.init(name: "meta-inf/container.xml", data: payload)])
        )

        XCTAssertNotNil(archive.entry(named: "META-INF/container.xml"))
        XCTAssertNil(archive.entry(named: "META-INF/other.xml"))
    }

    func testReadsAnArchiveWithATrailingComment() throws {
        let archive = try ZipArchive.read(
            ZipBuilder.archive([.init(name: "score.xml", data: payload)], comment: "written by a notation app")
        )
        let entry = try XCTUnwrap(archive.entry(named: "score.xml"))

        XCTAssertEqual(try archive.contents(of: entry), payload)
    }

    func testRejectsBytesThatAreNotAZip() {
        XCTAssertThrowsError(try ZipArchive.read(Data("<score-partwise/>".utf8))) { error in
            XCTAssertEqual(error as? ZipArchiveError, .notAZipArchive)
        }
        XCTAssertFalse(ZipArchive.looksLikeZip(Data("<score-partwise/>".utf8)))
    }

    func testRejectsATruncatedArchive() {
        let archive = ZipBuilder.archive([.init(name: "score.xml", data: payload, deflate: true)])

        // Cutting the tail removes the end-of-central-directory record.
        XCTAssertThrowsError(try ZipArchive.read(Data(archive.prefix(archive.count - 8)))) { error in
            XCTAssertEqual(error as? ZipArchiveError, .notAZipArchive)
        }
    }

    func testRejectsAnArchiveWhoseEntryDataWasCorrupted() throws {
        var bytes = ZipBuilder.archive([.init(name: "score.xml", data: payload, deflate: false)])
        // Flip a byte inside the stored entry's payload; the CRC must catch it.
        let target = bytes.startIndex + 30 + "score.xml".utf8.count + 10
        bytes[target] = bytes[target] ^ 0xFF

        let archive = try ZipArchive.read(bytes)
        let entry = try XCTUnwrap(archive.entry(named: "score.xml"))

        XCTAssertThrowsError(try archive.contents(of: entry)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .checksumMismatch(entry: "score.xml"))
        }
    }

    func testRejectsAnEntryWhoseChecksumDoesNotMatchItsContents() throws {
        let archive = try ZipArchive.read(
            ZipBuilder.archive([
                .init(name: "score.xml", data: payload, deflate: true, crcOverride: 0xDEAD_BEEF)
            ])
        )
        let entry = try XCTUnwrap(archive.entry(named: "score.xml"))

        XCTAssertThrowsError(try archive.contents(of: entry)) { error in
            XCTAssertEqual(error as? ZipArchiveError, .checksumMismatch(entry: "score.xml"))
        }
    }

    func testRefusesAnEntryLargerThanTheExpansionLimit() throws {
        var bytes = ZipBuilder.archive([.init(name: "bomb.xml", data: payload, deflate: true)])
        // Rewrite the central directory's uncompressed size to 1 GiB.
        let directoryOffset = try XCTUnwrap(Self.centralDirectoryOffset(in: bytes))
        Self.write(UInt32(1 << 30), into: &bytes, at: directoryOffset + 24)

        let archive = try ZipArchive.read(bytes)
        let entry = try XCTUnwrap(archive.entry(named: "bomb.xml"))

        XCTAssertThrowsError(try archive.contents(of: entry)) { error in
            guard case .entryTooLarge(let name, _, let limit)? = error as? ZipArchiveError else {
                return XCTFail("Expected entryTooLarge, got \(error)")
            }
            XCTAssertEqual(name, "bomb.xml")
            XCTAssertEqual(limit, ZipArchive.maximumEntryByteCount)
        }
    }

    func testRefusesAnUnsupportedCompressionMethod() throws {
        var bytes = ZipBuilder.archive([.init(name: "score.xml", data: payload)])
        let directoryOffset = try XCTUnwrap(Self.centralDirectoryOffset(in: bytes))
        // 14 is LZMA: legal ZIP, and not something this build reads.
        Self.write(UInt16(14), into: &bytes, at: directoryOffset + 10)

        let archive = try ZipArchive.read(bytes)
        let entry = try XCTUnwrap(archive.entry(named: "score.xml"))

        XCTAssertThrowsError(try archive.contents(of: entry)) { error in
            XCTAssertEqual(
                error as? ZipArchiveError,
                .unsupportedCompressionMethod(entry: "score.xml", method: 14)
            )
        }
    }

    func testCRC32MatchesKnownValues() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }

    // MARK: - Byte surgery helpers

    /// Offset of the first central-directory record, read from the archive's
    /// end-of-central-directory record.
    private static func centralDirectoryOffset(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { return nil }
        for offset in stride(from: bytes.count - 22, through: 0, by: -1) {
            let signature = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            guard signature == 0x0605_4b50 else { continue }
            return Int(
                UInt32(bytes[offset + 16])
                    | (UInt32(bytes[offset + 17]) << 8)
                    | (UInt32(bytes[offset + 18]) << 16)
                    | (UInt32(bytes[offset + 19]) << 24)
            )
        }
        return nil
    }

    private static func write(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[data.startIndex + offset] = UInt8(value & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func write(_ value: UInt32, into data: inout Data, at offset: Int) {
        for byte in 0..<4 {
            data[data.startIndex + offset + byte] = UInt8((value >> (8 * byte)) & 0xFF)
        }
    }
}
