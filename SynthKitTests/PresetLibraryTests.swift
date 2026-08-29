import Foundation
import XCTest
@testable import SynthKit

/// Issue #20: the assignment and preset model.
///
/// Every claim here is checked against the store, not against an in-memory
/// object: "auto-saved" is proved by reopening the database in a new
/// `LibraryStore`, "one active" by asking SQLite, and "the cascade ran" by
/// counting rows after a removal. A test that set a property and read it back
/// would agree with a model that never persisted anything.
final class PresetLibraryTests: XCTestCase {
    private var sandboxRoot: URL!
    private var sourceDirectory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        sourceDirectory = sandboxRoot.appending(path: "sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        store = try launch()
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    private func launch() throws -> LibraryStore {
        try LibraryStore.open(container: container, appVersion: "1.0 (1)")
    }

    /// Closes the store and opens a new one over the same container — the only
    /// honest way to test "survives a relaunch".
    private func relaunch() throws -> LibraryStore {
        store.close()
        store = try launch()
        return store
    }

    // MARK: Fixtures

    @discardableResult
    private func importScore(
        _ musicXML: Data, named name: String
    ) throws -> PieceRecord {
        let url = sourceDirectory.appending(path: name)
        try musicXML.write(to: url)
        return try store.makeImporter().importPiece(from: url).piece
    }

    /// The four-voice keyboard fugue — the REQ-005 acceptance fixture.
    @discardableResult
    private func importFugue() throws -> PieceRecord {
        try importScore(MusicXMLScoreFixtures.keyboardFugueExposition(), named: "fugue.musicxml")
    }

    /// A quartet whose parts are named after real instruments, so the
    /// auto-mapping has something to match.
    private static func namedEnsemble() -> Data {
        func part(id: String, name: String, pitch: String) -> ScoreXML.Part {
            ScoreXML.Part(
                id: id,
                name: name,
                measures: [
                    ScoreXML.Measure(
                        number: "1",
                        items: [
                            .attributes(
                                ScoreXML.Attributes(
                                    divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                                )
                            ),
                            .note(ScoreXML.Note(pitch: pitch, duration: 16, type: "whole"))
                        ]
                    )
                ]
            )
        }
        return ScoreXML.Score(
            workTitle: "Named Ensemble",
            composer: "Fixture",
            parts: [
                part(id: "P1", name: "Violin I", pitch: "A5"),
                part(id: "P2", name: "Trumpet in B♭", pitch: "D5"),
                part(id: "P3", name: "Harpsichord", pitch: "F4"),
                part(id: "P4", name: "Contrabass", pitch: "A2")
            ]
        ).data()
    }

    private func compile(_ piece: PieceRecord) throws -> CompiledScore {
        try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)
    }

    private func testPatch(cutoff: Double = 3_000, level: Double = 0.2) -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.8),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: cutoff),
            outputLevel: level
        )
    }

    // MARK: Line inventory (REQ-005)

    /// "A WTC fugue for keyboard shows one line per fugue voice, not one
    /// 'Piano' line."
    func testAFugueYieldsOneInventoryEntryPerVoice() throws {
        let score = try compile(try importFugue())
        let inventory = try store.lineInventory(for: score)

        XCTAssertEqual(inventory.count, 4, "four fugal voices, not one Piano line")
        XCTAssertEqual(
            inventory.entries.map(\.name),
            [
                "Piano, staff 1, voice 1",
                "Piano, staff 1, voice 2",
                "Piano, staff 2, voice 5",
                "Piano, staff 2, voice 6"
            ]
        )
        XCTAssertEqual(inventory.entries.map(\.partName), Array(repeating: "Piano", count: 4))
        XCTAssertTrue(inventory.entries.allSatisfy { !$0.isRenamed })
    }

    func testRenamingALineSurvivesARelaunchAndKeepsItsIdentity() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let inventory = try store.lineInventory(for: score)
        let soprano = try XCTUnwrap(inventory.entries.first)

        let renamed = try store.presets.renameLine(soprano, inPieceID: piece.id, to: "Soprano")
        XCTAssertEqual(renamed.name, "Soprano")
        XCTAssertTrue(renamed.isRenamed)
        XCTAssertEqual(renamed.id, soprano.id, "A rename must not move the line's identity")

        let reopened = try relaunch()
        let after = try reopened.lineInventory(for: try compile(piece))
        XCTAssertEqual(after.entries.map(\.name).first, "Soprano")
        XCTAssertEqual(after.entries.map(\.id), inventory.entries.map(\.id))
        // Only the renamed line moved.
        XCTAssertEqual(Array(after.entries.dropFirst().map(\.name)),
                       Array(inventory.entries.dropFirst().map(\.name)))
    }

    /// Resetting is a delete, not a write of the current default, so a later
    /// improvement to the name deriver still reaches the line.
    func testResettingALineNameRemovesTheStoredRenameRatherThanFreezingIt() throws {
        let piece = try importFugue()
        let inventory = try store.lineInventory(for: try compile(piece))
        let line = try XCTUnwrap(inventory.entries.first)

        _ = try store.presets.renameLine(line, inPieceID: piece.id, to: "Soprano")
        XCTAssertEqual(try PresetCatalog(database: store.database)
            .lineNameCount(forPieceID: piece.id), 1)

        let reset = try store.presets.resetLineName(line, inPieceID: piece.id)
        XCTAssertEqual(reset.name, line.defaultName)
        XCTAssertFalse(reset.isRenamed)
        XCTAssertEqual(try PresetCatalog(database: store.database)
            .lineNameCount(forPieceID: piece.id), 0)
    }

    /// Renaming a line back to exactly the score's own name is the same as
    /// resetting it.
    func testRenamingToTheDefaultNameClearsTheStoredRename() throws {
        let piece = try importFugue()
        let inventory = try store.lineInventory(for: try compile(piece))
        let line = try XCTUnwrap(inventory.entries.first)

        _ = try store.presets.renameLine(line, inPieceID: piece.id, to: "Soprano")
        _ = try store.presets.renameLine(line, inPieceID: piece.id, to: line.defaultName)

        XCTAssertEqual(try PresetCatalog(database: store.database)
            .lineNameCount(forPieceID: piece.id), 0)
    }

    func testAnEmptyLineNameIsRefused() throws {
        let piece = try importFugue()
        let line = try XCTUnwrap(try store.lineInventory(for: try compile(piece)).entries.first)
        XCTAssertThrowsError(try store.presets.renameLine(line, inPieceID: piece.id, to: "   ")) {
            XCTAssertEqual($0 as? PresetError, .nameIsEmpty)
        }
    }

    // MARK: First open (REQ-007)

    /// "First open of a fugue creates an active playable preset with one entry
    /// per fugue voice."
    func testFirstOpenCreatesAnActivePlayablePresetWithOneEntryPerVoice() throws {
        let piece = try importFugue()
        let score = try compile(piece)

        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 0)

        let preset = try store.activePreset(for: score)

        XCTAssertEqual(preset.name, PresetLibrary.initialPresetName)
        XCTAssertTrue(preset.isActive)
        XCTAssertEqual(preset.lines.count, 4)
        XCTAssertEqual(preset.lines.map(\.lineID), score.lines.map(\.id))
        // Playable means every line has a sound and a neutral strip.
        XCTAssertTrue(preset.lines.allSatisfy { !$0.assignment.isEmbedded })
        XCTAssertTrue(preset.lines.allSatisfy { $0.mixer == .neutral })

        let performance = try store.openActivePreset(for: score)
        XCTAssertFalse(performance.hasMissingSound)
        XCTAssertEqual(performance.lines.count, 4)
    }

    /// A keyboard piece starts on the Default Voice, so a first open sounds
    /// exactly like increment 003 did.
    func testAKeyboardPieceStartsOnTheDefaultVoice() throws {
        let score = try compile(try importFugue())
        let performance = try store.openActivePreset(for: score)

        XCTAssertTrue(performance.lines.allSatisfy { $0.patch == .defaultVoice },
                      "A first open must not change what a keyboard piece already sounded like")
    }

    /// "The closest available instruments named in the score, else a sensible
    /// default" — with a synth palette, closest means closest category.
    func testAutoMappingPicksTheClosestCategoryForEachNamedInstrument() throws {
        let score = try compile(
            try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")
        )
        let performance = try store.openActivePreset(for: score)
        let categories = try performance.lines.map { line -> SoundCategory in
            let id = try XCTUnwrap(
                { if case .library(let soundID, _) = line.source { return soundID } else { return nil } }()
            )
            return try XCTUnwrap(try store.sounds.sound(withID: id)).category
        }

        XCTAssertEqual(categories, [.strings, .brass, .keys, .bass],
                       "Violin → Strings, Trumpet → Brass, Harpsichord → Keys, Contrabass → Bass")
    }

    /// The overlapping-word cases the rule order exists for.
    func testAutoMappingDisambiguatesWordsThatContainOtherWords() throws {
        func category(part: String) -> SoundCategory? {
            PresetAutoAssignment.category(
                for: LineEntry(id: ScoreLineID(rawValue: "x"), defaultName: part, partName: part)
            )
        }
        XCTAssertEqual(category(part: "Bass Clarinet"), .leads, "a bass clarinet is a wind")
        XCTAssertEqual(category(part: "Contrabassoon"), .leads)
        XCTAssertEqual(category(part: "Contrabass"), .bass)
        XCTAssertEqual(category(part: "Double Bass"), .bass)
        XCTAssertEqual(category(part: "French Horn"), .brass)
        XCTAssertEqual(category(part: "Violoncello"), .strings)
        XCTAssertEqual(category(part: "Harpsichord"), .keys, "a harpsichord is a keyboard")
        XCTAssertEqual(category(part: "Harp"), .plucks)
        XCTAssertNil(category(part: "Upper"), "an unrecognised part must not be forced into a guess")
    }

    func testAnUnrecognisedPartFallsBackToTheDefaultVoiceRatherThanSilence() throws {
        // `twoLineFixture`'s parts are "Upper" and "Lower" — deliberately not
        // instrument names.
        let score = try compile(
            try importScore(AudioRenderFixtures.twoLineFixture(), named: "twolines.musicxml")
        )
        let performance = try store.openActivePreset(for: score)

        XCTAssertEqual(performance.lines.count, 2)
        XCTAssertTrue(performance.lines.allSatisfy { $0.patch == .defaultVoice })
        XCTAssertFalse(performance.hasMissingSound)
    }

    /// Opening a piece twice must not make a second preset.
    func testOpeningAPieceTwiceReusesTheSamePreset() throws {
        let score = try compile(try importFugue())
        let first = try store.activePreset(for: score)
        let second = try store.activePreset(for: score)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.revision, second.revision, "A reopen must not rewrite the preset")
        XCTAssertEqual(try store.presets.presetCount(forPieceID: score.pieceID), 1)
    }

    func testAPieceWithNoLinesIsReportedRatherThanGivenAnEmptyPreset() throws {
        let inventory = LineInventory(pieceID: "empty", entries: [])
        XCTAssertThrowsError(
            try store.presets.activePreset(for: inventory, palette: store.sounds.shippedSounds)
        ) {
            XCTAssertEqual($0 as? PresetError, .pieceHasNoLines(pieceID: "empty"))
        }
    }

    /// The symmetric guard: a palette that cannot cover a line is reported the
    /// way an empty inventory is, rather than producing a preset that looks
    /// real and plays nothing on that line.
    ///
    /// Unreachable through the app — the shipped collection is compiled into
    /// the build — but `activePreset(for:palette:)` is public, and a caller
    /// filtering the palette would land here.
    func testAPaletteThatCannotCoverALineIsReportedNotSilentlySkipped() throws {
        let piece = try importFugue()
        let inventory = try store.lineInventory(for: try compile(piece))
        let firstLine = try XCTUnwrap(inventory.entries.first)

        XCTAssertThrowsError(try store.presets.activePreset(for: inventory, palette: [])) {
            XCTAssertEqual(
                $0 as? PresetError, .noSoundAvailableForLine(name: firstLine.name)
            )
        }
        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 0,
                       "Nothing may be stored when the palette cannot cover the piece.")

        XCTAssertThrowsError(
            try PresetAutoAssignment.initialContent(for: inventory, palette: [])
        )
        XCTAssertThrowsError(try PresetAutoAssignment.assignment(for: firstLine, from: []))
    }

    /// Reconciliation has the same all-or-nothing rule: a line the palette
    /// cannot cover is reported rather than dropped from the rebuilt preset.
    func testReconciliationRefusesAPaletteThatCannotCoverANewLine() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let preset = try store.activePreset(for: score)
        let inventory = try store.lineInventory(for: score)

        // A preset that has lost one of its lines, so reconciliation has to
        // supply a replacement — with nothing to supply it from.
        var content = preset.content
        content.lines.removeLast()
        let shortened = Preset(
            id: preset.id, pieceID: preset.pieceID, name: preset.name, isActive: true,
            documentVersion: preset.documentVersion, revision: preset.revision,
            createdAt: preset.createdAt, updatedAt: preset.updatedAt, content: content
        )

        XCTAssertThrowsError(
            try store.presets.reconcile(shortened, with: inventory, palette: [])
        ) {
            XCTAssertEqual(
                $0 as? PresetError,
                .noSoundAvailableForLine(name: try! XCTUnwrap(inventory.entries.last).name)
            )
        }
        // The stored preset is untouched.
        XCTAssertEqual(
            try store.presets.activePreset(forPieceID: piece.id)?.content, preset.content
        )
    }

    // MARK: Auto-save and durability (REQ-024, REQ-025)

    /// "Assignment/mixer changes auto-save; relaunch restores the active preset
    /// exactly."
    func testAssignmentAndMixerChangesSurviveARelaunchExactly() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let preset = try store.activePreset(for: score)
        let bell = try XCTUnwrap(store.sounds.shippedSounds.first { $0.category == .bells })

        let alto = preset.lines[1].lineID
        var current = try store.presets.assign(
            .library(kind: .synth, soundID: bell.id), toLine: alto, in: preset
        )
        current = try store.presets.setMixer(
            LineMixerState(volume: 0.4, pan: -0.75, isMuted: false, isSoloed: true),
            forLine: alto,
            in: current
        )

        // No save() call anywhere above. Reopen the database and look.
        let reopened = try relaunch()
        let restored = try XCTUnwrap(try reopened.presets.activePreset(forPieceID: piece.id))

        XCTAssertEqual(restored.id, preset.id)
        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(
            restored.line(withID: alto)?.assignment, .library(kind: .synth, soundID: bell.id)
        )
        XCTAssertEqual(
            restored.line(withID: alto)?.mixer,
            LineMixerState(volume: 0.4, pan: -0.75, isMuted: false, isSoloed: true)
        )
        // And nothing else moved.
        XCTAssertEqual(restored.lines.count, 4)
        XCTAssertTrue(
            restored.lines.filter { $0.lineID != alto }.allSatisfy { $0.mixer == .neutral }
        )
    }

    func testEveryChangeBumpsTheRevisionAndTheTimestamp() throws {
        let score = try compile(try importFugue())
        let preset = try store.activePreset(for: score)
        let updated = try store.presets.rename(preset, to: "Chamber")

        XCTAssertEqual(updated.revision, preset.revision + 1)
        XCTAssertEqual(updated.createdAt, preset.createdAt, "Creation time is not a mutable field")
        XCTAssertEqual(updated.name, "Chamber")
    }

    func testAssigningToALineThePresetDoesNotHaveIsReportedNotIgnored() throws {
        let score = try compile(try importFugue())
        let preset = try store.activePreset(for: score)
        let absent = ScoreLineID(partID: "PX", staff: 9, voice: "9")

        XCTAssertThrowsError(
            try store.presets.assign(.library(kind: .synth, soundID: "whatever"), toLine: absent, in: preset)
        ) {
            XCTAssertEqual($0 as? PresetError, .lineNotInPreset(lineID: absent.rawValue))
        }
    }

    /// "Auto-save failure surfaces an error without discarding in-memory
    /// state."
    ///
    /// The API is value-returning, so "in-memory state is not discarded" is
    /// literal: a throw means the caller still holds the preset it had, and the
    /// stored one is unchanged, so retrying the same call is safe.
    func testAFailedAutoSaveIsReportedAndChangesNothing() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID
        let bell = try XCTUnwrap(store.sounds.shippedSounds.first { $0.category == .bells })

        // A trigger standing in for the real failures — a damaged database, a
        // full disk — because a refused write is the behaviour under test, not
        // the reason it was refused.
        try store.database.executeScript(
            """
            CREATE TRIGGER refuse_updates_to_presets
                BEFORE UPDATE ON \(PresetCatalog.tableName)
            BEGIN
                SELECT RAISE(ABORT, 'the disk is full');
            END;
            """
        )

        XCTAssertThrowsError(
            try store.presets.assign(.library(kind: .synth, soundID: bell.id), toLine: line, in: preset)
        ) { error in
            guard case PresetError.storeFailed(let name, let reason) = error else {
                return XCTFail("Expected storeFailed, got \(error)")
            }
            XCTAssertEqual(name, preset.name, "The failure must name the preset")
            XCTAssertFalse(reason.isEmpty)
        }

        // The caller's value is untouched, and so is the store.
        XCTAssertEqual(preset.line(withID: line)?.assignment, .library(kind: .synth, soundID: SynthPatch.defaultVoice.identifier))
        let stored = try XCTUnwrap(try store.presets.activePreset(forPieceID: piece.id))
        XCTAssertEqual(stored.content, preset.content)
        XCTAssertEqual(stored.revision, preset.revision)

        // And once the store accepts writes again the same call succeeds.
        try store.database.executeScript("DROP TRIGGER refuse_updates_to_presets;")
        let saved = try store.presets.assign(
            .library(kind: .synth, soundID: bell.id), toLine: line, in: preset
        )
        XCTAssertEqual(saved.line(withID: line)?.assignment, .library(kind: .synth, soundID: bell.id))
    }

    // MARK: Several presets, exactly one active (REQ-024)

    func testExactlyOnePresetPerPieceIsActive() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let first = try store.activePreset(for: score)
        let second = try store.presets.duplicate(first, named: "Bright", makeActive: true)

        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 2)
        XCTAssertEqual(
            try store.database.scalarInt(
                "SELECT count(*) FROM presets WHERE piece_id = ? AND is_active = 1;",
                [.text(piece.id)]
            ),
            1
        )
        XCTAssertEqual(try store.presets.activePreset(forPieceID: piece.id)?.id, second.id)
    }

    /// The database enforces it, not the code that remembers to clear the flag.
    func testTheStoreItselfRefusesASecondActivePreset() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let first = try store.activePreset(for: score)
        _ = try store.presets.duplicate(first, named: "Bright", makeActive: false)

        XCTAssertThrowsError(
            try store.database.execute(
                "UPDATE presets SET is_active = 1 WHERE piece_id = ?;", [.text(piece.id)]
            ),
            "The partial unique index must make two active presets impossible"
        )
    }

    /// "Switching presets never loses the previous preset's state."
    func testSwitchingPresetsKeepsBothPresetsExactlyAsTheyWere() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let bell = try XCTUnwrap(store.sounds.shippedSounds.first { $0.category == .bells })
        let brass = try XCTUnwrap(store.sounds.shippedSounds.first { $0.category == .brass })

        let quiet = try store.activePreset(for: score)
        let line = quiet.lines[0].lineID
        let quietSet = try store.presets.setMixer(
            LineMixerState(volume: 0.25), forLine: line, in: quiet
        )

        var loud = try store.presets.duplicate(quietSet, named: "Loud", makeActive: false)
        loud = try store.presets.setMixer(LineMixerState(volume: 2), forLine: line, in: loud)
        loud = try store.presets.assign(
            .library(kind: .synth, soundID: brass.id), toLine: line, in: loud
        )

        _ = try store.presets.activate(loud)
        // Switch back and forth once more, through a relaunch, to be sure
        // nothing is being held only in memory.
        let reopened = try relaunch()
        let stored = try reopened.presets.presets(forPieceID: piece.id)
        _ = try reopened.presets.activate(try XCTUnwrap(stored.first { $0.id == quietSet.id }))

        let after = try reopened.presets.presets(forPieceID: piece.id)
        let quietAfter = try XCTUnwrap(after.first { $0.id == quietSet.id })
        let loudAfter = try XCTUnwrap(after.first { $0.id == loud.id })

        XCTAssertEqual(quietAfter.line(withID: line)?.mixer.volume, 0.25)
        XCTAssertEqual(loudAfter.line(withID: line)?.mixer.volume, 2)
        XCTAssertEqual(
            loudAfter.line(withID: line)?.assignment, .library(kind: .synth, soundID: brass.id)
        )
        XCTAssertTrue(quietAfter.isActive)
        XCTAssertFalse(loudAfter.isActive)
        XCTAssertNotEqual(bell.id, brass.id)
    }

    func testDeletingTheActivePresetPromotesAnother() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let first = try store.activePreset(for: score)
        let second = try store.presets.duplicate(first, named: "Bright", makeActive: true)

        try store.presets.delete(second)

        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 1)
        XCTAssertEqual(try store.presets.activePreset(forPieceID: piece.id)?.id, first.id)
    }

    /// A caller holding a preset that was deactivated in the meantime must
    /// still be able to delete it.
    ///
    /// The stale value says "I am active", so trusting it would promote a
    /// *second* active preset and the partial unique index would reject the
    /// whole delete — a legitimate action failing with "Synth could not save".
    /// The active flag is therefore read from the store inside the transaction.
    func testDeletingAPresetThatWasDeactivatedElsewhereStillSucceeds() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let first = try store.activePreset(for: score)
        let second = try store.presets.duplicate(first, named: "Bright", makeActive: false)
        let third = try store.presets.duplicate(first, named: "Aardvark", makeActive: false)

        // Something else activates another preset; `first` is now stale and
        // still claims to be active.
        _ = try store.presets.activate(second)
        XCTAssertTrue(first.isActive, "The test needs a stale value that claims to be active.")

        try store.presets.delete(first)

        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 2)
        XCTAssertEqual(
            try store.presets.activePreset(forPieceID: piece.id)?.id, second.id,
            "The preset that was really active must stay active."
        )
        XCTAssertEqual(
            try store.database.scalarInt(
                "SELECT count(*) FROM presets WHERE piece_id = ? AND is_active = 1;",
                [.text(piece.id)]
            ),
            1
        )
        XCTAssertNotEqual(third.id, second.id)
    }

    /// A piece is always playable (REQ-007), so its last preset stays.
    func testTheLastPresetOfAPieceCannotBeDeleted() throws {
        let score = try compile(try importFugue())
        let only = try store.activePreset(for: score)

        XCTAssertThrowsError(try store.presets.delete(only)) {
            XCTAssertEqual($0 as? PresetError, .lastPresetCannotBeDeleted(name: only.name))
        }
        XCTAssertEqual(try store.presets.presetCount(forPieceID: score.pieceID), 1)
    }

    func testDuplicatingWithoutANameProducesALegibleCopyName() throws {
        let score = try compile(try importFugue())
        let first = try store.activePreset(for: score)

        XCTAssertEqual(try store.presets.duplicate(first).name, "Default copy")
        XCTAssertEqual(try store.presets.duplicate(first).name, "Default copy 2")
    }

    // MARK: Live references and embed-on-delete (REQ-029)

    /// The warning's material: which presets, and how many of their lines.
    func testUsageReportsEveryPresetThatReferencesASoundAcrossEveryPiece() throws {
        let fugue = try importFugue()
        let ensemble = try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")
        let mine = try store.sounds.create(patch: testPatch(), named: "My Sound", in: .keys)

        let fuguePreset = try store.activePreset(for: try compile(fugue))
        var assigned = try store.presets.assign(
            .library(kind: .synth, soundID: mine.id), toLine: fuguePreset.lines[0].lineID, in: fuguePreset
        )
        assigned = try store.presets.assign(
            .library(kind: .synth, soundID: mine.id), toLine: assigned.lines[2].lineID, in: assigned
        )

        let ensemblePreset = try store.activePreset(for: try compile(ensemble))
        _ = try store.presets.assign(
            .library(kind: .synth, soundID: mine.id), toLine: ensemblePreset.lines[1].lineID, in: ensemblePreset
        )

        let usage = try store.presets.usage(ofSoundID: mine.id)
        XCTAssertEqual(usage.count, 2, "A warning that counted only the open piece would understate this")
        XCTAssertEqual(Set(usage.map(\.pieceID)), [fugue.id, ensemble.id])
        XCTAssertEqual(
            usage.first { $0.pieceID == fugue.id }?.lineIDs.count, 2
        )
        XCTAssertTrue(try store.presets.isSoundInUse(mine.id))
    }

    func testASoundNoPresetUsesIsNotReportedAsInUse() throws {
        let unused = try store.sounds.create(patch: testPatch(), named: "Unused", in: .pads)
        XCTAssertFalse(try store.presets.isSoundInUse(unused.id))
        XCTAssertTrue(try store.presets.usage(ofSoundID: unused.id).isEmpty)
    }

    /// "Editing a user sound changes playback of every preset referencing it."
    ///
    /// The audible half of this is `PresetRenderTests`; here it is the model
    /// half — the reference resolves to the sound's *current* patch, not to a
    /// copy taken when it was assigned.
    func testEditingAReferencedSoundReachesEveryPresetThatUsesIt() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let mine = try store.sounds.create(patch: testPatch(cutoff: 800), named: "Mine", in: .keys)

        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID
        _ = try store.presets.assign(.library(kind: .synth, soundID: mine.id), toLine: line, in: preset)

        _ = try store.sounds.update(mine, patch: testPatch(cutoff: 9_000))

        let performance = try store.openActivePreset(for: score)
        let resolved = try XCTUnwrap(performance.lines.first { $0.lineID == line })
        XCTAssertEqual(try XCTUnwrap(resolved.patch).filter.cutoffHertz, 9_000,
                       "The preset must follow the sound, not a copy of it")
        XCTAssertFalse(resolved.source.isEmbedded)
    }

    /// "Deleting it after the warning leaves each affected preset ... observably
    /// marked embedded."
    func testDeletingAnInUseSoundEmbedsACopyIntoEveryPresetThatUsedIt() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let mine = try store.sounds.create(patch: testPatch(cutoff: 1_234), named: "Doomed", in: .keys)

        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID
        let untouched = preset.lines[1].lineID
        _ = try store.presets.assign(.library(kind: .synth, soundID: mine.id), toLine: line, in: preset)

        try store.sounds.delete(mine)

        let after = try XCTUnwrap(try store.presets.activePreset(forPieceID: fugue.id))
        let assignment = try XCTUnwrap(after.line(withID: line)?.assignment)
        guard case .embedded(let embedded) = assignment else {
            return XCTFail("Expected an embedded copy, got \(assignment)")
        }
        XCTAssertEqual(embedded.originalSoundID, mine.id)
        XCTAssertEqual(embedded.name, "Doomed")
        XCTAssertEqual(embedded.category, .keys)
        XCTAssertEqual(embedded.patch.filter.cutoffHertz, 1_234,
                       "The copy must be the sound as it was")
        XCTAssertFalse(embedded.embeddedAt.isEmpty)

        // Lines that did not use it are untouched.
        XCTAssertFalse(try XCTUnwrap(after.line(withID: untouched)).assignment.isEmbedded)

        // And it is visible as embedded, which is what REQ-029 asks for.
        let performance = try store.openActivePreset(for: score)
        XCTAssertEqual(performance.embeddedLines.map(\.lineID), [line])
        XCTAssertTrue(
            try XCTUnwrap(performance.lines.first { $0.lineID == line })
                .accessibilityDescription.contains("embedded copy")
        )
        XCTAssertFalse(performance.hasMissingSound)
    }

    func testAnEmbeddedCopySurvivesARelaunchAndIsNoLongerAReference() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let mine = try store.sounds.create(patch: testPatch(cutoff: 1_234), named: "Doomed", in: .keys)
        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID
        _ = try store.presets.assign(.library(kind: .synth, soundID: mine.id), toLine: line, in: preset)
        try store.sounds.delete(mine)

        let reopened = try relaunch()
        let after = try XCTUnwrap(try reopened.presets.activePreset(forPieceID: fugue.id))
        guard case .embedded(let embedded) = try XCTUnwrap(after.line(withID: line)?.assignment) else {
            return XCTFail("The embedded copy did not survive the relaunch")
        }
        XCTAssertEqual(embedded.patch.filter.cutoffHertz, 1_234)
        XCTAssertFalse(after.content.referencedLibrarySoundIDs.contains(mine.id))
        XCTAssertTrue(try reopened.presets.usage(ofSoundID: mine.id).isEmpty,
                      "An embedded copy is not a live reference any more")
        XCTAssertTrue(try reopened.sounds.isRetired(id: mine.id))
    }

    /// Deleting a second sound must not re-stamp the copy the first delete made.
    func testAnAlreadyEmbeddedLineIsNotReEmbeddedByALaterDeletion() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let first = try store.sounds.create(patch: testPatch(cutoff: 700), named: "First", in: .keys)
        let second = try store.sounds.create(patch: testPatch(cutoff: 5_000), named: "Second", in: .pads)

        var preset = try store.activePreset(for: score)
        preset = try store.presets.assign(
            .library(kind: .synth, soundID: first.id), toLine: preset.lines[0].lineID, in: preset
        )
        preset = try store.presets.assign(
            .library(kind: .synth, soundID: second.id), toLine: preset.lines[1].lineID, in: preset
        )

        try store.sounds.delete(first)
        try store.sounds.delete(second)

        let after = try XCTUnwrap(try store.presets.activePreset(forPieceID: fugue.id))
        guard
            case .embedded(let one) = try XCTUnwrap(after.line(withID: preset.lines[0].lineID)?.assignment),
            case .embedded(let two) = try XCTUnwrap(after.line(withID: preset.lines[1].lineID)?.assignment)
        else {
            return XCTFail("Both lines should hold embedded copies")
        }
        XCTAssertEqual(one.name, "First")
        XCTAssertEqual(one.patch.filter.cutoffHertz, 700)
        XCTAssertEqual(two.name, "Second")
        XCTAssertEqual(two.patch.filter.cutoffHertz, 5_000)
    }

    /// Deleting a sound no preset uses must still succeed — and must not touch
    /// any preset.
    func testDeletingAnUnusedSoundChangesNoPreset() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let preset = try store.activePreset(for: score)
        let unused = try store.sounds.create(patch: testPatch(), named: "Unused", in: .pads)

        try store.sounds.delete(unused)

        let after = try XCTUnwrap(try store.presets.activePreset(forPieceID: fugue.id))
        XCTAssertEqual(after.revision, preset.revision, "An unrelated deletion must not rewrite presets")
        XCTAssertEqual(after.content, preset.content)
    }

    /// A reference that resolves to nothing — store damage the embed path makes
    /// impossible — falls back visibly rather than going silent.
    func testAReferenceToAVanishedSoundFallsBackToTheDefaultVoiceWithAFlag() throws {
        let fugue = try importFugue()
        let score = try compile(fugue)
        let preset = try store.activePreset(for: score)
        let line = preset.lines[0].lineID

        _ = try store.presets.assign(
            .library(kind: .synth, soundID: "user.never-existed"), toLine: line, in: preset
        )

        let performance = try store.openActivePreset(for: score)
        let resolved = try XCTUnwrap(performance.lines.first { $0.lineID == line })

        XCTAssertEqual(resolved.source, .missing(soundID: "user.never-existed", wasRetired: false))
        XCTAssertEqual(resolved.patch, .defaultVoice, "Never silence, never a crash")
        XCTAssertTrue(performance.hasMissingSound)
        XCTAssertTrue(resolved.accessibilityDescription.contains("sound missing"))
    }

    // MARK: Removal cascade (REQ-003)

    /// "Removing a piece removes its presets."
    ///
    /// This is the verification increment 001's LIB003 could only do against a
    /// stand-in: the dependent store here is the real one.
    func testRemovingAPieceRemovesItsPresetsAndItsLineNames() throws {
        let removed = try importFugue()
        let kept = try importScore(Self.namedEnsemble(), named: "ensemble.musicxml")

        let removedPreset = try store.activePreset(for: try compile(removed))
        _ = try store.presets.duplicate(removedPreset, named: "Second")
        let keptPreset = try store.activePreset(for: try compile(kept))
        let line = try XCTUnwrap(try store.lineInventory(for: try compile(removed)).entries.first)
        _ = try store.presets.renameLine(line, inPieceID: removed.id, to: "Soprano")

        XCTAssertEqual(try store.presets.presetCount(forPieceID: removed.id), 2)

        try store.makeRemover().remove(removed)

        XCTAssertEqual(try store.presets.presetCount(forPieceID: removed.id), 0)
        XCTAssertEqual(
            try PresetCatalog(database: store.database).lineNameCount(forPieceID: removed.id), 0
        )
        // The other piece is untouched.
        XCTAssertEqual(try store.presets.presetCount(forPieceID: kept.id), 1)
        XCTAssertEqual(try store.presets.activePreset(forPieceID: kept.id)?.id, keptPreset.id)
    }

    func testRemovedPresetsStayRemovedAcrossARelaunch() throws {
        let piece = try importFugue()
        _ = try store.activePreset(for: try compile(piece))
        try store.makeRemover().remove(piece)

        let reopened = try relaunch()
        XCTAssertEqual(try reopened.presets.presetCount(forPieceID: piece.id), 0)
        XCTAssertEqual(try PresetCatalog(database: reopened.database).presetCount(), 0)
    }

    /// The foreign key is the belt to the cascade's braces: a removal that
    /// somehow skipped the dependent hook aborts loudly instead of orphaning
    /// presets.
    func testAPieceCannotBeDeletedOutFromUnderItsPresets() throws {
        let piece = try importFugue()
        _ = try store.activePreset(for: try compile(piece))

        XCTAssertThrowsError(
            try store.database.execute("DELETE FROM pieces WHERE id = ?;", [.text(piece.id)])
        )
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(try store.presets.presetCount(forPieceID: piece.id), 1)
    }

    // MARK: Documents

    func testAPresetDocumentRoundTripsByteIdentically() throws {
        let score = try compile(try importFugue())
        let preset = try store.activePreset(for: score)

        let first = try PresetDocument.data(from: preset.content)
        let decoded = try PresetDocument.content(from: first)
        let second = try PresetDocument.data(from: decoded)

        XCTAssertEqual(decoded, preset.content)
        XCTAssertEqual(first, second, "Two writes of one preset must produce identical bytes")
        XCTAssertEqual(try PresetDocument.version(of: first), PresetContent.currentVersion)
    }

    func testAnEmbeddedCopyRoundTripsThroughTheDocument() throws {
        let content = PresetContent(lines: [
            PresetLine(
                lineID: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
                assignment: .embedded(
                    EmbeddedSound(
                        originalSoundID: "user.gone",
                        name: "Gone",
                        category: .bells,
                        content: .synth(testPatch(cutoff: 4_321)),
                        embeddedAt: "2026-08-28T00:00:00Z"
                    )
                ),
                mixer: LineMixerState(volume: 1.5, pan: 0.25, isMuted: true, isSoloed: false)
            )
        ])
        let decoded = try PresetDocument.content(from: try PresetDocument.data(from: content))
        XCTAssertEqual(decoded, content)
    }

    func testADocumentFromANewerBuildIsRefusedRatherThanGuessedAt() throws {
        let future = Data(#"{"version": 99, "preset": {"lines": []}}"#.utf8)
        XCTAssertThrowsError(try PresetDocument.content(from: future)) {
            XCTAssertEqual(
                $0 as? PresetDocumentError,
                .unsupportedVersion(found: 99, supported: PresetContent.currentVersion)
            )
        }
    }

    func testADocumentWithNoVersionIsRefused() throws {
        XCTAssertThrowsError(try PresetDocument.content(from: Data(#"{"preset": {"lines": []}}"#.utf8))) {
            XCTAssertEqual($0 as? PresetDocumentError, .missingVersion)
        }
    }

    /// One sound per line is structural in memory but not in a file.
    func testADocumentAssigningTwoSoundsToOneLineIsRefused() throws {
        let line = ScoreLineID(partID: "P1", staff: 1, voice: "1")
        let content = PresetContent(lines: [
            PresetLine(lineID: line, assignment: .library(kind: .synth, soundID: "a")),
            PresetLine(lineID: line, assignment: .library(kind: .synth, soundID: "b"))
        ])
        XCTAssertThrowsError(try PresetDocument.data(from: content)) {
            XCTAssertEqual($0 as? PresetDocumentError, .duplicateLine(lineID: line.rawValue))
        }
    }

    func testAMixerValueOutsideTheEnginesRangeIsReportedNotClamped() throws {
        let content = PresetContent(lines: [
            PresetLine(
                lineID: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
                assignment: .library(kind: .synth, soundID: "a"),
                mixer: LineMixerState(volume: 99)
            )
        ])
        XCTAssertThrowsError(try PresetDocument.data(from: content)) {
            XCTAssertEqual(
                $0 as? PresetDocumentError,
                .valueOutOfRange(name: "volume", value: 99, minimum: 0, maximum: 8)
            )
        }
    }

    /// A row whose recorded format version disagrees with its document is a
    /// loud unreadable row, not a silently skipped preset.
    func testAPresetRowIsUnreadableWhenItsVersionColumnDisagreesWithItsDocument() throws {
        let piece = try importFugue()
        let preset = try store.activePreset(for: try compile(piece))
        try store.database.execute(
            "UPDATE presets SET document_version = 7 WHERE id = ?;", [.text(preset.id)]
        )

        XCTAssertThrowsError(try store.presets.presets(forPieceID: piece.id)) { error in
            guard case StoreError.presetRowUnreadable(let id, _) = error else {
                return XCTFail("Expected presetRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, preset.id)
        }
    }

    // MARK: Reconciliation

    /// A preset written before a line existed still opens playable.
    func testOpeningReconcilesAPresetWhoseLinesNoLongerMatchTheScore() throws {
        let piece = try importFugue()
        let score = try compile(piece)
        let preset = try store.activePreset(for: score)
        let bell = try XCTUnwrap(store.sounds.shippedSounds.first { $0.category == .bells })
        let kept = preset.lines[0].lineID

        // Keep one line, give it a distinctive sound, and add a stale entry for
        // a line the score does not have.
        var content = PresetContent(lines: [
            PresetLine(
                lineID: kept,
                assignment: .library(kind: .synth, soundID: bell.id),
                mixer: LineMixerState(volume: 0.3)
            )
        ])
        content.lines.append(
            PresetLine(
                lineID: ScoreLineID(partID: "GONE", staff: 1, voice: "1"),
                assignment: .library(kind: .synth, soundID: bell.id)
            )
        )
        try store.database.execute(
            "UPDATE presets SET document = ? WHERE id = ?;",
            [
                .text(String(decoding: try PresetDocument.data(from: content), as: UTF8.self)),
                .text(preset.id)
            ]
        )

        let reconciled = try store.activePreset(for: score)

        XCTAssertEqual(reconciled.lines.map(\.lineID), score.lines.map(\.id),
                       "Every line of the score, and nothing else")
        XCTAssertEqual(
            reconciled.line(withID: kept)?.assignment, .library(kind: .synth, soundID: bell.id),
            "A line that still exists keeps its assignment"
        )
        XCTAssertEqual(reconciled.line(withID: kept)?.mixer.volume, 0.3,
                       "…and its mixer state")
        XCTAssertTrue(try store.openActivePreset(for: score).lines.allSatisfy { !$0.source.isMissing })
    }

    // MARK: Migration from the previous build's schema

    /// A store the previous build wrote — schema v4, with pieces, preferences
    /// and sounds in it — opens at the new schema with everything intact.
    func testAStoreAtSchemaFourMigratesForwardKeepingEverything() throws {
        // Start from a store the *current* build made, then confirm the chain
        // that produced it is the previous build's plus this one's step.
        let piece = try importFugue()
        let sound = try store.sounds.create(patch: testPatch(), named: "Kept", in: .pads)
        let preferences = HumanizationSettings(isEnabled: false, intensity: 42)
        try store.preferences.setHumanization(preferences)
        store.close()

        // A v4 store has no preset tables. Prove the migration is what makes
        // them appear, by dropping to v4's own view of the world first.
        do {
            let database = try SQLiteDatabase.open(at: container.databaseURL)
            defer { database.close() }
            try database.executeScript(
                """
                DROP TABLE presets;
                DROP TABLE line_names;
                DROP TABLE installed_instrument_libraries;
                ALTER TABLE sounds DROP COLUMN kind;
                UPDATE schema_version SET version = 4 WHERE id = 1;
                """
            )
            XCTAssertFalse(try database.tableExists(PresetCatalog.tableName))
        }

        store = try launch()

        XCTAssertEqual(store.migrationOutcome.previousVersion, 4)
        XCTAssertEqual(store.migrationOutcome.currentVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(
            store.migrationOutcome.appliedMigrationNames,
            ["create_presets", "create_installed_instrument_libraries", "add_sound_kind"]
        )

        // Nothing the previous build wrote was disturbed.
        XCTAssertEqual(try store.pieceCount(), 1)
        XCTAssertEqual(try store.sounds.sound(withID: sound.id)?.name, "Kept")
        XCTAssertEqual(store.preferences.humanization(), preferences)

        // And presets work on the migrated store.
        let preset = try store.activePreset(for: try compile(piece))
        XCTAssertEqual(preset.lines.count, 4)
        XCTAssertTrue(preset.isActive)
    }

    /// What reverting this build actually does to a store it already migrated:
    /// the forward-only migrator refuses it by name and version and touches
    /// nothing, so rolling forward again recovers the whole library.
    func testAnEarlierBuildRefusesThisStoreLoudlyWithoutDamagingIt() throws {
        let piece = try importFugue()
        _ = try store.activePreset(for: try compile(piece))
        store.close()

        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }

        XCTAssertThrowsError(
            try SchemaMigrator.migrate(
                database, appVersion: "0.9 (1)",
                migrations: Array(SchemaMigrator.migrations.prefix(4))
            )
        ) { error in
            guard case StoreError.storeWrittenByNewerApp(let stored, let supported) = error else {
                return XCTFail("Expected storeWrittenByNewerApp, got \(error)")
            }
            XCTAssertEqual(stored, SchemaMigrator.latestVersion)
            XCTAssertEqual(supported, 4)
        }

        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM pieces;"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM presets;"), 1)

        store = try launch()
    }
}
