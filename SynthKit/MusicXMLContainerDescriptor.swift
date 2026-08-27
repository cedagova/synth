import Foundation

/// One `<rootfile>` declared by a compressed MusicXML container.
struct MusicXMLRootfile: Equatable, Sendable {
    let fullPath: String
    let mediaType: String?
}

/// The `META-INF/container.xml` inside a `.mxl`, which is the only sanctioned
/// way to learn which entry holds the score.
///
/// A `.mxl` is a ZIP whose entry names are arbitrary; the container descriptor
/// is what makes the archive self-describing, so this build follows it rather
/// than guessing from file extensions.
struct MusicXMLContainerDescriptor: Equatable, Sendable {
    /// Path of the descriptor inside the archive, per the MusicXML spec.
    static let entryName = "META-INF/container.xml"

    /// Media type a rootfile declares when it is the MusicXML score.
    static let musicXMLMediaType = "application/vnd.recordare.musicxml+xml"

    let rootfiles: [MusicXMLRootfile]

    /// The entry that holds the score: the first rootfile declaring the
    /// MusicXML media type, or — when no rootfile declares one at all — the
    /// first rootfile listed. A descriptor that only declares *other* media
    /// types has no score in it and yields `nil`.
    var scoreEntryName: String? {
        if let declared = rootfiles.first(where: {
            $0.mediaType?.lowercased() == Self.musicXMLMediaType
        }) {
            return declared.fullPath
        }
        guard rootfiles.allSatisfy({ $0.mediaType == nil }) else { return nil }
        return rootfiles.first?.fullPath
    }

    static func parse(_ data: Data) throws -> MusicXMLContainerDescriptor {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let scanner = ContainerScanner()
        parser.delegate = scanner

        guard parser.parse() else {
            let error = parser.parserError as NSError?
            throw MusicXMLParseError.notWellFormed(
                reason: error?.localizedDescription ?? "the container descriptor is not well-formed XML",
                line: parser.lineNumber,
                column: parser.columnNumber
            )
        }
        return MusicXMLContainerDescriptor(rootfiles: scanner.rootfiles)
    }
}

private final class ContainerScanner: NSObject, XMLParserDelegate {
    private(set) var rootfiles: [MusicXMLRootfile] = []

    /// Enough for any real container; a descriptor listing thousands of
    /// rootfiles is malformed, not interesting.
    private static let maximumRootfiles = 32

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "rootfile", rootfiles.count < Self.maximumRootfiles else { return }
        let fullPath = (attributeDict["full-path"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullPath.isEmpty else { return }

        rootfiles.append(
            MusicXMLRootfile(
                fullPath: fullPath,
                mediaType: attributeDict["media-type"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}
