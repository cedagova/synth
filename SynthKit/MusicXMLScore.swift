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

    /// `credit/credit-words` in document order, with engraving attributes.
    /// Engravers routinely put the only human-readable title here and leave
    /// `work-title` empty — but they also put page footers here, so the
    /// attributes matter.
    var creditEntries: [MusicXMLStyledWords] = []

    /// The credit texts alone, in document order.
    var creditWords: [String] { creditEntries.map(\.text) }

    /// The first credit that plausibly is a title: unstyled (a bare credit is
    /// how most exporters write the title), bold, or set large. A credit set
    /// visibly small — an 8pt "BWV 1046 - S. #" page footer — is not one.
    var creditTitle: String? {
        creditEntries.first { $0.fontSize == nil || $0.isBold || ($0.fontSize ?? 0) >= 14 }?.text
    }

    /// `<direction><words>` of the first part's opening measures, with the
    /// engraving attributes that say what each one is. Some scores carry
    /// their only title and composer here, as page text over the first
    /// system — anchored to whichever measure happens to sit under it.
    var headingWords: [MusicXMLStyledWords] = []

    /// The engraved title, when the opening measures' page text names one:
    /// the words an engraver made big or bold. A tempo word ("Allegro") is
    /// neither, so it does not qualify. Ties on size go to the earliest.
    var headingTitle: String? {
        let candidates = headingWords.filter { $0.isBold || ($0.fontSize ?? 0) >= 14 }
        guard let best = candidates.map({ $0.fontSize ?? 0 }).max() else { return nil }
        return candidates.first { ($0.fontSize ?? 0) == best }?.text
    }

    /// The engraved composer: the first right-justified words of the heading
    /// that are not the title — where an engraver puts the author's name.
    /// Only the first line of that block: engravers stack the composer over
    /// the catalogue number and the arranger inside one element.
    var headingComposer: String? {
        headingWords
            .first { $0.justify == "right" && $0.text != headingTitle }?
            .text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The MusicXML score roots this build accepts.
    static let acceptedRootElements: Set<String> = ["score-partwise", "score-timewise"]

    /// True when the document really is a MusicXML score rather than some
    /// other well-formed XML (or a MusicXML *opus*, which lists scores rather
    /// than being one).
    var isMusicXMLScore: Bool { Self.acceptedRootElements.contains(rootElement) }
}

/// One piece of engraved text — a `<credit-words>` or a first-measure
/// `<direction><words>` — with the attributes that distinguish a title from
/// a tempo mark or a page footer.
struct MusicXMLStyledWords: Equatable, Sendable {
    var text: String
    var fontSize: Double?
    var isBold: Bool
    var justify: String?
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
            creditEntries: scanner.creditEntries,
            headingWords: scanner.headingWords
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
    private(set) var creditEntries: [MusicXMLStyledWords] = []
    private(set) var headingWords: [MusicXMLStyledWords] = []

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

    /// How many `<measure>` and `<part>` elements have started. Page-heading
    /// text is anchored to whichever opening measure sits under it, so the
    /// window is the first part's first few measures; everything after
    /// streams past uncaptured.
    private var measuresSeen = 0
    private var partsSeen = 0

    /// Attributes of the styled words element being read, and which list it
    /// belongs to.
    private var pendingWordsAttributes: [String: String]?
    private var pendingWordsAreCredit = false

    /// How many credit-words to keep. A title fallback needs the first one;
    /// a couple more cost nothing and make the choice inspectable.
    private static let maximumCreditWords = 4

    /// Enough for a title, a composer, an arranger and a few tempo marks.
    private static let maximumHeadingWords = 8

    /// How many opening measures may carry heading text. Engravers anchor a
    /// page heading to the measure under it, which is not always the first.
    private static let headingMeasureWindow = 8

    /// True while `<words>` still count as page heading. A timewise score
    /// nests a `<part>` inside every measure, so the part guard applies only
    /// to partwise documents.
    private var headingWindowIsOpen: Bool {
        guard (1...Self.headingMeasureWindow).contains(measuresSeen) else { return false }
        return rootElement == "score-timewise" || partsSeen <= 1
    }

    /// Paths, relative to the root element, whose text we capture.
    private static let capturedPaths: Set<[String]> = [
        ["work", "work-title"],
        ["work", "work-number"],
        ["movement-title"],
        ["movement-number"],
        ["identification", "creator"]
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

        if elementName == "measure" { measuresSeen += 1 }
        if elementName == "part" { partsSeen += 1 }

        let relative = Array(path.dropFirst())
        guard buffer == nil else { return }

        // The opening measures' direction words: the page text an engraver
        // put over the first system, where some scores keep their only title
        // and composer.
        if headingWindowIsOpen,
           headingWords.count < Self.maximumHeadingWords,
           relative.suffix(3) == ["direction", "direction-type", "words"] {
            buffer = ""
            bufferDepth = path.count
            pendingWordsAttributes = attributeDict
            pendingWordsAreCredit = false
            return
        }

        // Credits keep their attributes too: an 8pt page footer and a title
        // both live in credit-words, and only the styling tells them apart.
        if relative == ["credit", "credit-words"], creditEntries.count < Self.maximumCreditWords {
            buffer = ""
            bufferDepth = path.count
            pendingWordsAttributes = attributeDict
            pendingWordsAreCredit = true
            return
        }

        guard Self.capturedPaths.contains(relative) else { return }

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

        if let attributes = pendingWordsAttributes {
            pendingWordsAttributes = nil
            if !value.isEmpty {
                let words = MusicXMLStyledWords(
                    text: value,
                    fontSize: attributes["font-size"].flatMap(Double.init),
                    isBold: attributes["font-weight"]?.lowercased() == "bold",
                    justify: attributes["justify"]?.lowercased()
                )
                if pendingWordsAreCredit {
                    creditEntries.append(words)
                } else {
                    headingWords.append(words)
                }
            }
            return
        }

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
        default:
            break
        }
    }
}
