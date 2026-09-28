import XCTest
@testable import Synth
import SynthKit

/// `InstrumentEditorModel` directly: measuring an installed instrument,
/// customizing it, Save as Variant, editing and saving a variant, revert and
/// reset, the gate on an instrument that is not downloaded, and what the owner
/// is told when the library refuses a write (issue #99).
///
/// The instrument is a real catalog entry installed with placeholder samples
/// into the temporary container — the technique `AppModelWiringTests` uses —
/// so the capability gate measures real files. Nothing here renders audio.
@MainActor
final class InstrumentEditorModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var editor: InstrumentEditorModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        editor = InstrumentEditorModel(store: library.store)
    }

    override func tearDown() async throws {
        editor = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private var sounds: SoundLibrary { library.store.sounds }

    private func installedCello() throws -> SoundEntry {
        try library.installFixtureCello()
        return try XCTUnwrap(sounds.installedInstrumentSounds().first)
    }

    private func celloVariant(named name: String = "Warm Cello") throws -> SoundEntry {
        let reference = try library.installFixtureCello()
        return try sounds.createVariant(InstrumentVariant(reference: reference), named: name)
    }

    // MARK: Opening

    func testNothingIsOpenToBeginWith() {
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.title, "No instrument selected")
        XCTAssertFalse(editor.isSupported(.toneLow), "No measurement is never permission")
    }

    func testAnInstalledInstrumentIsMeasuredAndReadOnly() throws {
        let cello = try installedCello()
        editor.load(cello)

        XCTAssertTrue(editor.isOpen)
        XCTAssertTrue(editor.isInstalledInstrument)
        XCTAssertFalse(editor.isEditable, "A downloaded instrument's only write is Save as Variant")
        XCTAssertNotNil(editor.capabilities)
        XCTAssertNil(editor.unavailableExplanation)
        XCTAssertTrue(editor.isSupported(.toneLow))
        XCTAssertNil(editor.alert)
    }

    func testASynthSoundClosesTheEditor() throws {
        editor.load(try installedCello())
        let synth = try XCTUnwrap(sounds.shippedSounds.first { $0.kind == .synth })

        editor.load(synth)

        XCTAssertFalse(editor.isOpen, "A synth patch belongs to the other editor")
        XCTAssertNil(editor.capabilities)
    }

    /// An instrument that is not downloaded has nothing to measure, so every
    /// control is inert and the owner is told why.
    func testAVariantOfAnInstrumentThatIsNotDownloadedIsInert() throws {
        let catalog = try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        let coverage = try XCTUnwrap(
            catalog.coverage.first { $0.identifier == "vsco2.cello.section" }
        )
        let variant = try sounds.createVariant(
            InstrumentVariant(reference: InstrumentReference(library: catalog, coverage: coverage)),
            named: "Orphan"
        )

        editor.load(variant)
        let before = editor.variant
        editor.setValue(-6, for: .toneLow)

        XCTAssertNotNil(editor.unavailableExplanation)
        XCTAssertFalse(editor.isSupported(.toneLow))
        XCTAssertEqual(editor.variant, before, "An unsupported control is refused, not faked")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    // MARK: Customizing an installed instrument

    func testCustomizingAnInstalledInstrumentIsAPreviewThatPublishesNothing() throws {
        var published = 0
        editor.onVariantEdited = { _, _ in published += 1 }
        editor.load(try installedCello())

        editor.setValue(-6, for: .toneLow)

        XCTAssertEqual(editor.value(for: .toneLow), -6, accuracy: 0.001)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(published, 0, "No line plays the downloaded instrument's own row")
        XCTAssertTrue(editor.suggestedVariantName().hasPrefix(editor.variant!.reference.instrumentName))
    }

    func testSavingAsAVariantCreatesTheOwnersSound() throws {
        let cello = try installedCello()
        var saved: [SoundEntry] = []
        editor.onSaved = { saved.append($0) }
        editor.load(cello)
        editor.setValue(-6, for: .toneLow)

        let created = try XCTUnwrap(editor.saveAsVariant(named: "Dark Cello"))

        XCTAssertEqual(created.origin, .user)
        XCTAssertEqual(saved.map(\.id), [created.id])
        let stored = try XCTUnwrap(sounds.sound(withID: created.id)?.instrumentVariant)
        XCTAssertEqual(stored.customization.toneLowDecibels, -6, accuracy: 0.001)
        XCTAssertTrue(editor.statusMessage?.hasPrefix("Saved “Dark Cello”") == true)
    }

    /// A failure path: the library refuses an empty name and nothing is made.
    func testAVariantWithNoNameIsRefusedWithAnAlert() throws {
        editor.load(try installedCello())

        XCTAssertNil(editor.saveAsVariant(named: "  "))
        XCTAssertEqual(editor.alert?.title, "Could not save “  ”")
        XCTAssertEqual(try sounds.userSoundCount(), 0)
    }

    func testResetGoesBackToTheInstrumentAsRecorded() throws {
        editor.load(try installedCello())
        editor.setValue(-6, for: .toneLow)

        editor.resetToRecorded()

        XCTAssertTrue(try XCTUnwrap(editor.variant).customization.isAsRecorded)
        XCTAssertNotNil(editor.statusMessage)
    }

    // MARK: Editing the owner's variant

    func testEditingAVariantReachesTheOpenPieceAndSaves() throws {
        let variant = try celloVariant()
        var published: [String] = []
        var saved: [SoundEntry] = []
        editor.onVariantEdited = { id, _ in published.append(id) }
        editor.onSaved = { saved.append($0) }
        editor.load(variant)
        XCTAssertTrue(editor.isEditable)

        editor.setValue(4, for: .toneHigh)
        XCTAssertEqual(published.last, variant.id, "Lines playing this variant hear it")
        XCTAssertTrue(editor.hasUnsavedChanges)

        editor.save()

        XCTAssertNil(editor.alert)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(saved.map(\.id), [variant.id])
        XCTAssertEqual(
            try XCTUnwrap(sounds.sound(withID: variant.id)?.instrumentVariant)
                .customization.toneHighDecibels,
            4, accuracy: 0.001
        )
    }

    func testRevertGoesBackToTheStoredVariant() throws {
        editor.load(try celloVariant())
        let saved = editor.savedVariant
        editor.setValue(4, for: .toneHigh)

        editor.revert()

        XCTAssertEqual(editor.variant, saved)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.statusMessage, "Reverted “Warm Cello” to the saved version.")
    }

    /// The failure path: the library refuses the save, the owner is told, and
    /// the unsaved edit is kept.
    func testASaveTheLibraryRefusesRaisesAnAlertAndKeepsTheEdit() throws {
        let variant = try celloVariant()
        editor.load(variant)
        editor.setValue(4, for: .toneHigh)
        try library.failWrites(.update, on: SoundCatalog.tableName)

        editor.save()

        XCTAssertEqual(editor.alert?.title, "Could not save “Warm Cello”")
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(
            try XCTUnwrap(sounds.sound(withID: variant.id)?.instrumentVariant)
                .customization.toneHighDecibels,
            variant.instrumentVariant?.customization.toneHighDecibels
        )
    }

    func testWalkingAwayFromAnUnsavedEditPutsThePieceBack() throws {
        let variant = try celloVariant()
        var published: [(String, InstrumentVariant)] = []
        editor.onVariantEdited = { published.append(($0, $1)) }
        editor.load(variant)
        let stored = try XCTUnwrap(editor.savedVariant)
        editor.setValue(4, for: .toneHigh)

        editor.close()

        XCTAssertEqual(published.last?.0, variant.id)
        XCTAssertEqual(published.last?.1, stored)
        XCTAssertFalse(editor.isOpen)
    }
}
