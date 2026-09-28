import XCTest
@testable import Synth
import SynthKit

/// `AssignmentModel` directly: the mixer, preset create/rename/switch/delete,
/// sound assignment, line names, and the auto-save that stands behind all of
/// them — plus what the owner sees when the store refuses a write (issue #99).
///
/// The model is built exactly as `PlaybackModel` builds it — over a store and
/// an engine with the piece's program loaded — but without `PlaybackModel`
/// in between, so these tests pin this model's own behaviour and do not ride on
/// the transport's preset-read path (#95, #96). The engine is loaded, never
/// started: nothing here needs an output device.
@MainActor
final class AssignmentModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var engine: PlaybackEngine!
    private var model: AssignmentModel!
    private var score: CompiledScore!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        let piece = try library.importPiece(
            musicXML: ModelFixtures.score(title: "Duet", parts: ["Flute", "Cello"])
        )
        score = try ScoreCompiler().compile(piece: piece, contentStore: library.store.pieceContent)
        engine = PlaybackEngine()
        try engine.load(timeline: PerformanceRealizer().realize(score, settings: .standard))
        model = AssignmentModel(store: library.store, engine: engine)
    }

    override func tearDown() async throws {
        model = nil
        engine?.stopEngine()
        engine = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private var presets: PresetLibrary { library.store.presets }

    /// Opens the piece and returns the first line's identity.
    @discardableResult
    private func open() throws -> ScoreLineID {
        model.open(score: score)
        XCTAssertNil(model.alert, "Opening should not fail: \(String(describing: model.alert))")
        XCTAssertTrue(model.isReady)
        return try XCTUnwrap(model.lines.first).lineID
    }

    private func storedActive() throws -> Preset {
        try XCTUnwrap(presets.activePreset(forPieceID: score.pieceID))
    }

    private func storedMixer(_ lineID: ScoreLineID) throws -> LineMixerState {
        try XCTUnwrap(storedActive().line(withID: lineID)).mixer
    }

    // MARK: Opening

    func testOpeningCreatesTheFirstPresetAndSelectsTheFirstLine() throws {
        let first = try open()

        XCTAssertEqual(model.lineCount, 2, "One line per part")
        XCTAssertEqual(model.presets.count, 1)
        XCTAssertEqual(model.activePreset?.name, PresetLibrary.initialPresetName)
        XCTAssertEqual(model.selectedLineID, first)
        XCTAssertTrue(
            model.statusMessage?.hasPrefix("\(PresetLibrary.initialPresetName) opened") == true,
            String(describing: model.statusMessage)
        )
        XCTAssertEqual(try storedActive().id, model.activePreset?.id, "The first preset is stored")
        XCTAssertFalse(model.palette.isEmpty, "The pickers have the shipped sounds to offer")
    }

    /// The failure path at open: the first preset cannot be written, so the
    /// owner is told rather than shown an empty mixer with no explanation.
    func testAPresetTheStoreCannotCreateRaisesAnAlert() throws {
        try library.failWrites(.insert, on: PresetCatalog.tableName)
        model.open(score: score)

        XCTAssertEqual(model.alert?.title, "Could not read this piece's presets")
        XCTAssertFalse(model.isReady)
        XCTAssertNil(try presets.activePreset(forPieceID: score.pieceID))
    }

    // MARK: The mixer (REQ-008) and auto-save

    func testSettingAVolumeIsHeardAndSaved() throws {
        let line = try open()
        let revision = try XCTUnwrap(model.activePreset?.revision)

        model.setVolume(0.5, forLine: line)

        XCTAssertEqual(model.lines.first { $0.lineID == line }?.mixer.volume, 0.5)
        XCTAssertEqual(try storedMixer(line).volume, 0.5, "Saved with no save step")
        XCTAssertEqual(try XCTUnwrap(engine.mixer(for: line)).gain, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(model.activePreset?.revision), revision)
        XCTAssertNil(model.alert)
    }

    func testAPreviewIsHeardButNotSavedUntilCommitted() throws {
        let line = try open()
        let stored = try storedMixer(line).volume

        model.previewVolume(0.25, forLine: line)
        XCTAssertEqual(try XCTUnwrap(engine.mixer(for: line)).gain, 0.25, accuracy: 0.0001)
        XCTAssertEqual(try storedMixer(line).volume, stored, "A drag in flight writes nothing")

        model.commitMixer(forLine: line)
        XCTAssertEqual(try storedMixer(line).volume, 0.25)
    }

    func testVolumeAndPanAreClamped() throws {
        let line = try open()
        model.setVolume(100, forLine: line)
        model.setPan(-5, forLine: line)

        XCTAssertEqual(try storedMixer(line).volume, LineMixerState.maximumVolume)
        XCTAssertEqual(try storedMixer(line).pan, -1)
    }

    func testMuteSoloRoomSendAndDepthAreSaved() throws {
        let line = try open()
        model.setMuted(true, forLine: line)
        model.setSoloed(true, forLine: line)
        model.setRoomSend(0.7, forLine: line)
        model.setDepth(0.3, forLine: line)

        let stored = try storedMixer(line)
        XCTAssertTrue(stored.isMuted)
        XCTAssertTrue(stored.isSoloed)
        XCTAssertEqual(stored.roomSend, 0.7, accuracy: 0.0001)
        XCTAssertEqual(stored.depth, 0.3, accuracy: 0.0001)
        let strip = try XCTUnwrap(engine.mixer(for: line))
        XCTAssertTrue(strip.isMuted)
        XCTAssertTrue(strip.isSoloed)
    }

    func testTheSelectedLineCommandsActOnTheSelection() throws {
        try open()
        model.selectNextLine()
        let second = try XCTUnwrap(model.selectedLineID)
        XCTAssertEqual(second, model.lines[1].lineID)
        // The auto-mapping spreads lines across the stereo field, so the
        // starting pan is whatever it chose, not necessarily the centre.
        let startingPan = try storedMixer(second).pan

        model.toggleMuteOnSelectedLine()
        model.toggleSoloOnSelectedLine()
        model.nudgePanOnSelectedLine(by: -0.25)
        XCTAssertTrue(try storedMixer(second).isMuted)
        XCTAssertTrue(try storedMixer(second).isSoloed)
        XCTAssertEqual(
            try storedMixer(second).pan, min(max(startingPan - 0.25, -1), 1), accuracy: 0.0001
        )

        model.centrePanOnSelectedLine()
        XCTAssertEqual(try storedMixer(second).pan, 0)
        XCTAssertFalse(
            try storedMixer(model.lines[0].lineID).isMuted, "The other line is untouched"
        )
    }

    /// The failure path the class documents: a mixer write the store refuses
    /// puts the strip *and* the row back to what is stored, and says so.
    func testAMixerWriteTheStoreRefusesIsRolledBackOnScreenAndInTheEngine() throws {
        let line = try open()
        let stored = try storedMixer(line)
        try library.failWrites(.update, on: PresetCatalog.tableName)

        model.setVolume(0.1, forLine: line)

        XCTAssertEqual(model.alert?.title, "Could not save the volume change")
        XCTAssertEqual(model.lines.first { $0.lineID == line }?.mixer, stored)
        XCTAssertEqual(
            try XCTUnwrap(engine.mixer(for: line)).gain, Float(stored.volume), accuracy: 0.0001,
            "The engine must not keep playing a value the library does not hold"
        )
        XCTAssertEqual(try storedMixer(line), stored)
    }

    // MARK: Whole-piece settings

    func testWholePieceSettingsAreSavedToTheActivePreset() throws {
        try open()
        model.saveTempoPercent(80)
        model.saveHumanization(HumanizationSettings(isEnabled: false, intensity: 20))
        model.saveExpression(ExpressionSettings(isEnabled: false, amount: 10))
        model.saveProducedMaster(ProducedMasterSettings(isEnabled: false))
        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        model.saveTuning(tuning)

        let content = try storedActive().content
        XCTAssertEqual(content.tempoPercent, 80)
        XCTAssertEqual(content.humanization, HumanizationSettings(isEnabled: false, intensity: 20))
        XCTAssertEqual(content.expression, ExpressionSettings(isEnabled: false, amount: 10))
        XCTAssertEqual(content.producedMaster, ProducedMasterSettings(isEnabled: false))
        XCTAssertEqual(content.tuning, tuning)
        XCTAssertNil(model.alert)
    }

    func testATempoTheStoreRefusesRaisesAnAlert() throws {
        try open()
        let before = try storedActive().content.tempoPercent
        try library.failWrites(.update, on: PresetCatalog.tableName)

        model.saveTempoPercent(before == 80 ? 90 : 80)

        XCTAssertEqual(model.alert?.title, "Could not save the tempo change")
        XCTAssertEqual(try storedActive().content.tempoPercent, before)
    }

    // MARK: Presets (REQ-024)

    func testANewPresetIsACopyThatBecomesActiveAndAsksForAName() throws {
        let line = try open()
        model.setVolume(0.4, forLine: line)
        let original = try XCTUnwrap(model.activePreset)

        model.createPreset()

        XCTAssertEqual(model.presets.count, 2)
        let created = try XCTUnwrap(model.activePreset)
        XCTAssertNotEqual(created.id, original.id)
        XCTAssertEqual(try storedActive().id, created.id, "The copy is the active one in the store")
        XCTAssertEqual(created.line(withID: line)?.mixer.volume, 0.4, "…and carries the mix")
        XCTAssertTrue(model.isRenamingPreset, "A new preset goes straight to naming")
        XCTAssertEqual(model.presetNameDraft, created.name)
    }

    func testRenamingThePresetStoresTheName() throws {
        try open()
        model.beginPresetRename()
        model.presetNameDraft = "Bright"
        model.commitPresetRename()

        XCTAssertFalse(model.isRenamingPreset)
        XCTAssertEqual(model.activePreset?.name, "Bright")
        XCTAssertEqual(try storedActive().name, "Bright")
        XCTAssertEqual(model.presets.map(\.name), ["Bright"])
    }

    /// The failure path through the shared `write` helper: the library refuses
    /// an empty name, the alert names what was attempted, and nothing changes.
    func testAnEmptyPresetNameIsRefusedWithAnAlert() throws {
        try open()
        model.beginPresetRename()
        model.presetNameDraft = "   "
        model.commitPresetRename()

        XCTAssertEqual(
            model.alert?.title, "Could not rename “\(PresetLibrary.initialPresetName)”"
        )
        XCTAssertEqual(try storedActive().name, PresetLibrary.initialPresetName)
    }

    func testCancellingAPresetRenameWritesNothing() throws {
        try open()
        model.beginPresetRename()
        model.presetNameDraft = "Unwanted"
        model.cancelPresetRename()

        XCTAssertFalse(model.isRenamingPreset)
        XCTAssertEqual(try storedActive().name, PresetLibrary.initialPresetName)
    }

    func testSwitchingPresetsActivatesAndAnnounces() throws {
        try open()
        let first = try XCTUnwrap(model.activePreset)
        model.createPreset()
        model.cancelPresetRename()

        model.activate(presetID: first.id)

        XCTAssertEqual(model.activePreset?.id, first.id)
        XCTAssertEqual(try storedActive().id, first.id)
        XCTAssertTrue(model.statusMessage?.hasPrefix("Switched to “\(first.name)”") == true)

        model.activateNextPreset()
        XCTAssertNotEqual(model.activePreset?.id, first.id, "Next wraps to the other preset")
    }

    func testDeletingOneOfTwoPresetsLandsOnTheOther() throws {
        try open()
        let first = try XCTUnwrap(model.activePreset)
        model.createPreset()
        model.cancelPresetRename()
        let second = try XCTUnwrap(model.activePreset)

        model.requestPresetDeletion()
        XCTAssertEqual(model.pendingPresetDeletion?.id, second.id, "Delete asks first")
        model.confirmPresetDeletion(of: second)

        XCTAssertNil(model.pendingPresetDeletion)
        XCTAssertEqual(model.presets.map(\.id), [first.id])
        XCTAssertEqual(model.activePreset?.id, first.id)
        XCTAssertNil(try presets.preset(withID: second.id))
    }

    func testDeletingTheOnlyPresetReplacesItWithAFreshOne() throws {
        try open()
        let only = try XCTUnwrap(model.activePreset)
        model.confirmPresetDeletion(of: only)

        XCTAssertNil(model.alert)
        XCTAssertEqual(model.presets.count, 1, "A piece always has a preset")
        XCTAssertNotEqual(model.activePreset?.id, only.id)
        XCTAssertEqual(model.activePreset?.name, PresetLibrary.initialPresetName)
        XCTAssertNil(try presets.preset(withID: only.id))
    }

    func testADeleteTheStoreRefusesRaisesAnAlertAndKeepsBothPresets() throws {
        try open()
        model.createPreset()
        model.cancelPresetRename()
        let second = try XCTUnwrap(model.activePreset)
        try library.failWrites(.delete, on: PresetCatalog.tableName)

        model.confirmPresetDeletion(of: second)

        XCTAssertEqual(model.alert?.title, "Could not delete “\(second.name)”")
        XCTAssertEqual(model.presets.count, 2, "The panel re-reads what is really stored")
        XCTAssertNotNil(try presets.preset(withID: second.id))
    }

    // MARK: Assigning a sound (REQ-006)

    func testAssigningASoundIsSavedAndShown() throws {
        let line = try open()
        let current = try XCTUnwrap(model.lines.first { $0.lineID == line })
        let other = try XCTUnwrap(
            model.palette.first { $0.kind == .synth && !current.source.isLibrarySound($0.id) }
        )

        model.assign(soundID: other.id, toLine: line)

        XCTAssertNil(model.alert)
        XCTAssertTrue(
            try XCTUnwrap(model.lines.first { $0.lineID == line }).source.isLibrarySound(other.id)
        )
        XCTAssertEqual(model.statusMessage, "“\(current.name)” now plays “\(other.name)”.")
        let stored = try library.store.openActivePreset(for: score)
        XCTAssertTrue(
            try XCTUnwrap(stored.lines.first { $0.lineID == line }).source.isLibrarySound(other.id),
            "The assignment is saved with no save step"
        )
    }

    func testCyclingTheSelectedLinesSoundStepsThroughThePalette() throws {
        let line = try open()
        let ordered = model.orderedPalette
        let before = try XCTUnwrap(model.selectedLine)
        let index = try XCTUnwrap(ordered.firstIndex { before.source.isLibrarySound($0.id) })

        model.cycleSoundOnSelectedLine(by: 1)

        let expected = ordered[(index + 1) % ordered.count]
        XCTAssertTrue(
            try XCTUnwrap(model.lines.first { $0.lineID == line }).source.isLibrarySound(expected.id)
        )
    }

    func testAnAssignmentTheStoreRefusesRaisesAnAlertAndKeepsTheOldSound() throws {
        let line = try open()
        let current = try XCTUnwrap(model.lines.first { $0.lineID == line })
        let other = try XCTUnwrap(
            model.palette.first { $0.kind == .synth && !current.source.isLibrarySound($0.id) }
        )
        try library.failWrites(.update, on: PresetCatalog.tableName)

        model.assign(soundID: other.id, toLine: line)

        XCTAssertEqual(
            model.alert?.title, "Could not give “\(current.name)” the sound “\(other.name)”"
        )
        XCTAssertEqual(model.lines.first { $0.lineID == line }?.source, current.source)
    }

    // MARK: Missing instruments (issue #24)

    /// A line whose instrument is not downloaded is silent until the owner
    /// explicitly accepts a substitute, and that answer is saved with the
    /// preset; withdrawing it is saved the same way.
    func testAcceptingAndWithdrawingASubstituteIsSavedWithThePreset() throws {
        let line = try open()
        let catalog = try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        let coverage = try XCTUnwrap(
            catalog.coverage.first { $0.identifier == "vsco2.cello.section" }
        )
        let variant = try library.store.sounds.createVariant(
            InstrumentVariant(reference: InstrumentReference(library: catalog, coverage: coverage)),
            named: "Not Downloaded Cello"
        )
        model.refreshFromStore()
        model.assign(soundID: variant.id, toLine: line)
        model.selectedLineID = line

        let silent = try XCTUnwrap(model.lines.first { $0.lineID == line })
        XCTAssertTrue(silent.isSilent, "Nothing is substituted without the owner asking")
        XCTAssertTrue(silent.canOfferSubstitution)
        XCTAssertNotNil(model.instrumentBanner)

        model.toggleSubstitutionOnSelectedLine()
        XCTAssertNil(model.alert)
        XCTAssertTrue(try XCTUnwrap(model.lines.first { $0.lineID == line }).acceptsSubstitution)
        XCTAssertTrue(try XCTUnwrap(storedActive().line(withID: line)).acceptsSubstitution)

        model.toggleSubstitutionOnSelectedLine()
        XCTAssertFalse(try XCTUnwrap(model.lines.first { $0.lineID == line }).acceptsSubstitution)
        XCTAssertFalse(try XCTUnwrap(storedActive().line(withID: line)).acceptsSubstitution)
    }

    // MARK: Naming a line (REQ-005)

    func testRenamingALineAndResettingIt() throws {
        let line = try open()
        let original = try XCTUnwrap(model.entry(for: line)).name

        model.beginLineRename(line)
        XCTAssertEqual(model.lineNameDraft, original)
        model.lineNameDraft = "Solo flute"
        model.commitLineRename()

        XCTAssertNil(model.renamingLineID)
        XCTAssertEqual(model.entry(for: line)?.name, "Solo flute")
        XCTAssertEqual(model.lines.first { $0.lineID == line }?.name, "Solo flute")
        XCTAssertEqual(
            try library.store.lineInventory(for: score).entry(withID: line)?.name, "Solo flute"
        )

        model.resetName(ofLine: line)
        XCTAssertEqual(model.entry(for: line)?.name, original)
        XCTAssertEqual(
            try library.store.lineInventory(for: score).entry(withID: line)?.name, original
        )
    }

    func testALineRenameTheStoreRefusesRaisesAnAlert() throws {
        let line = try open()
        let original = try XCTUnwrap(model.entry(for: line)).name
        try library.failWrites(.insert, on: PresetCatalog.lineNameTableName)

        model.beginLineRename(line)
        model.lineNameDraft = "Solo flute"
        model.commitLineRename()

        XCTAssertEqual(model.alert?.title, "Could not rename “\(original)”")
        XCTAssertEqual(model.entry(for: line)?.name, original)
    }

    // MARK: Play-through (SYN003)

    func testPlayThroughSuspendsThePresetAndGivesItBack() throws {
        try open()
        model.setSuspendedByPlayThrough(true)
        XCTAssertTrue(model.isSuspendedByPlayThrough)
        XCTAssertNotNil(model.exportCaveat, "The export sheet has to warn about it")

        model.setSuspendedByPlayThrough(false)
        XCTAssertFalse(model.isSuspendedByPlayThrough)
        XCTAssertNil(model.exportCaveat)
        XCTAssertEqual(model.statusMessage, "Back on this preset's own sounds.")
    }

    // MARK: Keyboard navigation (REQ-027)

    func testLineSelectionStopsAtBothEnds() throws {
        try open()
        let focus = model.lineFocusRequests
        model.selectPreviousLine()
        XCTAssertEqual(model.selectedLineID, model.lines[0].lineID)
        model.selectNextLine()
        model.selectNextLine()
        XCTAssertEqual(model.selectedLineID, model.lines[1].lineID)
        XCTAssertEqual(model.lineFocusRequests, focus + 3)
    }
}
