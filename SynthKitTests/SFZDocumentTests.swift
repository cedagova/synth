import XCTest
@testable import SynthKit

/// Issue #23: "SFZ parser for the required subset; unsupported opcodes are
/// logged/reported per instrument, never fatal."
///
/// These are the parser's own claims, made against text rather than against
/// audio, because that is the lowest layer that can answer them. What the
/// parsed regions then *sound* like is `SampledInstrumentRenderTests`.
///
/// Several of these cases exist because a real file in the curated set does the
/// thing they check — a value with a space in it, a path with backslashes, four
/// `<control>` blocks in one file — and a parser that handled only the tidy
/// cases would load none of the three installed libraries.
final class SFZDocumentTests: XCTestCase {
    // MARK: - The two rules real files break

    /// VSCO 2 writes `default_path=Strings\Cello Section\susvib\`.
    ///
    /// Splitting an opcode on whitespace truncates that to `Strings\Cello`,
    /// and every sample under it then fails to resolve. A value therefore runs
    /// to the start of the next opcode or header, which is what every real SFZ
    /// player does.
    func testAnOpcodeValueMayContainSpaces() {
        let document = SFZDocument.parse(
            """
            <control>
            default_path=Strings\\Cello Section\\susvib\\
            <region> sample=note one.wav lokey=40 hikey=41
            """
        )

        XCTAssertEqual(document.regions.count, 1)
        XCTAssertEqual(
            document.regions.first?.samplePath, "Strings/Cello Section/susvib/note one.wav"
        )
        XCTAssertEqual(document.regions.first?.loKey, 40)
        XCTAssertEqual(document.regions.first?.hiKey, 41)
    }

    /// Salamander writes `sample=44.1khz16bit\A0v1.wav`, and VSCO 2 and
    /// Etherealwinds write their `default_path` the same way. Without this
    /// none of the three libraries loads on macOS at all.
    func testWindowsSeparatorsBecomePathComponents() {
        let document = SFZDocument.parse(
            "<region> sample=44.1khz16bit\\A0v1.wav lokey=21 hikey=22"
        )
        XCTAssertEqual(document.regions.first?.samplePath, "44.1khz16bit/A0v1.wav")
    }

    /// A second `<control>` replaces the first. VSCO 2's `Flute-KS.sfz` has
    /// four, one per articulation, and treating only the first as authoritative
    /// sends three quarters of its samples to the wrong folder.
    func testASecondControlBlockReplacesTheDefaultPath() {
        let document = SFZDocument.parse(
            """
            <control>
            default_path=one\\
            <region> sample=a.wav
            <control>
            default_path=two\\
            <region> sample=b.wav
            """
        )
        XCTAssertEqual(document.regions.map(\.samplePath), ["one/a.wav", "two/b.wav"])
    }

    // MARK: - Inheritance

    func testARegionInheritsGlobalMasterAndGroupInThatOrder() {
        let document = SFZDocument.parse(
            """
            <global> volume=1 ampeg_release=0.5
            <master> volume=2
            <group> volume=3 ampeg_attack=0.25
            <region> sample=a.wav
            <region> sample=b.wav volume=4
            """
        )

        XCTAssertEqual(document.regions.count, 2)
        XCTAssertEqual(document.regions[0].volumeDecibels, 3)
        XCTAssertEqual(document.regions[0].attackSeconds, 0.25)
        XCTAssertEqual(document.regions[0].releaseSeconds, 0.5)
        // The region's own value wins over all three levels above it.
        XCTAssertEqual(document.regions[1].volumeDecibels, 4)
    }

    /// A new `<group>` clears the previous one rather than merging with it.
    func testANewGroupDiscardsThePreviousGroupsOpcodes() {
        let document = SFZDocument.parse(
            """
            <group> volume=6 tune=50
            <region> sample=a.wav
            <group> volume=-6
            <region> sample=b.wav
            """
        )
        XCTAssertEqual(document.regions[1].volumeDecibels, -6)
        XCTAssertEqual(document.regions[1].tuneSemitones, 0)
    }

    // MARK: - Values

    /// `c4` is 60, which is what SFZ and all three installed libraries use.
    func testNoteNamesParseWithMiddleCAtSixty() {
        XCTAssertEqual(SFZValue.key("c4"), 60)
        XCTAssertEqual(SFZValue.key("C4"), 60)
        XCTAssertEqual(SFZValue.key("a4"), 69)
        XCTAssertEqual(SFZValue.key("c2"), 36)
        XCTAssertEqual(SFZValue.key("d#2"), 39)
        XCTAssertEqual(SFZValue.key("db4"), 61, "D flat 4 is C sharp 4.")
        XCTAssertEqual(SFZValue.key("bb4"), 70, "A `b` after a note letter is a flat.")
        XCTAssertEqual(SFZValue.key("c-1"), 0)
        XCTAssertEqual(SFZValue.key("60"), 60)
        XCTAssertEqual(SFZValue.key("-1"), -1)
        XCTAssertNil(SFZValue.key("banana"))
    }

    func testTuneAndTransposeBothLandInSemitones() {
        let document = SFZDocument.parse("<region> sample=a.wav tune=-50 transpose=12")
        XCTAssertEqual(document.regions[0].tuneSemitones, 11.5, accuracy: 1e-9)
    }

    func testPercentageOpcodesBecomeFractions() {
        let document = SFZDocument.parse(
            "<region> sample=a.wav amp_veltrack=50 ampeg_sustain=25 pitch_keytrack=0"
        )
        XCTAssertEqual(document.regions[0].amplitudeVelocityTracking, 0.5)
        XCTAssertEqual(document.regions[0].sustainLevel, 0.25)
        XCTAssertEqual(document.regions[0].pitchKeytrack, 0)
    }

    func testKeySetsBothRangeAndKeycentre() {
        let document = SFZDocument.parse("<region> sample=a.wav key=c4")
        XCTAssertEqual(document.regions[0].loKey, 60)
        XCTAssertEqual(document.regions[0].hiKey, 60)
        XCTAssertEqual(document.regions[0].pitchKeycenter, 60)
    }

    // MARK: - Comments

    func testCommentsAreNotOpcodes() {
        let document = SFZDocument.parse(
            """
            // sample=wrong.wav
            <region> sample=right.wav lokey=1 // hikey=99
            /* <region> sample=alsowrong.wav */
            """
        )
        XCTAssertEqual(document.regions.map(\.samplePath), ["right.wav"])
        XCTAssertEqual(document.regions[0].hiKey, 127)
    }

    // MARK: - Keyswitches

    func testKeyswitchRangeAndDefaultAreInstrumentWide() {
        let document = SFZDocument.parse(
            """
            <group> sw_default=c2 sw_lokey=c2 sw_hikey=d#2 sw_last=c2
            <region> sample=a.wav
            <group> sw_lokey=c2 sw_hikey=d#2 sw_last=c#2
            <region> sample=b.wav
            """
        )
        XCTAssertEqual(document.switchKeyRange, 36...39)
        XCTAssertEqual(document.defaultSwitchKey, 36)
        XCTAssertEqual(document.regions[0].switchKey, 36)
        XCTAssertEqual(document.regions[1].switchKey, 37)
    }

    // MARK: - The honesty report

    /// Issue #23: unsupported opcodes are reported, never fatal.
    func testAnUnsupportedOpcodeIsReportedAndTheRegionStillLoads() {
        let document = SFZDocument.parse(
            """
            <group> ampeg_dynamic=1 cutoff=800
            <region> sample=a.wav lokey=60 hikey=60
            <region> sample=b.wav lokey=61 hikey=61
            """
        )

        XCTAssertEqual(document.regions.count, 2, "An unsupported opcode must not drop regions.")

        let names = document.unsupported.map(\.name)
        XCTAssertTrue(names.contains("ampeg_dynamic"))
        XCTAssertTrue(names.contains("cutoff"))

        let dynamic = document.unsupported.first { $0.name == "ampeg_dynamic" }
        XCTAssertEqual(dynamic?.occurrences, 2, "Reported once per region that inherited it.")
        XCTAssertFalse(
            dynamic?.reason.isEmpty ?? true,
            "An unsupported opcode has to say why, or the report tells the owner nothing."
        )
    }

    /// An opcode nobody has ever heard of is still not fatal.
    func testACompletelyUnknownOpcodeIsReportedRatherThanFatal() {
        let document = SFZDocument.parse("<region> sample=a.wav quantum_flux=7")
        XCTAssertEqual(document.regions.count, 1)
        XCTAssertEqual(document.unsupported.map(\.name), ["quantum_flux"])
    }

    /// The whole `<effect>` block is skipped, not merged into the next region.
    func testAnUnsupportedHeaderSkipsItsContents() {
        let document = SFZDocument.parse(
            """
            <region> sample=a.wav volume=3
            <effect> type=reverb volume=-99
            <region> sample=b.wav
            """
        )
        XCTAssertEqual(document.regions.map(\.samplePath), ["a.wav", "b.wav"])
        XCTAssertEqual(document.regions[1].volumeDecibels, 0)
        XCTAssertTrue(document.unsupported.map(\.name).contains("<effect>"))
    }

    /// A region with no `sample` carries opcodes and plays nothing. Real files
    /// use this; treating it as an error would reject them.
    func testARegionWithoutASampleIsSkippedRatherThanFailing() {
        let document = SFZDocument.parse("<region> lokey=1 hikey=2\n<region> sample=a.wav")
        XCTAssertEqual(document.regions.map(\.samplePath), ["a.wav"])
    }

    /// Every opcode this player recognises but does not apply must explain
    /// itself, because that explanation is what INS003 shows the owner. A
    /// reason that is blank, or that just repeats the opcode's name, is not a
    /// report.
    func testEveryDocumentedUnsupportedOpcodeHasARealReason() {
        for (name, reason) in SFZDocument.unsupportedReasons {
            XCTAssertGreaterThan(
                reason.count, 20, "\(name)'s reason is too short to tell the owner anything."
            )
            XCTAssertTrue(
                reason.hasSuffix("."), "\(name)'s reason should read as a sentence."
            )
        }
    }
}
