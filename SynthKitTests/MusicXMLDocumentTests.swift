import XCTest
@testable import SynthKit

/// The tree reader compilation is built on, and the parser hardening both
/// MusicXML readers share.
final class MusicXMLDocumentTests: XCTestCase {
    func testElementsKeepTheirAttributesTextAndChildOrder() throws {
        let root = try MusicXMLDocument.parse(
            Data(#"<part id="P1"><measure number="1"><note>x</note><note>y</note></measure></part>"#.utf8)
        )
        XCTAssertEqual(root.name, "part")
        XCTAssertEqual(root.attribute("id"), "P1")

        let measure = try XCTUnwrap(root.child("measure"))
        XCTAssertEqual(measure.attribute("number"), "1")
        XCTAssertEqual(measure.childrenNamed("note").map(\.text), ["x", "y"])
    }

    func testTextIsTrimmedAndCDATAIsRead() throws {
        let root = try MusicXMLDocument.parse(
            Data("<work>\n  <work-title>  <![CDATA[Prelude]]>  </work-title>\n</work>".utf8)
        )
        XCTAssertEqual(root.childText("work-title"), "Prelude")
    }

    func testAnEmptyChildReadsAsAbsentRatherThanAsAnEmptyString() throws {
        let root = try MusicXMLDocument.parse(Data("<work><work-title/></work>".utf8))
        XCTAssertNil(root.childText("work-title"))
        XCTAssertNotNil(root.child("work-title"))
    }

    func testYesNoAttributesAreReadAsBooleans() throws {
        let root = try MusicXMLDocument.parse(Data(#"<measure implicit="yes" other="no"/>"#.utf8))
        XCTAssertTrue(root.attributeIsYes("implicit"))
        XCTAssertFalse(root.attributeIsYes("other"))
        XCTAssertFalse(root.attributeIsYes("absent"))
    }

    func testADocumentThatIsNotWellFormedIsRejectedWithItsPosition() {
        XCTAssertThrowsError(try MusicXMLDocument.parse(Data("<a><b></a>".utf8))) { error in
            guard case MusicXMLParseError.notWellFormed(_, let line, _) = error else {
                return XCTFail("expected notWellFormed, got \(error)")
            }
            XCTAssertGreaterThan(line, 0)
        }
    }

    /// A document with no elements never comes back as an empty tree. In
    /// practice libxml2 rejects it first, which is why `noRootElement` is the
    /// belt to that braces rather than the usual path.
    func testADocumentWithNoElementsIsRejectedRatherThanReturningAnEmptyTree() {
        for empty in ["   \n ", "", "<!-- nothing here -->"] {
            XCTAssertThrowsError(try MusicXMLDocument.parse(Data(empty.utf8))) { error in
                XCTAssertTrue(
                    error is MusicXMLParseError,
                    "expected a MusicXMLParseError for \"\(empty)\", got \(error)"
                )
            }
        }
    }

    /// The reader must never fetch an external entity — not the MusicXML DTD
    /// on musicxml.org, and not a local file a hostile score points at.
    /// REQ-028 forbids the network outright, and reading `/etc/passwd` into a
    /// score would be worse still.
    func testAnExternalEntityIsNeverResolved() throws {
        let hostile = """
            <?xml version="1.0"?>
            <!DOCTYPE score-partwise [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
            <score-partwise><work><work-title>&secret;</work-title></work></score-partwise>
            """
        // Either the parser refuses the document or it yields an empty title.
        // What it must never do is return the file's contents.
        if let root = try? MusicXMLDocument.parse(Data(hostile.utf8)) {
            let title = root.child("work")?.childText("work-title") ?? ""
            XCTAssertFalse(title.contains("root:"), "an external entity was resolved")
            XCTAssertFalse(title.contains("/bin/"), "an external entity was resolved")
        }
    }

    func testTheDoctypeAMusicXMLFileNormallyCarriesIsNotFetched() throws {
        // The fixtures write the real MusicXML 4.0 DOCTYPE. If the parser were
        // resolving it, this call would try to reach musicxml.org.
        let root = try MusicXMLDocument.parse(MusicXMLScoreFixtures.repeatsVoltasAndDaCapo())
        XCTAssertEqual(root.name, "score-partwise")
    }

    func testDescendantsAreVisitedInDocumentOrder() throws {
        let root = try MusicXMLDocument.parse(Data("<a><b><c/></b><d/></a>".utf8))
        var visited: [String] = []
        root.forEachDescendant { visited.append($0.name) }
        XCTAssertEqual(visited, ["a", "b", "c", "d"])
    }

    /// A file that nests a hundred thousand elements deep is rejected as
    /// malformed rather than exhausting the stack when the tree is released.
    func testAbsurdlyDeepNestingIsRejectedRatherThanExhaustingTheStack() {
        let depth = MusicXMLDocument.maximumDepth + 50
        let deep = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)

        XCTAssertThrowsError(try MusicXMLDocument.parse(Data(deep.utf8))) { error in
            guard case MusicXMLParseError.notWellFormed(let reason, _, _) = error else {
                return XCTFail("expected notWellFormed, got \(error)")
            }
            XCTAssertTrue(reason.contains("nest"), "got \(reason)")
        }
    }

    func testNestingUpToTheLimitStillParses() throws {
        let depth = MusicXMLDocument.maximumDepth - 1
        let deep = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        XCTAssertEqual(try MusicXMLDocument.parse(Data(deep.utf8)).name, "a")
    }
}
