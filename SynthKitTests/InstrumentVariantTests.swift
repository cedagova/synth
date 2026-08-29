import XCTest
@testable import SynthKit

/// Named instrument-customization variants in the personal sound library
/// (REQ-023), and the read-only assets underneath them (REQ-021).
///
/// Two properties are the whole point of this suite, and everything below
/// exists to make them true rather than merely intended:
///
/// 1. **A variant never mutates what was downloaded.** It is a reference plus
///    parameters; the only way to make one is `makeEditableCopy` /
///    `createVariant`, and neither touches a file under `assets/`.
/// 2. **An installed instrument is a library entry, not a row.** It appears
///    when its library is installed, disappears when it is removed, and comes
///    back with the *same identity* — which is what lets a preset reference one.
final class InstrumentVariantTests: XCTestCase {
    private var directory: URL!
    private var container: AppContainer!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "InstrumentVariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = AppContainer(rootURL: directory)
        store = try LibraryStore.open(container: container, appVersion: "test")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: The document

    func testAVariantRoundTripsThroughItsDocumentByteForByte() throws {
        let variant = InstrumentVariant(
            reference: InstrumentReference(
                libraryID: "vsco2-ce",
                instrumentID: "vsco2.cello.section",
                libraryName: "VSCO 2 Community Edition",
                instrumentName: "Cello section"
            ),
            customization: InstrumentCustomization(
                toneLowDecibels: -3.5,
                toneHighDecibels: 2,
                dynamicsResponse: 1.4,
                attackSeconds: 0.08,
                releaseScale: 1.8,
                vibratoDepthCents: 22,
                vibratoRateHz: 5.5,
                tuningOffsetCents: -7,
                articulationFileName: "CelloPizz.sfz"
            )
        )

        let data = try InstrumentVariantDocument.data(from: variant)
        XCTAssertEqual(try InstrumentVariantDocument.variant(from: data), variant)
        XCTAssertEqual(
            try InstrumentVariantDocument.data(from: variant), data,
            "Two writes of one variant must produce identical bytes"
        )
        XCTAssertEqual(try InstrumentVariantDocument.version(of: data), 1)
    }

    func testADocumentMissingItsInstrumentIsRefusedRatherThanGuessedAt() {
        let nameless = InstrumentVariant(
            reference: InstrumentReference(
                libraryID: "", instrumentID: "", libraryName: "", instrumentName: ""
            )
        )
        XCTAssertThrowsError(try InstrumentVariantDocument.data(from: nameless)) { error in
            guard case InstrumentVariantDocumentError.malformed(let reason) = error else {
                return XCTFail("Expected malformed, got \(error)")
            }
            XCTAssertTrue(reason.contains("names no instrument"), reason)
        }
    }

    func testAValueOutsideTheControlsRangeIsRefusedRatherThanClampedOnTheWayIn() {
        var variant = InstrumentVariant(
            reference: InstrumentReference(
                libraryID: "l", instrumentID: "i", libraryName: "L", instrumentName: "I"
            )
        )
        variant.customization.vibratoDepthCents = 900

        XCTAssertThrowsError(try InstrumentVariantDocument.data(from: variant)) { error in
            guard case InstrumentVariantDocumentError.valueOutOfRange(let name, _, _, let max) = error
            else { return XCTFail("Expected valueOutOfRange, got \(error)") }
            XCTAssertEqual(name, "vibratoDepthCents")
            XCTAssertEqual(max, 100)
        }
    }

    func testANewerDocumentIsRefusedByVersionRatherThanMisread() throws {
        let forged = Data("""
            { "version": 99, "variant": {} }
            """.utf8)
        XCTAssertThrowsError(try InstrumentVariantDocument.variant(from: forged)) { error in
            guard case InstrumentVariantDocumentError.unsupportedVersion(let found, let supported)
                = error
            else { return XCTFail("Expected unsupportedVersion, got \(error)") }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, InstrumentVariantDocument.currentVersion)
        }
    }

    /// Every field defaults to the recorded value, so a variant written by a
    /// build that gains a control still opens here minus that control.
    func testADocumentWithoutOptionalFieldsReadsAsTheRecordedInstrument() throws {
        let sparse = Data("""
            {
              "variant": {
                "customization": {},
                "reference": {
                  "instrumentID": "i", "instrumentName": "I",
                  "libraryID": "l", "libraryName": "L"
                }
              },
              "version": 1
            }
            """.utf8)
        let variant = try InstrumentVariantDocument.variant(from: sparse)
        XCTAssertEqual(variant.customization, .asRecorded)
        XCTAssertTrue(variant.customization.isAsRecorded)
    }

    // MARK: Installed instruments in the library

    private func installFixtureLibrary() throws -> AvailableInstrument {
        let root = store.instruments.stagingArea.installedURL(forLibraryID: "vsco2-ce")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The real catalog's cello, installed by writing the files its entry
        // names — so the store resolves it exactly as a download would.
        let cello = try XCTUnwrap(
            InstrumentCatalog.library(withIdentifier: "vsco2-ce")?
                .coverage.first { $0.identifier == "vsco2.cello.section" }
        )
        try SFZFixtures.writeWave(
            SFZFixtures.sine(hertz: 220, seconds: 1.0),
            to: root.appending(path: "cello.wav")
        )
        // Every entry point the catalog names, so the store finds the primary
        // and its alternates exactly as it would after a real download.
        for path in cello.allSFZPaths {
            try """
                <group> ampeg_attack=0 ampeg_release=0.2
                <region> sample=cello.wav lokey=36 hikey=72 pitch_keycenter=57
                """.write(
                    to: root.appending(path: path), atomically: true, encoding: .utf8
                )
        }

        try store.instruments.recordInstall(
            of: try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        )
        return try XCTUnwrap(
            try store.instruments.availableInstruments()
                .first { $0.coverage.identifier == "vsco2.cello.section" },
            "The fixture install should be visible to the asset store"
        )
    }

    func testAnInstalledInstrumentAppearsInTheLibraryAsAReadOnlyEntry() throws {
        let before = try store.sounds.allSounds()
        XCTAssertFalse(before.contains { $0.origin == .instrument })

        let cello = try installFixtureLibrary()
        let after = try store.sounds.allSounds()

        let entry = try XCTUnwrap(
            after.first { $0.origin == .instrument && $0.name == cello.coverage.name }
        )
        XCTAssertEqual(entry.id, "instrument:vsco2-ce/vsco2.cello.section")
        XCTAssertEqual(entry.category, .strings, "A string instrument files under Strings")
        XCTAssertEqual(entry.kind, .instrument)
        XCTAssertFalse(entry.isEditable, "Downloaded assets are read-only")
        XCTAssertTrue(entry.mustBeCopiedToEdit)
        XCTAssertEqual(entry.instrumentVariant?.customization, .asRecorded)
    }

    func testChangingAnInstalledInstrumentInPlaceIsRefusedWithTheRightNextStep() throws {
        let cello = try installFixtureLibrary()
        let entry = try XCTUnwrap(
            try store.sounds.sound(withID: InstrumentReference(cello).soundID)
        )

        XCTAssertThrowsError(try store.sounds.rename(entry, to: "My Cello")) { error in
            guard case SoundLibraryError.instrumentIsReadOnly(let name) = error else {
                return XCTFail("Expected instrumentIsReadOnly, got \(error)")
            }
            XCTAssertEqual(name, entry.name)
            let recovery = try? XCTUnwrap((error as? LocalizedError)?.recoverySuggestion)
            XCTAssertTrue(
                (recovery ?? "").contains("named variant"),
                "The refusal must point at the operation that does work"
            )
        }
        XCTAssertThrowsError(try store.sounds.delete(entry))
    }

    /// The acceptance criterion: "create and assign a named variant (e.g.
    /// darker EQ on cello); it persists, appears in the sound library".
    func testAVariantOfADownloadedInstrumentPersistsAndAppearsInTheLibrary() throws {
        let cello = try installFixtureLibrary()
        let instrument = try XCTUnwrap(
            try store.sounds.sound(withID: InstrumentReference(cello).soundID)
        )

        // Edit-as-copy, exactly as the studio does it.
        var variant = try XCTUnwrap(instrument.instrumentVariant)
        variant.customization.toneLowDecibels = 4
        variant.customization.toneHighDecibels = -5
        let saved = try store.sounds.createVariant(variant, named: "Darker Cello")

        XCTAssertEqual(saved.origin, .user)
        XCTAssertTrue(saved.isEditable)
        XCTAssertEqual(saved.category, .strings)
        XCTAssertEqual(saved.kind, .instrument)
        XCTAssertEqual(saved.instrumentVariant?.customization.toneHighDecibels, -5)

        // It survives a close and reopen — the persistence half of the claim.
        store.close()
        store = try LibraryStore.open(container: container, appVersion: "test")
        let reloaded = try XCTUnwrap(try store.sounds.sound(withID: saved.id))
        XCTAssertEqual(reloaded.instrumentVariant, saved.instrumentVariant)
        XCTAssertEqual(reloaded.name, "Darker Cello")

        // And the downloaded instrument is exactly as it was.
        let original = try XCTUnwrap(
            try store.sounds.sound(withID: InstrumentReference(cello).soundID)
        )
        XCTAssertEqual(original.instrumentVariant?.customization, .asRecorded)
        XCTAssertFalse(original.isEditable)
    }

    /// The read-only claim, checked against the bytes rather than the API.
    func testSavingAVariantDoesNotTouchASingleDownloadedFile() throws {
        let cello = try installFixtureLibrary()
        let root = cello.libraryRootURL

        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                guard let data = FileManager.default.contents(
                    atPath: url.path(percentEncoded: false)
                ) else { continue }
                files[url.lastPathComponent] = data
            }
            return files
        }

        let before = try snapshot()
        XCTAssertFalse(before.isEmpty, "The fixture must actually have installed files")

        var variant = InstrumentVariant.asRecorded(cello)
        variant.customization.vibratoDepthCents = 30
        _ = try store.sounds.createVariant(variant, named: "Wobbly Cello")
        _ = try store.sounds.createVariant(variant, named: "Wobbly Cello 2")

        XCTAssertEqual(try snapshot(), before, "A variant must never write into assets/")
    }

    func testEditingAVariantKeepsItsInstrumentAndBumpsTheRevision() throws {
        let cello = try installFixtureLibrary()
        var variant = InstrumentVariant.asRecorded(cello)
        let saved = try store.sounds.createVariant(variant, named: "Cello A")

        variant.customization.releaseScale = 2.5
        let updated = try store.sounds.update(saved, variant: variant)

        XCTAssertEqual(updated.id, saved.id, "Editing never changes identity")
        XCTAssertEqual(updated.revision, saved.revision + 1)
        XCTAssertEqual(updated.instrumentVariant?.reference, InstrumentReference(cello))
        XCTAssertEqual(updated.instrumentVariant?.customization.releaseScale, 2.5)
    }

    func testRenamingAVariantLeavesItsCustomizationExactlyAsItWas() throws {
        let cello = try installFixtureLibrary()
        var variant = InstrumentVariant.asRecorded(cello)
        variant.customization.toneLowDecibels = -8
        let saved = try store.sounds.createVariant(variant, named: "Before")

        let renamed = try store.sounds.rename(saved, to: "After")
        XCTAssertEqual(renamed.name, "After")
        XCTAssertEqual(renamed.id, saved.id)
        XCTAssertEqual(renamed.instrumentVariant, saved.instrumentVariant)

        let refiled = try store.sounds.recategorize(renamed, to: .pads)
        XCTAssertEqual(refiled.category, .pads)
        XCTAssertEqual(refiled.instrumentVariant, saved.instrumentVariant)
    }

    // MARK: REQ-029 through the preset model

    /// "REQ-029 semantics apply to it via the preset model."
    ///
    /// Deleting a variant a preset references embeds a complete copy of it, so
    /// the preset goes on playing the same instrument the same way — and the
    /// copy is the reference plus the parameters, which is the whole of what a
    /// variant was.
    func testDeletingAVariantEmbedsItIntoEveryPresetThatUsedIt() throws {
        let cello = try installFixtureLibrary()
        var variant = InstrumentVariant.asRecorded(cello)
        variant.customization.toneLowDecibels = 5
        let saved = try store.sounds.createVariant(variant, named: "Doomed Cello")

        let piece = try importFixturePiece()
        let inventory = try store.lineInventory(for: try compile(piece))
        let preset = try store.presets.activePreset(
            for: inventory, palette: try store.sounds.allSounds()
        )
        let line = try XCTUnwrap(preset.lines.first).lineID
        _ = try store.presets.assign(
            .library(kind: .instrument, soundID: saved.id), toLine: line, in: preset
        )

        try store.sounds.delete(saved)

        let after = try XCTUnwrap(try store.presets.activePreset(forPieceID: piece.id))
        let embedded = try XCTUnwrap(after.line(withID: line))
        guard case .embedded(let copy) = embedded.assignment else {
            return XCTFail("Expected an embedded copy, got \(embedded.assignment)")
        }
        XCTAssertEqual(copy.kind, .instrument)
        XCTAssertEqual(copy.name, "Doomed Cello")
        XCTAssertEqual(copy.content.instrumentVariant, variant)
        XCTAssertEqual(copy.originalSoundID, saved.id)

        // And it resolves to something playable rather than to the missing case.
        let performance = try store.openActivePreset(for: try compile(piece))
        let resolved = try XCTUnwrap(performance.lines.first { $0.lineID == line })
        XCTAssertTrue(resolved.source.isEmbedded)
        XCTAssertEqual(resolved.variant, variant)
        XCTAssertTrue(resolved.advice.isEmpty, "Its library is installed, so nothing is wrong")
    }

    func testAnEmbeddedVariantRoundTripsThroughThePresetDocument() throws {
        let variant = InstrumentVariant(
            reference: InstrumentReference(
                libraryID: "l", instrumentID: "i", libraryName: "L", instrumentName: "I"
            ),
            customization: InstrumentCustomization(toneHighDecibels: 6)
        )
        let content = PresetContent(lines: [
            PresetLine(
                lineID: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
                assignment: .embedded(
                    EmbeddedSound(
                        originalSoundID: "user.gone",
                        name: "Gone",
                        category: .strings,
                        content: .instrument(variant),
                        embeddedAt: "2026-08-29T00:00:00Z"
                    )
                ),
                mixer: LineMixerState(volume: 1, pan: 0, isMuted: false, isSoloed: false, roomSend: 0.4),
                acceptsSubstitution: true
            )
        ])

        let data = try PresetDocument.data(from: content)
        XCTAssertEqual(try PresetDocument.content(from: data), content)
    }

    /// A preset written before increment 005 still opens, and reads as dry with
    /// no acknowledgment — which is the only safe default for both fields.
    func testAPresetWrittenBeforeThisBuildStillOpens() throws {
        let old = Data("""
            {
              "preset": {
                "lines": [
                  {
                    "assignment": { "kind": "synth", "soundID": "builtin.default", "source": "library" },
                    "lineID": "P1.1.1",
                    "mixer": { "isMuted": false, "isSoloed": false, "pan": 0.25, "volume": 1.5 }
                  }
                ]
              },
              "version": 1
            }
            """.utf8)

        let content = try PresetDocument.content(from: old)
        let line = try XCTUnwrap(content.lines.first)
        XCTAssertEqual(line.mixer.volume, 1.5)
        XCTAssertEqual(line.mixer.pan, 0.25)
        XCTAssertEqual(line.mixer.roomSend, 0, "An absent room send is dry")
        XCTAssertFalse(
            line.acceptsSubstitution,
            "An absent acknowledgment must never read as consent"
        )
    }

    // MARK: Schema v7

    func testSchemaSevenIsOneAdditiveColumnAndKeepsEverySound() throws {
        let existing = try store.sounds.create(
            patch: .defaultVoice, named: "Made Before", in: .pads
        )
        store.close()

        // Drop to increment 004's view of `sounds`, then migrate forward.
        do {
            let database = try SQLiteDatabase.open(at: container.databaseURL)
            defer { database.close() }
            try database.executeScript(
                """
                ALTER TABLE sounds DROP COLUMN kind;
                UPDATE schema_version SET version = 6 WHERE id = 1;
                """
            )
        }

        store = try LibraryStore.open(container: container, appVersion: "test")
        XCTAssertEqual(store.migrationOutcome.previousVersion, 6)
        XCTAssertEqual(store.migrationOutcome.currentVersion, 7)
        XCTAssertEqual(store.migrationOutcome.appliedMigrationNames, ["add_sound_kind"])

        let kept = try XCTUnwrap(try store.sounds.sound(withID: existing.id))
        XCTAssertEqual(kept.name, "Made Before")
        XCTAssertEqual(kept.kind, .synth, "A row written before the column reads as a patch")
        XCTAssertEqual(kept.synthPatch, existing.synthPatch)
    }

    /// Reverting this build leaves the store openable, which is the issue's
    /// rollback clause.
    ///
    /// The forward-only migrator refuses the older chain by name and version
    /// and touches nothing, so rolling forward again recovers everything — and
    /// a variant row that an older build could not decode would be reported by
    /// name rather than silently dropped.
    func testAnEarlierBuildRefusesThisStoreLoudlyWithoutDamagingIt() throws {
        _ = try store.sounds.create(patch: .defaultVoice, named: "Kept", in: .keys)
        store.close()

        let database = try SQLiteDatabase.open(at: container.databaseURL)
        defer { database.close() }

        XCTAssertThrowsError(
            try SchemaMigrator.migrate(
                database, appVersion: "0.9 (1)",
                migrations: Array(SchemaMigrator.migrations.prefix(6))
            )
        ) { error in
            guard case StoreError.storeWrittenByNewerApp(let stored, let supported) = error else {
                return XCTFail("Expected storeWrittenByNewerApp, got \(error)")
            }
            XCTAssertEqual(stored, 7)
            XCTAssertEqual(supported, 6)
        }

        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM sounds;"), 1)
        store = try LibraryStore.open(container: container, appVersion: "test")
        XCTAssertEqual(try store.sounds.userSoundCount(), 1)
    }

    /// A variant row this build cannot decode is a loud failure, not a sound
    /// that quietly stops existing — the rule `SoundCatalog` already holds for
    /// patches, now holding for both kinds.
    func testAVariantRowThisBuildCannotReadIsReportedByNameRatherThanDropped() throws {
        let cello = try installFixtureLibrary()
        let saved = try store.sounds.createVariant(
            InstrumentVariant.asRecorded(cello), named: "Corrupt Me"
        )

        try store.database.execute(
            "UPDATE sounds SET document = ? WHERE id = ?;",
            [.text("{ not json at all"), .text(saved.id)]
        )

        XCTAssertThrowsError(try store.sounds.allSounds()) { error in
            guard case StoreError.soundRowUnreadable(let id, _) = error else {
                return XCTFail("Expected soundRowUnreadable, got \(error)")
            }
            XCTAssertEqual(id, saved.id)
        }
    }

    // MARK: Fixtures

    private func importFixturePiece() throws -> PieceRecord {
        let source = directory.appending(path: "fixture.musicxml")
        try MusicXMLScoreFixtures.keyboardFugueExposition().write(to: source)
        return try store.makeImporter().importPiece(from: source).piece
    }

    private func compile(_ piece: PieceRecord) throws -> CompiledScore {
        try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)
    }
}
