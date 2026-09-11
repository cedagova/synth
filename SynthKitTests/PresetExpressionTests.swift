import XCTest
@testable import SynthKit

/// Phrase expression lives on the preset, additively — the `humanization` and
/// `tempoPercent` precedent (AD-P3), with owner decision D65-3 as the decode
/// default.
final class PresetExpressionTests: XCTestCase {
    private func content(_ expression: ExpressionSettings) -> PresetContent {
        PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )],
            expression: expression
        )
    }

    func testAFreshPresetHasExpressionOnAtTheDefaultAmount() {
        let fresh = PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )]
        )
        XCTAssertEqual(fresh.expression, .standard)
        XCTAssertTrue(fresh.expression.isEnabled)
    }

    func testTheSettingRoundTripsThroughTheDocument() throws {
        let stored = ExpressionSettings(isEnabled: false, amount: 35)
        let data = try PresetDocument.data(from: content(stored))
        XCTAssertEqual(try PresetDocument.content(from: data).expression, stored)
    }

    /// **Owner decision D65-3, as a test.** A preset written before this field
    /// existed opens with expression on at the default amount, so every piece
    /// already in the library gains the feature on its next open — with no
    /// migration pass and without touching anything else the preset stores.
    func testAPresetWrittenBeforeTheFieldExistedOpensWithExpressionOn() throws {
        var document = try JSONSerialization.jsonObject(
            with: try PresetDocument.data(from: content(ExpressionSettings(isEnabled: false, amount: 10)))
        ) as! [String: Any]
        var inner = document["preset"] as! [String: Any]
        XCTAssertNotNil(
            inner.removeValue(forKey: "expression"), "the field is stored under that key"
        )
        document["preset"] = inner
        let old = try JSONSerialization.data(withJSONObject: document)

        let decoded = try PresetDocument.content(from: old)
        XCTAssertEqual(decoded.expression, .standard, "D65-3: on, at the default amount")
        XCTAssertEqual(decoded.humanization, .standard, "and nothing else moved")
        XCTAssertEqual(decoded.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertEqual(decoded.lines.count, 1)
    }

    /// Writing the setting is one store call that leaves the rest of the preset
    /// alone, and it is auto-saved — proved by reopening the database rather
    /// than by reading back the value in memory, the
    /// `PresetLibraryTests` house rule.
    func testTheStoreSavesTheSettingAndItSurvivesARelaunch() throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(ProcessInfo.processInfo.globallyUniqueString)")
        let sources = root.appending(path: "sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        var store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")

        let url = sources.appending(path: "fugue.musicxml")
        try MusicXMLScoreFixtures.keyboardFugueExposition().write(to: url)
        let piece = try store.makeImporter().importPiece(from: url).piece
        let preset = try store.presets.create(
            named: "Default", forPieceID: piece.id, content: content(.standard)
        )

        let wanted = ExpressionSettings(isEnabled: false, amount: 80)
        let updated = try store.presets.setExpression(wanted, in: preset)
        XCTAssertEqual(updated.content.expression, wanted)
        XCTAssertEqual(updated.content.lines, preset.content.lines, "the assignment is untouched")
        XCTAssertEqual(updated.content.humanization, preset.content.humanization)
        XCTAssertGreaterThan(updated.revision, preset.revision, "the write was recorded")

        store.close()
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }
        XCTAssertEqual(
            try store.presets.activePreset(forPieceID: piece.id)?.content.expression, wanted,
            "the setting did not survive a relaunch"
        )
    }
}
