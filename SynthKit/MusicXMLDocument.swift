import Foundation

/// One element of a parsed MusicXML document, with its attributes, its own
/// text, and its children in document order.
///
/// Increment 001 reads MusicXML with a streaming delegate that keeps only a
/// handful of header fields, because import must stay cheap on a large
/// orchestral score. Compilation is the opposite problem: it needs the whole
/// musical body, repeatedly, in order. A tree is the honest shape for that.
///
/// Both readers are the same parser with the same hardening
/// (`MusicXMLParsing.makeParser`); only the delegate differs.
struct MusicXMLElement: Sendable {
    let name: String
    let attributes: [String: String]

    /// The element's own character data, trimmed. Empty for container
    /// elements.
    let text: String

    let children: [MusicXMLElement]

    /// The first child named `name`, or nil.
    func child(_ name: String) -> MusicXMLElement? {
        children.first { $0.name == name }
    }

    /// Every child named `name`, in document order.
    func childrenNamed(_ name: String) -> [MusicXMLElement] {
        children.filter { $0.name == name }
    }

    /// Trimmed text of the first child named `name`.
    func childText(_ name: String) -> String? {
        guard let value = child(name)?.text, !value.isEmpty else { return nil }
        return value
    }

    /// Integer value of the first child named `name`.
    func childInt(_ name: String) -> Int? {
        childText(name).flatMap(Int.init)
    }

    /// `attributes[name]`, trimmed, nil when absent or empty.
    func attribute(_ name: String) -> String? {
        guard let value = attributes[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// True for MusicXML's `yes`/`no` attribute type.
    func attributeIsYes(_ name: String) -> Bool {
        attribute(name)?.lowercased() == "yes"
    }

    /// Visits every element in this subtree, self first, in document order.
    ///
    /// A visitor rather than a returned array: an orchestral score is tens of
    /// thousands of elements, and materialising a second copy of the whole
    /// tree to look at one attribute is a waste the compiler makes on every
    /// piece. Iterative, so document depth cannot exhaust the stack.
    func forEachDescendant(_ body: (MusicXMLElement) -> Void) {
        var stack: [MusicXMLElement] = [self]
        while let element = stack.popLast() {
            body(element)
            stack.append(contentsOf: element.children.reversed())
        }
    }
}

/// Shared, hardened MusicXML parsing setup.
enum MusicXMLParsing {
    /// An `XMLParser` that will never resolve an external entity.
    ///
    /// A MusicXML file's DOCTYPE points at musicxml.org and a hostile file
    /// could point an entity at a local file. Neither is ever fetched. Every
    /// MusicXML reader in SynthKit is built here so that policy has exactly
    /// one definition.
    static func makeParser(_ data: Data) -> XMLParser {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser
    }
}

/// Reads a MusicXML document into a `MusicXMLElement` tree.
enum MusicXMLDocument {
    /// How deeply elements may nest. Real MusicXML nests about ten deep; the
    /// limit exists so a file built to nest a hundred thousand deep is
    /// rejected as malformed instead of exhausting the stack when the tree is
    /// released.
    static let maximumDepth = 256

    /// Parses `data` and returns its root element.
    ///
    /// - Throws: `MusicXMLParseError` for a document libxml2 will not finish,
    ///   one nested past `maximumDepth`, or one with no elements at all.
    static func parse(_ data: Data) throws -> MusicXMLElement {
        let parser = MusicXMLParsing.makeParser(data)
        let builder = TreeBuilder(maximumDepth: maximumDepth)
        parser.delegate = builder

        guard parser.parse() else {
            if builder.exceededDepth {
                throw MusicXMLParseError.notWellFormed(
                    reason: "its elements nest more than \(maximumDepth) deep",
                    line: parser.lineNumber,
                    column: parser.columnNumber
                )
            }
            let error = parser.parserError as NSError?
            throw MusicXMLParseError.notWellFormed(
                reason: error?.localizedDescription ?? "the document is not well-formed XML",
                line: parser.lineNumber,
                column: parser.columnNumber
            )
        }
        guard let root = builder.root else {
            throw MusicXMLParseError.noRootElement
        }
        return root
    }
}

/// Builds the element tree from SAX events.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    /// An element still being read: its own data plus the children closed so
    /// far. Turned into an immutable `MusicXMLElement` when it ends.
    private struct Frame {
        let name: String
        let attributes: [String: String]
        var text: String = ""
        var children: [MusicXMLElement] = []
    }

    private var stack: [Frame] = []
    private(set) var root: MusicXMLElement?

    private let maximumDepth: Int

    /// Set when the document was abandoned for nesting too deeply, so the
    /// caller can say that rather than repeating libxml2's generic wording.
    private(set) var exceededDepth = false

    init(maximumDepth: Int) {
        self.maximumDepth = maximumDepth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard stack.count < maximumDepth else {
            exceededDepth = true
            parser.abortParsing()
            return
        }
        stack.append(Frame(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text.append(text)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let frame = stack.popLast() else { return }
        let element = MusicXMLElement(
            name: frame.name,
            attributes: frame.attributes,
            text: frame.text.trimmingCharacters(in: .whitespacesAndNewlines),
            children: frame.children
        )
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(element)
        }
    }
}
