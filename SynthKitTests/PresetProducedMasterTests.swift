import XCTest
@testable import SynthKit

/// The produced master lives on the preset, additively — the `expression` and
/// `humanization` precedent (AD-P3), with owner decision D65-3 as the decode
/// default.
final class PresetProducedMasterTests: XCTestCase {
    private func content(_ producedMaster: ProducedMasterSettings) -> PresetContent {
        PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )],
            producedMaster: producedMaster
        )
    }

    func testAFreshPresetHasTheProducedMasterOn() {
        let fresh = PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )]
        )
        XCTAssertEqual(fresh.producedMaster, .standard)
        XCTAssertTrue(fresh.producedMaster.isEnabled, "D65-3: on for a fresh preset")
    }

    func testTheSettingRoundTripsThroughTheDocument() throws {
        let data = try PresetDocument.data(from: content(.off))
        XCTAssertEqual(try PresetDocument.content(from: data).producedMaster, .off)
    }

    /// **Owner decision D65-3, as a test.** A preset written before this field
    /// existed opens with the produced master on, so every piece already in the
    /// library is levelled on its next open — with no migration pass and without
    /// touching anything else the preset stores.
    func testAPresetWrittenBeforeTheFieldExistedOpensWithTheProducedMasterOn() throws {
        var document = try JSONSerialization.jsonObject(
            with: try PresetDocument.data(from: content(.off))
        ) as! [String: Any]
        var inner = document["preset"] as! [String: Any]
        XCTAssertNotNil(
            inner.removeValue(forKey: "producedMaster"), "the field is stored under that key"
        )
        document["preset"] = inner
        let old = try JSONSerialization.data(withJSONObject: document)

        let decoded = try PresetDocument.content(from: old)
        XCTAssertEqual(decoded.producedMaster, .standard, "D65-3: on")
        XCTAssertEqual(decoded.expression, .standard, "and nothing else moved")
        XCTAssertEqual(decoded.humanization, .standard)
        XCTAssertEqual(decoded.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertEqual(decoded.lines.count, 1)
    }

    /// Writing the setting is one store call that leaves the rest of the preset
    /// alone, and it is auto-saved — proved by reopening the database rather than
    /// by reading back the value in memory, the `PresetLibraryTests` house rule.
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

        let updated = try store.presets.setProducedMaster(.off, in: preset)
        XCTAssertEqual(updated.content.producedMaster, .off)
        XCTAssertEqual(updated.content.lines, preset.content.lines, "the assignment is untouched")
        XCTAssertEqual(updated.content.expression, preset.content.expression)
        XCTAssertGreaterThan(updated.revision, preset.revision, "the write was recorded")

        store.close()
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }
        XCTAssertEqual(
            try store.presets.activePreset(forPieceID: piece.id)?.content.producedMaster, .off,
            "the setting did not survive a relaunch"
        )
    }
}
