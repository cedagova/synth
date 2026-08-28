import Foundation

/// The metadata LIB002 extracts from a score, before fallbacks are applied.
///
/// Every field is optional because real files omit most of them. Turning this
/// into a `PieceRecord` is where the fallbacks live, so the raw reading of the
/// file stays honest.
struct MusicXMLScoreMetadata: Equatable, Sendable {
    /// The document's root element, e.g. `score-partwise`.
    var rootElement: String

    var workTitle: String?
    var workNumber: String?
    var movementTitle: String?
    var movementNumber: String?
    var composer: String?

    /// `credit/credit-words` in document order. Engravers routinely put the
    /// only human-readable title here and leave `work-title` empty.
    var creditWords: [String] = []

    /// The MusicXML score roots this build accepts.
    static let acceptedRootElements: Set<String> = ["score-partwise", "score-timewise"]

    /// True when the document really is a MusicXML score rather than some
    /// other well-formed XML (or a MusicXML *opus*, which lists scores rather
    /// than being one).
    var isMusicXMLScore: Bool { Self.acceptedRootElements.contains(rootElement) }
}

/// Why a MusicXML document could not be read.
enum MusicXMLParseError: Error, Equatable {
    /// libxml2 rejected the document. `reason` is its own wording.
    case notWellFormed(reason: String, line: Int, column: Int)

    /// Parsing produced no root element at all (an empty or whitespace file).
    case noRootElement
}

/// Reads a MusicXML score's structure and metadata with Foundation's XML
/// parser (AD4: our own importer, no third-party notation dependency).
///
/// Parsing the whole document *is* the acceptance check: a file that libxml2
/// will not finish is rejected before anything touches the library.
enum MusicXMLScore {
    /// Parses `data` and returns its metadata, or throws on a document that is
    /// not well-formed.
    static func metadata(from data: Data) throws -> MusicXMLScoreMetadata {
        // Hardened in one place for every MusicXML reader: external entities
        // are never resolved, so a DOCTYPE pointing at musicxml.org — or a
        // hostile entity pointing at a local file — is never fetched.
        let parser = MusicXMLParsing.makeParser(data)

        let scanner = MusicXMLScanner()
        parser.delegate = scanner

        guard parser.parse() else {
            let error = parser.parserError as NSError?
            throw MusicXMLParseError.notWellFormed(
                reason: error?.localizedDescription ?? "the document is not well-formed XML",
                line: parser.lineNumber,
                column: parser.columnNumber
            )
        }
        guard let rootElement = scanner.rootElement else {
            throw MusicXMLParseError.noRootElement
        }

        return MusicXMLScoreMetadata(
            rootElement: rootElement,
            workTitle: scanner.workTitle,
            workNumber: scanner.workNumber,
            movementTitle: scanner.movementTitle,
            movementNumber: scanner.movementNumber,
            composer: scanner.composer ?? scanner.untypedCreator,
            creditWords: scanner.creditWords
        )
    }
}

/// The SAX delegate behind `MusicXMLScore.metadata(from:)`.
///
/// It buffers only the handful of small header elements the library needs; the
/// musical body streams past untouched, which is what keeps a large orchestral
/// score cheap to import. Interpreting that body is increment 002's job.
private final class MusicXMLScanner: NSObject, XMLParserDelegate {
    private(set) var rootElement: String?
    private(set) var workTitle: String?
    private(set) var workNumber: String?
    private(set) var movementTitle: String?
    private(set) var movementNumber: String?
    private(set) var composer: String?
    private(set) var creditWords: [String] = []

    /// A type-less `<creator>`: the composer of last resort, resolved only
    /// after the whole document has been read so a typed composer appearing
    /// later in the file still wins.
    private(set) var untypedCreator: String?

    /// Element names from the root down to the element being parsed.
    private var path: [String] = []

    /// Text being collected, and the depth of the element it belongs to.
    private var buffer: String?
    private var bufferDepth: Int?

    /// `type` of the `creator` currently being read.
    private var creatorType: String?

    /// How many credit-words to keep. A title fallback needs the first one;
    /// a couple more cost nothing and make the choice inspectable.
    private static let maximumCreditWords = 4

    /// Paths, relative to the root element, whose text we capture.
    private static let capturedPaths: Set<[String]> = [
        ["work", "work-title"],
        ["work", "work-number"],
        ["movement-title"],
        ["movement-number"],
        ["identification", "creator"],
        ["credit", "credit-words"]
    ]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        path.append(elementName)
        if rootElement == nil { rootElement = elementName }

        let relative = Array(path.dropFirst())
        guard buffer == nil, Self.capturedPaths.contains(relative) else { return }

        buffer = ""
        bufferDepth = path.count
        creatorType = relative == ["identification", "creator"]
            ? attributeDict["type"]?.lowercased()
            : nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard buffer != nil else { return }
        buffer?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard buffer != nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        buffer?.append(text)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            if !path.isEmpty { path.removeLast() }
        }

        guard bufferDepth == path.count, let text = buffer else { return }
        buffer = nil
        bufferDepth = nil

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative = Array(path.dropFirst())
        guard !value.isEmpty else {
            creatorType = nil
            return
        }

        switch relative {
        case ["work", "work-title"]:
            workTitle = workTitle ?? value
        case ["work", "work-number"]:
            workNumber = workNumber ?? value
        case ["movement-title"]:
            movementTitle = movementTitle ?? value
        case ["movement-number"]:
            movementNumber = movementNumber ?? value
        case ["identification", "creator"]:
            if creatorType == "composer" {
                composer = composer ?? value
            } else if creatorType == nil {
                untypedCreator = untypedCreator ?? value
            }
            creatorType = nil
        case ["credit", "credit-words"]:
            if creditWords.count < Self.maximumCreditWords {
                creditWords.append(value)
            }
        default:
            break
        }
    }
}
