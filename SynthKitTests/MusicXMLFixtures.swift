import Compression
import Foundation
@testable import SynthKit

/// Fixture MusicXML and `.mxl` bytes, built in code rather than checked in.
///
/// Two reasons the archives are assembled here instead of shipped as binary
/// test resources: the ZIP reader is exercised against bytes whose exact
/// structure the test controls (stored *and* deflated entries, deliberate
/// truncation, a wrong checksum), and the repository keeps no opaque blobs.
enum MusicXMLFixtures {
    /// A complete, if tiny, MusicXML 4.0 part-wise score.
    static func score(
        workTitle: String? = "Prelude in C",
        workNumber: String? = "BWV 846",
        movementTitle: String? = nil,
        movementNumber: String? = nil,
        composer: String? = "Johann Sebastian Bach",
        creditWords: [String] = [],
        includeDoctype: Bool = true
    ) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        if includeDoctype {
            xml += "\n" + #"<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">"#
        }
        xml += "\n<score-partwise version=\"4.0\">\n"

        if workTitle != nil || workNumber != nil {
            xml += "  <work>\n"
            if let workNumber { xml += "    <work-number>\(escape(workNumber))</work-number>\n" }
            if let workTitle { xml += "    <work-title>\(escape(workTitle))</work-title>\n" }
            xml += "  </work>\n"
        }
        if let movementNumber { xml += "  <movement-number>\(escape(movementNumber))</movement-number>\n" }
        if let movementTitle { xml += "  <movement-title>\(escape(movementTitle))</movement-title>\n" }
        if let composer {
            xml += """
                  <identification>
                    <creator type="composer">\(escape(composer))</creator>
                    <encoding>
                      <software>SynthKitTests</software>
                    </encoding>
                  </identification>

                """
        }
        for words in creditWords {
            xml += """
                  <credit page="1">
                    <credit-type>title</credit-type>
                    <credit-words>\(escape(words))</credit-words>
                  </credit>

                """
        }

        xml += """
              <part-list>
                <score-part id="P1">
                  <part-name>Piano</part-name>
                </score-part>
              </part-list>
              <part id="P1">
                <measure number="1">
                  <attributes>
                    <divisions>1</divisions>
                    <key><fifths>0</fifths></key>
                    <time><beats>4</beats><beat-type>4</beat-type></time>
                    <clef><sign>G</sign><line>2</line></clef>
                  </attributes>
                  <note>
                    <pitch><step>C</step><octave>4</octave></pitch>
                    <duration>4</duration>
                    <type>whole</type>
                  </note>
                </measure>
              </part>
            </score-partwise>

            """
        return Data(xml.utf8)
    }

    /// The `META-INF/container.xml` a `.mxl` must carry.
    static func containerDescriptor(
        rootfilePath: String = "score.xml",
        mediaType: String? = MusicXMLContainerDescriptor.musicXMLMediaType
    ) -> Data {
        let mediaAttribute = mediaType.map { #" media-type="\#(escape($0))""# } ?? ""
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container>
              <rootfiles>
                <rootfile full-path="\(escape(rootfilePath))"\(mediaAttribute)/>
              </rootfiles>
            </container>

            """.utf8
        )
    }

    /// A well-formed `.mxl`: descriptor plus score, exactly as a notation app
    /// writes one.
    static func compressedScore(
        score: Data = MusicXMLFixtures.score(),
        rootfilePath: String = "score.xml",
        descriptor: Data? = nil,
        deflateScore: Bool = true
    ) -> Data {
        var entries: [ZipBuilder.Entry] = []
        if let descriptor {
            entries.append(.init(name: MusicXMLContainerDescriptor.entryName, data: descriptor, deflate: false))
        } else {
            entries.append(
                .init(
                    name: MusicXMLContainerDescriptor.entryName,
                    data: containerDescriptor(rootfilePath: rootfilePath),
                    deflate: false
                )
            )
        }
        entries.append(.init(name: rootfilePath, data: score, deflate: deflateScore))
        return ZipBuilder.archive(entries)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A minimal ZIP writer for fixtures: stored or deflated entries, no ZIP64.
///
/// Deliberately independent of `ZipArchive` — the reader under test is never
/// asked to validate its own idea of the format.
enum ZipBuilder {
    struct Entry {
        let name: String
        let data: Data
        var deflate: Bool = false

        /// Overrides the CRC written for this entry, to fabricate damage.
        var crcOverride: UInt32?
    }

    static func archive(_ entries: [Entry], comment: String = "") -> Data {
        var payload = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let raw = [UInt8](entry.data)
            let crc = entry.crcOverride ?? CRC32.checksum(raw)
            let stored: Data
            let method: UInt16
            if entry.deflate, let compressed = Deflater.deflate(entry.data) {
                stored = compressed
                method = 8
            } else {
                stored = entry.data
                method = 0
            }

            offsets.append(payload.count)

            payload.append(uint32(0x0403_4b50))
            payload.append(uint16(20))              // version needed
            payload.append(uint16(0x0800))          // UTF-8 name flag
            payload.append(uint16(method))
            payload.append(uint16(0))               // mod time
            payload.append(uint16(0))               // mod date
            payload.append(uint32(crc))
            payload.append(uint32(UInt32(stored.count)))
            payload.append(uint32(UInt32(entry.data.count)))
            payload.append(uint16(UInt16(nameBytes.count)))
            payload.append(uint16(0))               // extra length
            payload.append(nameBytes)
            payload.append(stored)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.name.utf8)
            let raw = [UInt8](entry.data)
            let crc = entry.crcOverride ?? CRC32.checksum(raw)
            let compressedCount: Int
            let method: UInt16
            if entry.deflate, let compressed = Deflater.deflate(entry.data) {
                compressedCount = compressed.count
                method = 8
            } else {
                compressedCount = entry.data.count
                method = 0
            }

            central.append(uint32(0x0201_4b50))
            central.append(uint16(20))              // version made by
            central.append(uint16(20))              // version needed
            central.append(uint16(0x0800))
            central.append(uint16(method))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint32(crc))
            central.append(uint32(UInt32(compressedCount)))
            central.append(uint32(UInt32(entry.data.count)))
            central.append(uint16(UInt16(nameBytes.count)))
            central.append(uint16(0))               // extra
            central.append(uint16(0))               // comment
            central.append(uint16(0))               // disk start
            central.append(uint16(0))               // internal attrs
            central.append(uint32(0))               // external attrs
            central.append(uint32(UInt32(offsets[index])))
            central.append(nameBytes)
        }

        let commentBytes = Data(comment.utf8)
        var end = Data()
        end.append(uint32(0x0605_4b50))
        end.append(uint16(0))
        end.append(uint16(0))
        end.append(uint16(UInt16(entries.count)))
        end.append(uint16(UInt16(entries.count)))
        end.append(uint32(UInt32(central.count)))
        end.append(uint32(UInt32(payload.count)))
        end.append(uint16(UInt16(commentBytes.count)))

        return payload + central + end + commentBytes
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}

/// Raw DEFLATE for fixtures, the mirror of `ZipArchive`'s inflate.
enum Deflater {
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: source.count + 4096)

        let written = destination.withUnsafeMutableBufferPointer { destinationBuffer -> Int in
            source.withUnsafeBufferPointer { sourceBuffer -> Int in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceBuffer.baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    destinationBuffer.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }
}
