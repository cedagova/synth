import XCTest
@testable import SynthKit

/// The whole-piece tempo lives on the preset, additively.
final class PresetTempoTests: XCTestCase {
    private func content(tempo: Int) -> PresetContent {
        PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )],
            tempoPercent: tempo
        )
    }

    func testTheTempoIsClampedToTheControlsRange() {
        XCTAssertEqual(content(tempo: 10).tempoPercent, 50)
        XCTAssertEqual(content(tempo: 900).tempoPercent, 150)
        var mutated = content(tempo: 100)
        mutated.tempoPercent = 0
        XCTAssertEqual(mutated.tempoPercent, 50, "Clamped on write, not only on init")
    }

    func testTheTempoRoundTripsThroughTheDocument() throws {
        let data = try PresetDocument.data(from: content(tempo: 85))
        XCTAssertEqual(try PresetDocument.content(from: data).tempoPercent, 85)
    }

    /// A preset written before the field existed plays at the file's tempo.
    func testADocumentWithoutATempoReadsAsTheScoresOwn() throws {
        var document = try JSONSerialization.jsonObject(
            with: try PresetDocument.data(from: content(tempo: 70))
        ) as! [String: Any]
        var inner = document["preset"] as! [String: Any]
        XCTAssertNotNil(inner.removeValue(forKey: "tempoPercent"), "The field is stored under that key")
        document["preset"] = inner
        let old = try JSONSerialization.data(withJSONObject: document)

        XCTAssertEqual(try PresetDocument.content(from: old).tempoPercent, 100)
    }
}
