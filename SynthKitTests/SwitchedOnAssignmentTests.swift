import XCTest
@testable import SynthKit

/// The Switched-On preset's mapping: part name in, Baroque Modular sound out,
/// and nothing at all when the score names nothing.
final class SwitchedOnAssignmentTests: XCTestCase {
    private func sound(_ partName: String?) -> String? {
        SwitchedOnAssignment.soundID(forPartName: partName)
    }

    func testTheObviousNamesLandOnTheirSounds() {
        XCTAssertEqual(sound("Violin I"), "shipped.brandenburg-violin")
        XCTAssertEqual(sound("Violino II"), "shipped.brandenburg-violin")
        XCTAssertEqual(sound("Viola"), "shipped.modular-cello")
        XCTAssertEqual(sound("Violoncello"), "shipped.modular-cello")
        XCTAssertEqual(sound("Viola da gamba"), "shipped.modular-cello")
        XCTAssertEqual(sound("Contrabass"), "shipped.continuo-bass")
        XCTAssertEqual(sound("Violone"), "shipped.continuo-bass")
        XCTAssertEqual(sound("Trumpet in D"), "shipped.cantata-trumpet")
        XCTAssertEqual(sound("Tromba"), "shipped.cantata-trumpet")
        XCTAssertEqual(sound("Corno I"), "shipped.cantata-trumpet")
        XCTAssertEqual(sound("Oboe"), "shipped.wachet-reed")
        XCTAssertEqual(sound("Fagotto"), "shipped.wachet-reed")
        XCTAssertEqual(sound("Flauto traverso"), "shipped.air-flute")
        XCTAssertEqual(sound("Recorder"), "shipped.air-flute")
        XCTAssertEqual(sound("Harpsichord"), "shipped.modular-harpsichord")
        XCTAssertEqual(sound("Basso continuo"), "shipped.modular-harpsichord")
        XCTAssertEqual(sound("Organ"), "shipped.sinfonia-organ")
        XCTAssertEqual(sound("Soprano"), "shipped.chorale-vox")
        XCTAssertEqual(sound("Lute"), "shipped.pizzicato-pulse")
        XCTAssertEqual(sound("Glockenspiel"), "shipped.clank-box")
    }

    /// The substrings that would go wrong in the wrong order.
    func testOverlappingNamesAreDisambiguatedByOrder() {
        XCTAssertEqual(sound("Bassoon"), "shipped.wachet-reed", "not a bass")
        XCTAssertEqual(sound("Contrabassoon"), "shipped.wachet-reed", "not a contrabass")
        XCTAssertEqual(sound("Bass Clarinet"), "shipped.wachet-reed", "a reed")
        XCTAssertEqual(sound("Alto Flute"), "shipped.air-flute", "a flute, not an alto")
        XCTAssertEqual(sound("English Horn"), "shipped.wachet-reed", "a reed, not a horn")
        XCTAssertEqual(sound("Harpsichord"), "shipped.modular-harpsichord", "not a harp")
        XCTAssertEqual(sound("Harp"), "shipped.pizzicato-pulse")
        XCTAssertEqual(sound("Violoncello"), "shipped.modular-cello", "not a violin")
        XCTAssertEqual(sound("Bass"), "shipped.continuo-bass", "a bare bass is the continuo line")
        XCTAssertEqual(sound("Basso"), "shipped.chorale-vox", "the Italian voice part")
    }

    func testMatchingIgnoresCaseAndSurroundingText() {
        XCTAssertEqual(sound("VIOLIN 1"), "shipped.brandenburg-violin")
        XCTAssertEqual(sound("  Solo Violin (Concertino) "), "shipped.brandenburg-violin")
        XCTAssertEqual(sound("Cello & Bass"), "shipped.modular-cello", "first rule to match wins")
    }

    /// The owner's rule: no instrument name, no action. No guessing from the
    /// line's derived display name either — only the score's own part name.
    func testNoNameOrUnknownNameMeansNoAssignment() {
        XCTAssertNil(sound(nil))
        XCTAssertNil(sound(""))
        XCTAssertNil(sound("   "))
        XCTAssertNil(sound("Part 3"))
        XCTAssertNil(sound("Theremin"))
    }

    func testEveryRuleNamesAShippedSound() {
        for rule in SwitchedOnAssignment.rules {
            XCTAssertNotNil(
                ShippedSoundCollection.standard.sound(withID: rule.soundID),
                "\(rule.soundID) is not shipped; a Switched-On preset would point at nothing"
            )
        }
    }

    // MARK: The plan

    private func line(_ id: String, part: String?) -> LineEntry {
        LineEntry(
            id: ScoreLineID(rawValue: id), defaultName: id, name: id,
            partName: part, staff: 1, voice: "1"
        )
    }

    func testThePlanReassignsMatchedLinesAndLeavesTheRestAlone() throws {
        let inventory = LineInventory(pieceID: "piece", entries: [
            line("v1", part: "Violin I"),
            line("cb", part: "Contrabass"),
            line("odd", part: "Theremin"),
            line("anon", part: nil)
        ])
        let mixer = LineMixerState(volume: 0.5, pan: -0.3, isMuted: false, isSoloed: true,
                                   roomSend: 0.2, depth: 0.4)
        let current = PresetContent(lines: [
            PresetLine(lineID: ScoreLineID(rawValue: "v1"),
                       assignment: .library(kind: .synth, soundID: "shipped.glass-keys"),
                       mixer: mixer),
            PresetLine(lineID: ScoreLineID(rawValue: "cb"),
                       assignment: .library(kind: .synth, soundID: "shipped.glass-keys"),
                       acceptsSubstitution: true),
            PresetLine(lineID: ScoreLineID(rawValue: "odd"),
                       assignment: .library(kind: .synth, soundID: "shipped.fm-bell")),
            PresetLine(lineID: ScoreLineID(rawValue: "anon"),
                       assignment: .library(kind: .synth, soundID: "shipped.music-box"))
        ], humanization: HumanizationSettings(isEnabled: false, intensity: 20))

        let plan = SwitchedOnAssignment.plan(from: current, inventory: inventory)

        XCTAssertEqual(plan.assignedCount, 2)
        XCTAssertEqual(plan.unmatchedCount, 1)
        XCTAssertEqual(plan.unnamedCount, 1)

        let lines = plan.content.lines
        XCTAssertEqual(lines[0].assignment,
                       .library(kind: .synth, soundID: "shipped.brandenburg-violin"))
        XCTAssertEqual(lines[0].mixer, mixer, "The mix carries over untouched")
        XCTAssertEqual(lines[1].assignment,
                       .library(kind: .synth, soundID: "shipped.continuo-bass"))
        XCTAssertTrue(lines[1].acceptsSubstitution, "The substitution answer carries over")
        XCTAssertEqual(lines[2].assignment,
                       .library(kind: .synth, soundID: "shipped.fm-bell"), "Unknown: kept")
        XCTAssertEqual(lines[3].assignment,
                       .library(kind: .synth, soundID: "shipped.music-box"), "Unnamed: kept")
        XCTAssertEqual(plan.content.humanization, current.humanization)

        XCTAssertEqual(
            plan.summary(named: "Switched-On"),
            "Made “Switched-On”: 2 of 4 lines given a Switched-On sound; 1 kept its sound "
                + "(instrument not in the table), 1 kept its sound (no instrument name in the score)."
        )
    }

    func testThePresetNameStepsPastExistingOnes() {
        XCTAssertEqual(SwitchedOnAssignment.presetName(existing: ["Default"]), "Switched-On")
        XCTAssertEqual(SwitchedOnAssignment.presetName(existing: ["switched-on"]), "Switched-On 2")
        XCTAssertEqual(
            SwitchedOnAssignment.presetName(existing: ["Switched-On", "Switched-On 2"]),
            "Switched-On 3"
        )
    }
}
