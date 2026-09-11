import XCTest
@testable import SynthKit

/// The tuning lives on the preset, additively — the `expression`,
/// `producedMaster` and `humanization` precedent (AD-P3) — with one deliberate
/// difference: its decode default is the identity rather than an opinion.
///
/// D65-3 turned expression and the produced master **on** for presets written
/// before those fields existed, because both make every piece in the library
/// better on its next open. A temperament is not that kind of setting: REQ-006
/// requires the default to be indistinguishable from what the app did before, and
/// inferring a temperament the owner never chose would change the pitch of every
/// piece they already have.
final class PresetTuningTests: XCTestCase {
    private func content(_ tuning: TuningSettings) -> PresetContent {
        PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )],
            tuning: tuning
        )
    }

    func testAFreshPresetIsAtEqualTemperamentAndConcertPitch() {
        let fresh = PresetContent(
            lines: [PresetLine(
                lineID: ScoreLineID(rawValue: "l1"),
                assignment: .library(kind: .synth, soundID: "shipped.glass-keys")
            )]
        )
        XCTAssertEqual(fresh.tuning, .standard)
        XCTAssertTrue(
            fresh.tuning.isDefault,
            "REQ-006: a fresh preset must sound exactly as it did before this field existed"
        )
    }

    func testTheSettingRoundTripsThroughTheDocument() throws {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                let data = try PresetDocument.data(from: content(tuning))
                XCTAssertEqual(try PresetDocument.content(from: data).tuning, tuning)
            }
        }
    }

    /// **REQ-006's default clause, as a test.** A preset written before this field
    /// existed opens at equal temperament and A=440 — the identity — and nothing
    /// else about it moves.
    func testAPresetWrittenBeforeTheFieldExistedOpensAtTheDefaultTuning() throws {
        let stored = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        var document = try JSONSerialization.jsonObject(
            with: try PresetDocument.data(from: content(stored))
        ) as! [String: Any]
        var inner = document["preset"] as! [String: Any]
        XCTAssertNotNil(
            inner.removeValue(forKey: "tuning"), "the field is stored under that key"
        )
        document["preset"] = inner
        let old = try JSONSerialization.data(withJSONObject: document)

        let decoded = try PresetDocument.content(from: old)
        XCTAssertEqual(decoded.tuning, .standard)
        XCTAssertTrue(decoded.tuning.isDefault)
        XCTAssertEqual(decoded.producedMaster, .standard, "and nothing else moved")
        XCTAssertEqual(decoded.expression, .standard)
        XCTAssertEqual(decoded.humanization, .standard)
        XCTAssertEqual(decoded.tempoPercent, TempoMap.defaultTempoPercent)
        XCTAssertEqual(decoded.lines.count, 1)
    }

    /// REQ-006's failure clause through the real document reader: a stored
    /// temperament this build does not know opens the preset — at equal temperament,
    /// with a sentence — rather than failing it.
    ///
    /// Through `PresetDocument` rather than through `TuningSettings` alone, because
    /// the thing that must not happen is the *document* refusing to open: a preset
    /// that cannot be read is a piece the owner cannot play, which is a far worse
    /// answer to a field they never typed than equal temperament is.
    func testAnUnknownStoredTemperamentStillOpensThePreset() throws {
        var document = try JSONSerialization.jsonObject(
            with: try PresetDocument.data(
                from: content(TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415))
            )
        ) as! [String: Any]
        var inner = document["preset"] as! [String: Any]
        var tuning = inner["tuning"] as! [String: Any]
        tuning["temperament"] = "kirnberger-iii-from-a-later-version"
        inner["tuning"] = tuning
        document["preset"] = inner
        let newer = try JSONSerialization.data(withJSONObject: document)

        let decoded = try PresetDocument.content(from: newer)
        XCTAssertEqual(decoded.tuning.temperament, .equal, "it plays in equal temperament")
        XCTAssertEqual(
            decoded.tuning.referencePitch, .a415,
            "the reference pitch was readable and must not be discarded with it"
        )
        XCTAssertNotNil(decoded.tuning.failureSentence, "and the owner is told")
        XCTAssertEqual(decoded.lines.count, 1, "the rest of the preset read normally")

        // And writing it back does not destroy the choice, which matters because the
        // preset auto-saves on every performance change.
        let rewritten = try PresetDocument.content(
            from: try PresetDocument.data(from: decoded)
        )
        XCTAssertEqual(
            rewritten.tuning.unrecognizedTemperament, "kirnberger-iii-from-a-later-version"
        )
    }

    /// Writing the setting is one store call that leaves the rest of the preset
    /// alone, and it is auto-saved — proved by reopening the database rather than by
    /// reading back the value in memory, the `PresetLibraryTests` house rule.
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

        let chosen = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        let updated = try store.presets.setTuning(chosen, in: preset)
        XCTAssertEqual(updated.content.tuning, chosen)
        XCTAssertEqual(updated.content.lines, preset.content.lines, "the assignment is untouched")
        XCTAssertEqual(updated.content.producedMaster, preset.content.producedMaster)
        XCTAssertEqual(updated.content.expression, preset.content.expression)
        XCTAssertGreaterThan(updated.revision, preset.revision, "the write was recorded")

        store.close()
        store = try LibraryStore.open(container: container, appVersion: "1.0 (1)")
        defer { store.close() }
        XCTAssertEqual(
            try store.presets.activePreset(forPieceID: piece.id)?.content.tuning, chosen,
            "the setting did not survive a relaunch"
        )
    }

    /// The per-instrument tuning offset and the preset's tuning are stored in
    /// different places and neither replaces the other (P65-4): changing one leaves
    /// the other's stored shape untouched.
    ///
    /// The storage half of the composition rule. The audible half is measured in
    /// `TuningRenderTests.testThePerInstrumentOffsetComposesWithTheProgramsTuning`.
    func testTheProgramsTuningAndTheInstrumentOffsetAreStoredSeparately() throws {
        let variant = InstrumentVariant(
            reference: InstrumentReference(
                libraryID: "lib", instrumentID: "cello",
                libraryName: "Library", instrumentName: "Cello"
            ),
            customization: InstrumentCustomization(tuningOffsetCents: -27)
        )
        // The offset lives on the sound, not on the preset: the preset names the
        // sound and stores the whole-piece tuning beside it.
        XCTAssertEqual(variant.customization.tuningOffsetCents, -27)

        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        let read = try PresetDocument.content(
            from: try PresetDocument.data(from: content(tuning))
        )
        XCTAssertEqual(read.tuning, tuning)
        XCTAssertEqual(
            variant.customization.tuningOffsetCents, -27,
            "storing a whole-piece tuning must not change what an instrument's offset means"
        )
    }
}
