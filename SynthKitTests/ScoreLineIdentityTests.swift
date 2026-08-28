import XCTest
@testable import SynthKit

/// `ScoreLineID` is a stored contract: increment 004 saves preset rows against
/// it and increment 006 reproduces a mix from it. These tests pin the
/// derivation itself, separately from any score, because the thing that must
/// never change is the *function*.
final class ScoreLineIdentityTests: XCTestCase {
    func testTheSameTripleAlwaysDerivesTheSameIdentifier() {
        XCTAssertEqual(
            ScoreLineID(partID: "P1", staff: 1, voice: "1"),
            ScoreLineID(partID: "P1", staff: 1, voice: "1")
        )
    }

    /// Frozen expected values. If a change to the derivation makes this test
    /// fail, every preset an owner has saved would silently point at nothing —
    /// so the fix is a migration, not a new expectation.
    func testTheDerivationIsFrozen() {
        XCTAssertEqual(ScoreLineID(partID: "P1", staff: 1, voice: "1").rawValue, "P1-s1-v1-98ae7ea0")
        XCTAssertEqual(ScoreLineID(partID: "P1", staff: 2, voice: "5").rawValue, "P1-s2-v5-ad6b5323")
        XCTAssertEqual(ScoreLineID(partID: "P12", staff: 1, voice: "1").rawValue, "P12-s1-v1-de2156fe")
    }

    func testPartStaffAndVoiceEachChangeTheIdentifier() {
        let base = ScoreLineID(partID: "P1", staff: 1, voice: "1")
        XCTAssertNotEqual(base, ScoreLineID(partID: "P2", staff: 1, voice: "1"))
        XCTAssertNotEqual(base, ScoreLineID(partID: "P1", staff: 2, voice: "1"))
        XCTAssertNotEqual(base, ScoreLineID(partID: "P1", staff: 1, voice: "2"))
    }

    /// The readable prefix folds anything unusual to `_`, so two different
    /// part identifiers can share a prefix. The digest is what keeps them
    /// apart, and a collision here would silently merge two lines' presets.
    func testPartIdentifiersThatFoldTogetherStillGetDifferentIdentifiers() {
        let spaced = ScoreLineID(partID: "P 1", staff: 1, voice: "1")
        let underscored = ScoreLineID(partID: "P_1", staff: 1, voice: "1")
        XCTAssertTrue(spaced.rawValue.hasPrefix("P_1-s1-v1-"))
        XCTAssertTrue(underscored.rawValue.hasPrefix("P_1-s1-v1-"))
        XCTAssertNotEqual(spaced, underscored)
    }

    func testAPartIdentifierWithNoUsableCharactersStillProducesAReadableName() {
        let id = ScoreLineID(partID: "—", staff: 1, voice: "1")
        XCTAssertTrue(id.rawValue.hasPrefix("x-s1-v1-"), "got \(id.rawValue)")
    }

    func testAVeryLongPartIdentifierIsTrimmedButStaysUnique() {
        let long = String(repeating: "A", count: 200)
        let longer = long + "B"
        let first = ScoreLineID(partID: long, staff: 1, voice: "1")
        let second = ScoreLineID(partID: longer, staff: 1, voice: "1")
        XCTAssertLessThan(first.rawValue.count, 48)
        XCTAssertNotEqual(first, second)
    }

    func testIdentifiersSurviveARoundTripThroughStorage() throws {
        let original = ScoreLineID(partID: "P3", staff: 2, voice: "7")
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(original.rawValue)\"")
        XCTAssertEqual(try JSONDecoder().decode(ScoreLineID.self, from: encoded), original)
    }

    func testIdentifiersHaveATotalOrderSoLineListsAreStable() {
        let ids = [
            ScoreLineID(partID: "P2", staff: 1, voice: "1"),
            ScoreLineID(partID: "P1", staff: 1, voice: "1"),
            ScoreLineID(partID: "P1", staff: 2, voice: "1")
        ]
        XCTAssertEqual(ids.sorted(), ids.sorted().sorted())
        XCTAssertEqual(Set(ids).count, 3)
    }

    // MARK: Uniqueness within a compiled score

    /// A preset key that two different lines share would make one line's sound
    /// follow the other. Two parts declaring the same `id` is a malformed
    /// file, but the compiler must still hand back distinct identities.
    func testTwoPartsSharingAnIdentifierStillProduceDistinctLines() throws {
        func part(id: String, name: String, pitch: String) -> String {
            #"<score-part id="\#(id)"><part-name>\#(name)</part-name></score-part>"#
        }
        let xml = #"<?xml version="1.0"?><score-partwise version="4.0"><part-list>"#
            + part(id: "P1", name: "Flute", pitch: "C5")
            + part(id: "P1", name: "Oboe", pitch: "E4")
            + "</part-list>"
            + #"<part id="P1"><measure number="1">"#
            + "<attributes><divisions>4</divisions><time><beats>4</beats>"
            + "<beat-type>4</beat-type></time></attributes>"
            + "<note><pitch><step>C</step><octave>5</octave></pitch><duration>16</duration>"
            + "<voice>1</voice></note></measure></part>"
            + #"<part id="P1"><measure number="1">"#
            + "<note><pitch><step>E</step><octave>4</octave></pitch><duration>16</duration>"
            + "<voice>1</voice></note></measure></part>"
            + "</score-partwise>"

        let score = try ScoreCompiler().compile(pieceID: "clash", musicXML: Data(xml.utf8))

        XCTAssertEqual(score.lines.count, 2)
        XCTAssertEqual(Set(score.lines.map(\.id)).count, 2, "the two lines must not share a key")
        XCTAssertTrue(score.report.mentions(kind: "duplicate part identifier"))
    }

    /// A voice that crosses staves becomes one line per staff. That is a
    /// decision, so it has to appear in the report rather than just happen.
    func testAVoiceCrossingStavesIsSplitAndSaidSo() throws {
        let xml = #"<?xml version="1.0"?><score-partwise version="4.0">"#
            + #"<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>"#
            + #"<part id="P1"><measure number="1">"#
            + "<attributes><divisions>4</divisions><staves>2</staves>"
            + "<time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
            + "<note><pitch><step>C</step><octave>5</octave></pitch><duration>8</duration>"
            + "<voice>1</voice><staff>1</staff></note>"
            + "<note><pitch><step>C</step><octave>3</octave></pitch><duration>8</duration>"
            + "<voice>1</voice><staff>2</staff></note>"
            + "</measure></part></score-partwise>"

        let score = try ScoreCompiler().compile(pieceID: "crossing", musicXML: Data(xml.utf8))

        XCTAssertEqual(score.lines.map(\.staff), [1, 2])
        XCTAssertEqual(Set(score.lines.map(\.voice)), ["1"])
        let entry = try XCTUnwrap(
            score.report.entries.first { $0.kind == "voice split across staves" }
        )
        XCTAssertEqual(entry.category, .structuralFallback)
        XCTAssertEqual(entry.occurrenceCount, 2, "one per resulting line")
    }

    func testAnOrdinaryTwoStaffPianoPartIsNotReportedAsCrossingStaves() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "fugue",
            musicXML: MusicXMLScoreFixtures.keyboardFugueExposition()
        )
        XCTAssertFalse(score.report.mentions(kind: "voice split across staves"))
    }

    // MARK: Default names

    func testASingleLinePartIsNamedAfterTheInstrumentAlone() {
        XCTAssertEqual(
            ScoreCompiler.defaultLineName(
                base: "Violin I", staff: 1, voice: "1", staffCount: 1, lineCount: 1
            ),
            "Violin I"
        )
    }

    func testAMultivoicePartNamesTheVoiceAndOnlyMentionsStavesWhenThereAreSome() {
        XCTAssertEqual(
            ScoreCompiler.defaultLineName(
                base: "Piano", staff: 1, voice: "2", staffCount: 1, lineCount: 2
            ),
            "Piano, voice 2"
        )
        XCTAssertEqual(
            ScoreCompiler.defaultLineName(
                base: "Piano", staff: 2, voice: "5", staffCount: 2, lineCount: 4
            ),
            "Piano, staff 2, voice 5"
        )
    }

    // MARK: Pitch

    func testMiddleCIsMIDISixty() {
        XCTAssertEqual(ScorePitch(step: "C", alter: 0, octave: 4).midiNoteNumber, 60)
        XCTAssertEqual(ScorePitch(step: "A", alter: 0, octave: 4).midiNoteNumber, 69)
        XCTAssertEqual(ScorePitch(step: "B", alter: -1, octave: 3).midiNoteNumber, 58)
    }

    func testAnUnreadableStepHasNoMIDINumberRatherThanAWrongOne() {
        XCTAssertNil(ScorePitch(step: "H", alter: 0, octave: 4).midiNoteNumber)
    }
}
