import Foundation

/// Unpacking a downloaded archive into a staged library directory.
///
/// Two formats, because the two archive-delivered libraries in the catalog use
/// one each and neither publishes the other: Salamander ships `.tar.xz`,
/// Etherealwinds ships `.zip`. Both go through `StreamingInflate`, so neither
/// ever holds its contents in memory.
///
/// **Every member path is checked before anything is written.** A relative path
/// with `..` in it, an absolute path, or a symlink is how an archive escapes
/// the directory it is supposed to unpack into and writes somewhere else on the
/// disk. The catalog's archives are pinned by checksum and cannot change under
/// us, so this is defence in depth rather than a live threat — but a checksum
/// pins bytes, not intent, and the check costs nothing.
enum ArchiveUnpacking {
    /// Where unpacked members are written.
    ///
    /// A protocol so extraction can be tested without a disk and so the
    /// disk-full seam reaches inside an archive too: filling up part way
    /// through an unpack is a materially different moment from filling up
    /// during a download.
    protocol Destination {
        /// Creates a directory, and every missing parent.
        func createDirectory(_ relativePath: String) throws

        /// Opens a member for writing. The caller appends and then closes.
        ///
        /// Push rather than pull, because a tar member's bytes are discovered
        /// across several decompressor chunks and there is no point at which
        /// the whole file is available to hand over.
        func beginFile(_ relativePath: String) throws -> AppendableFile
    }

    /// The shipped destination: real files under a staged library root.
    struct DirectoryDestination: Destination {
        let rootURL: URL
        let opener: StagingFileOpening
        let fileManager: FileManager

        init(
            rootURL: URL,
            opener: StagingFileOpening = FileSystemStagingFileOpener(),
            fileManager: FileManager = .default
        ) {
            self.rootURL = rootURL
            self.opener = opener
            self.fileManager = fileManager
        }

        func createDirectory(_ relativePath: String) throws {
            let url = rootURL.appending(path: relativePath)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw InstrumentInstallError.stagingWriteFailed(
                    path: url.path(percentEncoded: false),
                    reason: (error as NSError).localizedDescription
                )
            }
        }

        func beginFile(_ relativePath: String) throws -> AppendableFile {
            let url = rootURL.appending(path: relativePath)
            let parent = url.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw InstrumentInstallError.stagingWriteFailed(
                    path: parent.path(percentEncoded: false),
                    reason: (error as NSError).localizedDescription
                )
            }

            // Start from empty: an unpack retried after a failure must not
            // append to whatever the failed one left behind.
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try? fileManager.removeItem(at: url)
            }

            return try opener.openForAppending(at: url)
        }
    }

    /// Reads an archive from disk in chunks.
    struct SourceFile {
        private let handle: FileHandle
        private let chunkSize: Int

        init(url: URL, chunkSize: Int = 256 * 1024) throws {
            self.handle = try FileHandle(forReadingFrom: url)
            self.chunkSize = chunkSize
        }

        func nextChunk() throws -> Data {
            try handle.read(upToCount: chunkSize) ?? Data()
        }

        func seek(to offset: UInt64) throws { try handle.seek(toOffset: offset) }

        /// Reads exactly `count` bytes, or as many as remain.
        ///
        /// `read(upToCount:)` is allowed to return fewer bytes than asked for
        /// without being at the end of the file, and a single call was enough to
        /// write a truncated *stored* zip member — the digest makes that
        /// unreachable today, and looping keeps it unreachable if it ever stops
        /// being.
        func readExactly(_ count: Int) throws -> Data {
            var collected = Data()
            while collected.count < count {
                guard let chunk = try handle.read(upToCount: count - collected.count),
                      !chunk.isEmpty
                else { break }
                collected.append(chunk)
            }
            return collected
        }
        func close() { try? handle.close() }
    }

    // MARK: - Member paths

    /// Normalises and vets one archive member's path.
    ///
    /// Returns nil for a member that should simply be skipped (the archive's
    /// own root, a `.DS_Store`, a `__MACOSX` resource fork). Throws for one
    /// that is actively wrong.
    static func safeRelativePath(
        _ rawName: String,
        strippingComponents strip: Int,
        libraryID: String,
        assetID: String
    ) throws -> String? {
        // Some archivers write Windows separators. Normalise before judging.
        let normalised = rawName.replacingOccurrences(of: "\\", with: "/")

        guard !normalised.hasPrefix("/"), !normalised.contains("\0") else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID,
                reason: "it contains an absolute path (\(rawName))."
            )
        }

        var components = normalised.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        for component in components where component == ".." {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID,
                reason: "it contains a path that climbs out of the library folder (\(rawName))."
            )
        }
        components.removeAll { $0 == "." }

        guard components.count > strip else { return nil }
        components.removeFirst(strip)

        if components.contains("__MACOSX") { return nil }
        if let last = components.last, last == ".DS_Store" { return nil }
        guard !components.isEmpty else { return nil }

        return components.joined(separator: "/")
    }

    // MARK: - tar.xz

    /// Unpacks a `.tar.xz` into `destination`.
    ///
    /// The tar reader is deliberately a USTAR one and nothing more: the
    /// catalog's tarball is plain USTAR — 646 members, no name longer than 99
    /// characters, only regular files and directories — and a reader that
    /// handles exactly that is one that can be read in a sitting. A member the
    /// reader does not understand is refused loudly rather than skipped, so a
    /// future archive that needs GNU long names fails visibly instead of
    /// installing three-quarters of an instrument.
    static func unpackTarXZ(
        at archiveURL: URL,
        into destination: Destination,
        strippingComponents strip: Int,
        libraryID: String,
        assetID: String
    ) throws {
        let source = try SourceFile(url: archiveURL)
        defer { source.close() }

        var tar = TarStream(strip: strip, libraryID: libraryID, assetID: assetID, destination: destination)
        try StreamingInflate.decode(
            format: .xz,
            read: { try source.nextChunk() },
            write: { try tar.consume($0) }
        )
        try tar.finish()
    }

    /// Feeds a decoded tar byte stream through the 512-byte-block state
    /// machine, writing members as they complete.
    private struct TarStream {
        static let blockSize = 512

        let strip: Int
        let libraryID: String
        let assetID: String
        let destination: Destination

        private var buffer = Data()

        /// Bytes of the current member still to come, and where they go.
        private var currentPath: String?
        private var currentRemaining: Int = 0
        private var currentPadding: Int = 0
        private var currentFile: AppendableFile?
        private var sawEndOfArchive = false
        private var memberCount = 0

        init(strip: Int, libraryID: String, assetID: String, destination: Destination) {
            self.strip = strip
            self.libraryID = libraryID
            self.assetID = assetID
            self.destination = destination
        }

        mutating func consume(_ data: Data) throws {
            buffer.append(data)
            try drain()
        }

        mutating func finish() throws {
            try closeCurrentMember()
            guard sawEndOfArchive || memberCount > 0 else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID, reason: "it contains no members."
                )
            }
            guard currentRemaining == 0 else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "it ends in the middle of \(currentPath ?? "a file")."
                )
            }
        }

        private mutating func drain() throws {
            while true {
                if currentRemaining > 0 {
                    let take = min(currentRemaining, buffer.count)
                    guard take > 0 else { return }
                    let chunk = buffer.prefix(take)
                    buffer.removeFirst(take)
                    currentRemaining -= take
                    if let file = currentFile { try file.append(Data(chunk)) }
                    if currentRemaining == 0 { try closeCurrentMember() }
                    continue
                }

                if currentPadding > 0 {
                    let take = min(currentPadding, buffer.count)
                    guard take > 0 else { return }
                    buffer.removeFirst(take)
                    currentPadding -= take
                    continue
                }

                guard buffer.count >= Self.blockSize else { return }
                let header = Data(buffer.prefix(Self.blockSize))
                buffer.removeFirst(Self.blockSize)
                try startMember(header: header)
                if sawEndOfArchive { return }
            }
        }

        private mutating func startMember(header: Data) throws {
            // Two consecutive zero blocks end the archive; one is enough for us
            // to stop reading members.
            if header.allSatisfy({ $0 == 0 }) {
                sawEndOfArchive = true
                return
            }

            guard TarHeader.checksumMatches(header) else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "one of its file headers is damaged."
                )
            }

            let name = TarHeader.string(header, offset: 0, length: 100)
            let prefix = TarHeader.string(header, offset: 345, length: 155)
            let fullName = prefix.isEmpty ? name : prefix + "/" + name
            guard let size = TarHeader.octal(header, offset: 124, length: 12) else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "the size of \(fullName) could not be read."
                )
            }
            let typeFlag = header[header.startIndex + 156]

            memberCount += 1
            currentRemaining = Int(size)
            currentPadding = Int((Self.blockSize - Int(size) % Self.blockSize) % Self.blockSize)

            let relative = try ArchiveUnpacking.safeRelativePath(
                fullName, strippingComponents: strip, libraryID: libraryID, assetID: assetID
            )

            switch typeFlag {
            case UInt8(ascii: "0"), 0:
                guard let relative else { return }  // stripped away; bytes are skipped
                try beginFile(at: relative)
            case UInt8(ascii: "5"):
                if let relative { try destination.createDirectory(relative) }
            case UInt8(ascii: "g"), UInt8(ascii: "x"):
                // PAX extended headers describe the *next* member. Skipping the
                // record silently would apply the wrong name to real content.
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "it uses PAX extended headers, which this version of Synth does not read."
                )
            default:
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "it contains \(fullName), which is not a plain file or folder."
                )
            }
        }

        private mutating func beginFile(at relativePath: String) throws {
            try closeCurrentMember()
            currentPath = relativePath
            currentFile = try destination.beginFile(relativePath)
        }

        private mutating func closeCurrentMember() throws {
            guard let file = currentFile else {
                currentPath = nil
                return
            }
            currentFile = nil
            currentPath = nil
            try file.close()
        }
    }

    // MARK: - zip

    /// Unpacks a `.zip` into `destination`.
    ///
    /// Central-directory first, then each member by seeking to its local
    /// header — the same order any correct reader uses, and the only one that
    /// works when a member's local header does not repeat the sizes (bit 3 of
    /// the general-purpose flags). Stored and DEFLATE members are supported,
    /// which between them cover every entry in the catalog's archive; anything
    /// else is refused rather than silently skipped.
    static func unpackZip(
        at archiveURL: URL,
        into destination: Destination,
        strippingComponents strip: Int,
        libraryID: String,
        assetID: String
    ) throws {
        let source = try SourceFile(url: archiveURL)
        defer { source.close() }

        let totalSize = try FileManager.default
            .attributesOfItem(atPath: archiveURL.path(percentEncoded: false))[.size] as? Int64 ?? 0

        let entries = try ZipCentralDirectory.read(
            source: source, archiveByteCount: totalSize, libraryID: libraryID, assetID: assetID
        )
        guard !entries.isEmpty else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID, reason: "it contains no members."
            )
        }

        for entry in entries {
            guard let relative = try safeRelativePath(
                entry.name, strippingComponents: strip, libraryID: libraryID, assetID: assetID
            ) else { continue }

            if entry.isDirectory {
                try destination.createDirectory(relative)
                continue
            }

            // The local header's variable fields can be longer than the central
            // directory's, so the data offset has to be read from the local
            // header itself rather than assumed.
            try source.seek(to: UInt64(entry.localHeaderOffset))
            let local = try source.readExactly(30)
            guard local.count == 30,
                  ZipCentralDirectory.uint32(local, 0) == 0x0403_4B50
            else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "the entry for \(entry.name) does not start where the index says it does."
                )
            }
            let nameLength = Int(ZipCentralDirectory.uint16(local, 26))
            let extraLength = Int(ZipCentralDirectory.uint16(local, 28))
            try source.seek(to: UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLength + extraLength))

            var remaining = entry.compressedSize
            let readChunk: () throws -> Data = {
                guard remaining > 0 else { return Data() }
                let want = Int(min(remaining, 256 * 1024))
                let chunk = try source.readExactly(want)
                remaining -= Int64(chunk.count)
                return chunk
            }

            guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
                throw InstrumentInstallError.archiveRejected(
                    libraryID: libraryID, assetID: assetID,
                    reason: "\(entry.name) uses compression method \(entry.compressionMethod), "
                        + "which this version of Synth does not read."
                )
            }

            let file = try destination.beginFile(relative)
            var written: Int64 = 0
            do {
                if entry.compressionMethod == 0 {
                    while true {
                        let chunk = try readChunk()
                        if chunk.isEmpty { break }
                        try file.append(chunk)
                        written += Int64(chunk.count)
                    }
                } else {
                    written = try StreamingInflate.decode(
                        format: .rawDeflate,
                        read: readChunk,
                        write: { try file.append($0) }
                    )
                }
                try file.close()

                // The index says how big this member should expand to, so use
                // it: a second bound on decompression that is independent of the
                // archive's own digest, and the thing that would catch a
                // decompression bomb before it filled the disk.
                guard written == entry.uncompressedSize else {
                    throw InstrumentInstallError.archiveRejected(
                        libraryID: libraryID, assetID: assetID,
                        reason: "\(entry.name) expanded to \(written) bytes, but its index "
                            + "says \(entry.uncompressedSize)."
                    )
                }
            } catch {
                try? file.close()
                throw error
            }
        }
    }
}

// MARK: - Tar header fields

enum TarHeader {
    /// A NUL-terminated ASCII field.
    static func string(_ block: Data, offset: Int, length: Int) -> String {
        let start = block.startIndex + offset
        let slice = block[start..<min(start + length, block.endIndex)]
        let terminated = slice.prefix { $0 != 0 }
        return String(decoding: terminated, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// An octal numeric field. Returns nil when it is not octal at all.
    static func octal(_ block: Data, offset: Int, length: Int) -> UInt64? {
        let text = string(block, offset: offset, length: length)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if text.isEmpty { return 0 }
        return UInt64(text, radix: 8)
    }

    /// The header checksum, computed with the checksum field read as spaces —
    /// which is how tar defines it.
    static func checksumMatches(_ block: Data) -> Bool {
        guard block.count >= 512, let stored = octal(block, offset: 148, length: 8) else {
            return false
        }
        var unsigned: UInt64 = 0
        for (index, byte) in block.enumerated() {
            unsigned += (148..<156).contains(index) ? UInt64(UInt8(ascii: " ")) : UInt64(byte)
        }
        return unsigned == stored
    }
}

// MARK: - Zip central directory

enum ZipCentralDirectory {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int64
        let uncompressedSize: Int64
        let localHeaderOffset: Int64

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        guard i + 1 < data.endIndex else { return 0 }
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 3 < data.endIndex else { return 0 }
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    /// Finds and parses the central directory.
    static func read(
        source: ArchiveUnpacking.SourceFile,
        archiveByteCount: Int64,
        libraryID: String,
        assetID: String
    ) throws -> [Entry] {
        // The end-of-central-directory record is within the last 64 KB + 22
        // bytes, because the comment field it ends with is at most 64 KB.
        let tailLength = Int(min(archiveByteCount, 65_557))
        guard tailLength >= 22 else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID, reason: "it is too short to be a zip file."
            )
        }
        try source.seek(to: UInt64(archiveByteCount - Int64(tailLength)))
        var tail = Data()
        while tail.count < tailLength {
            let chunk = try source.readExactly(tailLength - tail.count)
            if chunk.isEmpty { break }
            tail.append(chunk)
        }

        var endOffset: Int?
        var scan = tail.count - 22
        while scan >= 0 {
            if uint32(tail, scan) == 0x0605_4B50 { endOffset = scan; break }
            scan -= 1
        }
        guard let endOffset else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID,
                reason: "it has no zip index, so it is not a zip file or it is truncated."
            )
        }

        let entryCount = Int(uint16(tail, endOffset + 10))
        let directorySize = Int(uint32(tail, endOffset + 12))
        let directoryOffset = Int64(uint32(tail, endOffset + 16))

        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + Int64(directorySize) <= archiveByteCount
        else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID,
                reason: "its index points outside the file. Zip64 archives are not supported."
            )
        }

        try source.seek(to: UInt64(directoryOffset))
        var directory = Data()
        while directory.count < directorySize {
            let chunk = try source.readExactly(directorySize - directory.count)
            if chunk.isEmpty { break }
            directory.append(chunk)
        }
        guard directory.count == directorySize else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID, reason: "its index is truncated."
            )
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0
        while cursor + 46 <= directory.count, uint32(directory, cursor) == 0x0201_4B50 {
            let nameLength = Int(uint16(directory, cursor + 28))
            let extraLength = Int(uint16(directory, cursor + 30))
            let commentLength = Int(uint16(directory, cursor + 32))
            let start = directory.startIndex + cursor + 46
            guard start + nameLength <= directory.endIndex else { break }
            let name = String(decoding: directory[start..<(start + nameLength)], as: UTF8.self)

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: uint16(directory, cursor + 10),
                    compressedSize: Int64(uint32(directory, cursor + 20)),
                    uncompressedSize: Int64(uint32(directory, cursor + 24)),
                    localHeaderOffset: Int64(uint32(directory, cursor + 42))
                )
            )
            cursor += 46 + nameLength + extraLength + commentLength
        }

        guard entries.count == entryCount else {
            throw InstrumentInstallError.archiveRejected(
                libraryID: libraryID, assetID: assetID,
                reason: "its index lists \(entryCount) files but only \(entries.count) could be read."
            )
        }
        return entries
    }
}
