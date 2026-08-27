import Compression
import Foundation

/// Why a ZIP container could not be read.
///
/// Deliberately specific: a `.mxl` that fails to open must tell the owner what
/// is wrong with it, not just that "the import failed".
enum ZipArchiveError: Error, Equatable {
    case notAZipArchive
    case unsupportedZip64
    case truncated(detail: String)
    case malformedCentralDirectory(detail: String)
    case malformedLocalHeader(entry: String)
    case unsupportedCompressionMethod(entry: String, method: UInt16)
    case entryTooLarge(entry: String, byteCount: Int, limit: Int)
    case decompressionFailed(entry: String)
    case checksumMismatch(entry: String)
}

extension ZipArchiveError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notAZipArchive:
            return "it is not a ZIP archive (no end-of-central-directory record)"
        case .unsupportedZip64:
            return "it uses the ZIP64 extensions, which Synth does not read"
        case .truncated(let detail):
            return "the archive is truncated (\(detail))"
        case .malformedCentralDirectory(let detail):
            return "its directory of entries is malformed (\(detail))"
        case .malformedLocalHeader(let entry):
            return "the entry “\(entry)” has a malformed header"
        case .unsupportedCompressionMethod(let entry, let method):
            return "the entry “\(entry)” uses compression method \(method), which Synth does not read"
        case .entryTooLarge(let entry, let byteCount, let limit):
            return "the entry “\(entry)” expands to \(byteCount) bytes, over the \(limit)-byte limit"
        case .decompressionFailed(let entry):
            return "the entry “\(entry)” could not be decompressed"
        case .checksumMismatch(let entry):
            return "the entry “\(entry)” failed its checksum, so the archive is damaged"
        }
    }
}

/// A read-only reader for the subset of ZIP that MusicXML containers use.
///
/// Scope is deliberate: stored and deflated entries, no ZIP64, no encryption,
/// no spanning. A `.mxl` is a handful of small files, so anything beyond that
/// is refused with a reason rather than guessed at. Nothing here writes, and
/// entry names are never used as filesystem paths — entries are only ever
/// decompressed into memory.
struct ZipArchive {
    /// One central-directory entry.
    struct Entry: Equatable {
        let name: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Largest single entry this reader will expand, as a zip-bomb bound.
    static let maximumEntryByteCount = 64 * 1024 * 1024

    let entries: [Entry]
    private let bytes: [UInt8]

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let zip64Sentinel32: UInt32 = 0xFFFF_FFFF
    private static let zip64Sentinel16: UInt16 = 0xFFFF

    /// True when the bytes start with a local file header, the marker every
    /// ordinary ZIP (and therefore every `.mxl`) begins with.
    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
    }

    /// Parses the central directory. Entry contents are read lazily.
    static func read(_ data: Data) throws -> ZipArchive {
        let bytes = [UInt8](data)
        let endOffset = try locateEndOfCentralDirectory(in: bytes)

        let entriesOnDisk = readUInt16(bytes, endOffset + 8)
        let directorySize = readUInt32(bytes, endOffset + 12)
        let directoryOffset = readUInt32(bytes, endOffset + 16)

        guard
            entriesOnDisk != zip64Sentinel16,
            directorySize != zip64Sentinel32,
            directoryOffset != zip64Sentinel32
        else {
            throw ZipArchiveError.unsupportedZip64
        }

        var cursor = Int(directoryOffset)
        let directoryEnd = cursor + Int(directorySize)
        guard cursor >= 0, directoryEnd <= bytes.count else {
            throw ZipArchiveError.truncated(detail: "the entry directory runs past the end of the file")
        }

        var entries: [Entry] = []
        while cursor + 46 <= directoryEnd {
            guard readUInt32(bytes, cursor) == centralFileHeaderSignature else {
                throw ZipArchiveError.malformedCentralDirectory(
                    detail: "unexpected record at byte \(cursor)"
                )
            }

            let method = readUInt16(bytes, cursor + 10)
            let crc = readUInt32(bytes, cursor + 16)
            let compressedSize = readUInt32(bytes, cursor + 20)
            let uncompressedSize = readUInt32(bytes, cursor + 24)
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = readUInt32(bytes, cursor + 42)

            guard
                compressedSize != zip64Sentinel32,
                uncompressedSize != zip64Sentinel32,
                localOffset != zip64Sentinel32
            else {
                throw ZipArchiveError.unsupportedZip64
            }

            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryEnd else {
                throw ZipArchiveError.malformedCentralDirectory(
                    detail: "an entry name runs past the directory"
                )
            }

            entries.append(
                Entry(
                    name: decodeName(Array(bytes[nameStart..<(nameStart + nameLength)])),
                    compressionMethod: method,
                    crc32: crc,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localOffset)
                )
            )

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return ZipArchive(entries: entries, bytes: bytes)
    }

    /// The entry with this exact name, or — failing that — the single entry
    /// whose name matches case-insensitively. Producers occasionally disagree
    /// about the case of `META-INF`.
    func entry(named name: String) -> Entry? {
        if let exact = entries.first(where: { $0.name == name }) { return exact }
        let lowercased = name.lowercased()
        let matches = entries.filter { $0.name.lowercased() == lowercased }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Decompresses one entry into memory, verifying its CRC-32.
    func contents(of entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maximumEntryByteCount else {
            throw ZipArchiveError.entryTooLarge(
                entry: entry.name,
                byteCount: entry.uncompressedSize,
                limit: Self.maximumEntryByteCount
            )
        }

        let headerStart = entry.localHeaderOffset
        guard
            headerStart >= 0,
            headerStart + 30 <= bytes.count,
            Self.readUInt32(bytes, headerStart) == Self.localFileHeaderSignature
        else {
            throw ZipArchiveError.malformedLocalHeader(entry: entry.name)
        }

        // The local header repeats the name and extra fields; their lengths
        // are the only fields here we trust, because data-descriptor entries
        // leave the local sizes zeroed.
        let nameLength = Int(Self.readUInt16(bytes, headerStart + 26))
        let extraLength = Int(Self.readUInt16(bytes, headerStart + 28))
        let dataStart = headerStart + 30 + nameLength + extraLength

        guard dataStart >= 0, dataStart + entry.compressedSize <= bytes.count else {
            throw ZipArchiveError.truncated(
                detail: "the entry “\(entry.name)” runs past the end of the file"
            )
        }

        let compressed = Array(bytes[dataStart..<(dataStart + entry.compressedSize)])

        let expanded: [UInt8]
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw ZipArchiveError.malformedLocalHeader(entry: entry.name)
            }
            expanded = compressed
        case 8:
            expanded = try Self.inflate(
                compressed,
                expectedByteCount: entry.uncompressedSize,
                entryName: entry.name
            )
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(
                entry: entry.name,
                method: entry.compressionMethod
            )
        }

        guard CRC32.checksum(expanded) == entry.crc32 else {
            throw ZipArchiveError.checksumMismatch(entry: entry.name)
        }

        return Data(expanded)
    }

    // MARK: - Parsing helpers

    /// Scans backwards for the end-of-central-directory record, which may sit
    /// behind a trailing comment of up to 64 KiB.
    private static func locateEndOfCentralDirectory(in bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipArchiveError.notAZipArchive }

        let lowestStart = max(0, bytes.count - 22 - 0xFFFF)
        var offset = bytes.count - 22
        while offset >= lowestStart {
            if readUInt32(bytes, offset) == endOfCentralDirectorySignature {
                let commentLength = Int(readUInt16(bytes, offset + 20))
                if offset + 22 + commentLength == bytes.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw ZipArchiveError.notAZipArchive
    }

    /// Raw DEFLATE (ZIP method 8) is `COMPRESSION_ZLIB` in Apple's Compression
    /// framework: no zlib wrapper, which is exactly what ZIP stores.
    private static func inflate(
        _ compressed: [UInt8],
        expectedByteCount: Int,
        entryName: String
    ) throws -> [UInt8] {
        guard expectedByteCount > 0 else { return [] }

        var destination = [UInt8](repeating: 0, count: expectedByteCount)
        let written = destination.withUnsafeMutableBufferPointer { destinationBuffer -> Int in
            compressed.withUnsafeBufferPointer { sourceBuffer -> Int in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceBuffer.baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    expectedByteCount,
                    sourceBase,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == expectedByteCount else {
            throw ZipArchiveError.decompressionFailed(entry: entryName)
        }
        return destination
    }

    /// UTF-8 when the name is valid UTF-8 (flag bit 11, and the common case
    /// regardless), otherwise CP437's ASCII-compatible reading via Latin-1.
    private static func decodeName(_ raw: [UInt8]) -> String {
        String(bytes: raw, encoding: .utf8)
            ?? String(bytes: raw, encoding: .isoLatin1)
            ?? ""
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// The CRC-32 ZIP stores for every entry. Checking it is what turns a
/// truncated or corrupted `.mxl` into a named error instead of a silently
/// mangled score.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        checksum([UInt8](data))
    }
}
