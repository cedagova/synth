import Foundation
import XCTest
@testable import SynthKit

final class MusicXMLScoreTests: XCTestCase {
    func testReadsTheHeaderFieldsOfAPartwiseScore() throws {
        let metadata = try MusicXMLScore.metadata(
            from: MusicXMLFixtures.score(
                workTitle: "Prelude in C",
                workNumber: "BWV 846",
                movementTitle: "Praeludium",
                movementNumber: "1",
                composer: "Johann Sebastian Bach",
                creditWords: ["Das Wohltemperierte Klavier"]
            )
        )

        XCTAssertEqual(metadata.rootElement, "score-partwise")
        XCTAssertTrue(metadata.isMusicXMLScore)
        XCTAssertEqual(metadata.workTitle, "Prelude in C")
        XCTAssertEqual(metadata.workNumber, "BWV 846")
        XCTAssertEqual(metadata.movementTitle, "Praeludium")
        XCTAssertEqual(metadata.movementNumber, "1")
        XCTAssertEqual(metadata.composer, "Johann Sebastian Bach")
        XCTAssertEqual(metadata.creditWords, ["Das Wohltemperierte Klavier"])
    }

    /// A score with an empty header whose title and composer exist only as
    /// page text engraved over the first measure — the BWV 1046 shape. The
    /// big bold words are the title, the first right-justified words the
    /// composer; a tempo mark and an arranger line must fool neither.
    func testReadsTitleAndComposerFromFirstMeasureHeadingWords() throws {
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="3.1">
              <part-list><score-part id="P1"><part-name>Violino</part-name></score-part></part-list>
              <part id="P1">
                <measure number="1">
                  <direction placement="above">
                    <direction-type>
                      <words font-size="17" font-weight="bold" justify="center">Brandenburgisches Konzert Nr. 1.</words>
                    </direction-type>
                  </direction>
                  <direction placement="above">
                    <direction-type>
                      <words font-size="10" justify="right">Johann Sebastian Bach</words>
                    </direction-type>
                  </direction>
                  <direction placement="above">
                    <direction-type>
                      <words font-size="10" justify="right">Klavierauszug: Someone Else</words>
                    </direction-type>
                  </direction>
                  <direction placement="above">
                    <direction-type><words>Allegro.</words></direction-type>
                  </direction>
                </measure>
                <measure number="2">
                  <direction placement="above">
                    <direction-type>
                      <words font-size="17" font-weight="bold">Not The Title</words>
                    </direction-type>
                  </direction>
                </measure>
              </part>
            </score-partwise>
            """.utf8)

        let metadata = try MusicXMLScore.metadata(from: xml)

        XCTAssertNil(metadata.workTitle)
        XCTAssertNil(metadata.composer)
        XCTAssertEqual(metadata.headingTitle, "Brandenburgisches Konzert Nr. 1.")
        XCTAssertEqual(metadata.headingComposer, "Johann Sebastian Bach")
        XCTAssertFalse(
            metadata.headingWords.contains { $0.text == "Not The Title" },
            "only the first measure's words are a heading"
        )
    }

    func testAcceptsATimewiseScore() throws {
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <score-timewise version="3.1">
              <work><work-title>Timewise</work-title></work>
              <part-list/>
            </score-timewise>
            """.utf8)

        let metadata = try MusicXMLScore.metadata(from: xml)

        XCTAssertEqual(metadata.rootElement, "score-timewise")
        XCTAssertTrue(metadata.isMusicXMLScore)
        XCTAssertEqual(metadata.workTitle, "Timewise")
    }

    func testAnOpusIsWellFormedButNotAScore() throws {
        let metadata = try MusicXMLScore.metadata(
            from: Data("<opus><opus-link xlink:href=\"a.xml\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"/></opus>".utf8)
        )

        XCTAssertEqual(metadata.rootElement, "opus")
        XCTAssertFalse(metadata.isMusicXMLScore)
    }

    func testARoleLessCreatorBecomesTheComposerOnlyWhenNoTypedComposerExists() throws {
        let untypedOnly = Data("""
            <score-partwise>
              <identification><creator>Anonymous</creator></identification>
            </score-partwise>
            """.utf8)
        XCTAssertEqual(try MusicXMLScore.metadata(from: untypedOnly).composer, "Anonymous")

        // The untyped creator comes first; the typed composer still wins.
        let both = Data("""
            <score-partwise>
              <identification>
                <creator>Someone Else</creator>
                <creator type="composer">Clara Schumann</creator>
              </identification>
            </score-partwise>
            """.utf8)
        XCTAssertEqual(try MusicXMLScore.metadata(from: both).composer, "Clara Schumann")
    }

    func testAnArrangerNeverBecomesTheComposer() throws {
        let xml = Data("""
            <score-partwise>
              <identification>
                <creator type="arranger">A. Arranger</creator>
                <creator type="lyricist">L. Lyricist</creator>
              </identification>
            </score-partwise>
            """.utf8)

        XCTAssertNil(try MusicXMLScore.metadata(from: xml).composer)
    }

    func testWhitespaceOnlyFieldsAreTreatedAsAbsent() throws {
        let xml = Data("""
            <score-partwise>
              <work><work-title>   </work-title></work>
              <movement-title>
              </movement-title>
            </score-partwise>
            """.utf8)

        let metadata = try MusicXMLScore.metadata(from: xml)
        XCTAssertNil(metadata.workTitle)
        XCTAssertNil(metadata.movementTitle)
    }

    func testTextIsReassembledAcrossEntityAndCDATABoundaries() throws {
        let xml = Data("""
            <score-partwise>
              <work><work-title>Fanfare &amp; <![CDATA[Finale]]></work-title></work>
            </score-partwise>
            """.utf8)

        XCTAssertEqual(try MusicXMLScore.metadata(from: xml).workTitle, "Fanfare & Finale")
    }

    func testMalformedXMLIsRejectedWithALocation() {
        let xml = Data("<score-partwise><work><work-title>Broken</work></score-partwise>".utf8)

        XCTAssertThrowsError(try MusicXMLScore.metadata(from: xml)) { error in
            guard case MusicXMLParseError.notWellFormed(let reason, let line, _) = error else {
                return XCTFail("Expected notWellFormed, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertGreaterThan(line, 0)
        }
    }

    /// REQ-028 and ordinary XXE safety: a MusicXML DOCTYPE points at
    /// musicxml.org, and a hostile file can point an entity at a local file.
    /// Neither may ever be fetched.
    func testAnExternalEntityIsNeverResolved() throws {
        let secret = URL(filePath: NSTemporaryDirectory())
            .appending(path: "synth-xxe-\(UUID().uuidString).txt")
        try Data("TOP-SECRET".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let xml = Data("""
            <?xml version="1.0"?>
            <!DOCTYPE score-partwise [
              <!ENTITY leak SYSTEM "file://\(secret.path(percentEncoded: false))">
            ]>
            <score-partwise>
              <work><work-title>&leak;</work-title></work>
            </score-partwise>
            """.utf8)

        // Either the parser refuses the document or it yields no leaked text.
        // What must never happen is the file's contents ending up in metadata.
        let workTitle = (try? MusicXMLScore.metadata(from: xml))?.workTitle
        XCTAssertNotEqual(workTitle, "TOP-SECRET")
        XCTAssertFalse(workTitle?.contains("TOP-SECRET") ?? false)
    }

    func testADoctypePointingAtTheWebIsIgnoredRatherThanFetched() throws {
        // The fixture carries the standard MusicXML 4.0 DOCTYPE; parsing it
        // must succeed offline, which it only can if the DTD is never fetched.
        let metadata = try MusicXMLScore.metadata(from: MusicXMLFixtures.score(includeDoctype: true))
        XCTAssertEqual(metadata.workTitle, "Prelude in C")
    }
}

final class MusicXMLContainerDescriptorTests: XCTestCase {
    func testReadsTheRootfileDeclaredWithTheMusicXMLMediaType() throws {
        let descriptor = try MusicXMLContainerDescriptor.parse(
            MusicXMLFixtures.containerDescriptor(rootfilePath: "Nested/Score.xml")
        )

        XCTAssertEqual(descriptor.rootfiles.count, 1)
        XCTAssertEqual(descriptor.scoreEntryName, "Nested/Score.xml")
    }

    func testPrefersTheMusicXMLRootfileOverOtherMediaTypes() throws {
        let xml = Data("""
            <container><rootfiles>
              <rootfile full-path="cover.png" media-type="image/png"/>
              <rootfile full-path="score.xml" media-type="application/vnd.recordare.musicxml+xml"/>
            </rootfiles></container>
            """.utf8)

        XCTAssertEqual(try MusicXMLContainerDescriptor.parse(xml).scoreEntryName, "score.xml")
    }

    func testATypelessSingleRootfileIsAccepted() throws {
        let xml = Data(#"<container><rootfiles><rootfile full-path="score.xml"/></rootfiles></container>"#.utf8)

        XCTAssertEqual(try MusicXMLContainerDescriptor.parse(xml).scoreEntryName, "score.xml")
    }

    func testADescriptorWithOnlyOtherMediaTypesHasNoScore() throws {
        let xml = Data("""
            <container><rootfiles>
              <rootfile full-path="cover.png" media-type="image/png"/>
            </rootfiles></container>
            """.utf8)

        XCTAssertNil(try MusicXMLContainerDescriptor.parse(xml).scoreEntryName)
    }

    func testAnEmptyDescriptorHasNoRootfiles() throws {
        let xml = Data("<container><rootfiles/></container>".utf8)

        XCTAssertTrue(try MusicXMLContainerDescriptor.parse(xml).rootfiles.isEmpty)
    }
}
