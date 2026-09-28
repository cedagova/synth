import XCTest
@testable import Synth
import SynthKit

/// `SoundStudioModel` directly: create, duplicate, rename, file, delete, search
/// and keyboard selection, the hand-off to the right editor, and what the owner
/// is told when the library refuses a write (issue #99).
@MainActor
final class SoundStudioModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var studio: SoundStudioModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        let editor = SoundEditorModel(
            store: library.store, playbackChannel: SynthPatchLiveVoices(patch: .defaultVoice)
        )
        studio = SoundStudioModel(
            store: library.store,
            editor: editor,
            instrumentEditor: InstrumentEditorModel(store: library.store)
        )
        studio.reload()
    }

    override func tearDown() async throws {
        studio?.editor.suspend()
        studio = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private var sounds: SoundLibrary { library.store.sounds }

    private func selectUserSound(named name: String = "Mine") throws -> SoundEntry {
        let entry = try sounds.create(patch: .newSound(), named: name, in: .keys)
        studio.reload()
        studio.selection = entry.id
        return entry
    }

    // MARK: Loading

    func testTheShippedCollectionIsListedAndSomethingIsSelected() {
        XCTAssertGreaterThan(studio.shippedSoundCount, 0)
        XCTAssertEqual(studio.userSoundCount, 0)
        XCTAssertNotNil(studio.selection, "A list with nothing selected has no keyboard target")
        XCTAssertEqual(studio.editor.entry?.id, studio.selection, "The selection is in the editor")
        XCTAssertNil(studio.alert)
    }

    // MARK: Creating and copying

    func testCreatingASoundSelectsItWithAUniqueName() throws {
        studio.createSound()
        let first = try XCTUnwrap(studio.selectedSound)
        XCTAssertEqual(first.name, "New Sound")
        XCTAssertEqual(first.origin, .user)
        XCTAssertEqual(studio.editor.entry?.id, first.id, "…and open, ready to be heard")

        studio.createSound()
        XCTAssertEqual(studio.selectedSound?.name, "New Sound 2")
        XCTAssertEqual(try sounds.userSoundCount(), 2)
    }

    /// The failure path: the library refuses the insert, the alert names what
    /// was attempted, and nothing was added.
    func testACreateTheLibraryRefusesRaisesAnAlert() throws {
        try library.failWrites(.insert, on: SoundCatalog.tableName)
        studio.createSound()

        XCTAssertEqual(studio.alert?.title, "Could not create a sound")
        XCTAssertEqual(try sounds.userSoundCount(), 0)
        XCTAssertEqual(studio.userSoundCount, 0)
    }

    func testDuplicatingAShippedSoundMakesTheOwnersCopy() throws {
        let shipped = try XCTUnwrap(studio.sounds.first { $0.origin == .shipped && $0.kind == .synth })
        studio.selection = shipped.id

        studio.duplicateSelected()

        let copy = try XCTUnwrap(studio.selectedSound)
        XCTAssertNotEqual(copy.id, shipped.id)
        XCTAssertEqual(copy.origin, .user)
        XCTAssertTrue(studio.statusMessage?.contains("The original is unchanged") == true)
    }

    // MARK: Renaming and filing

    func testRenamingAUserSound() throws {
        let entry = try selectUserSound()
        studio.beginRename()
        XCTAssertEqual(studio.renameText, "Mine")
        studio.renameText = "Glassy"
        studio.commitRename()

        XCTAssertNil(studio.renaming)
        XCTAssertEqual(studio.selectedSound?.name, "Glassy")
        XCTAssertEqual(try sounds.sound(withID: entry.id)?.name, "Glassy")
        XCTAssertEqual(studio.editor.title, "Glassy", "The editor's heading follows")
        XCTAssertEqual(studio.statusMessage, "Renamed “Mine” to “Glassy”.")
    }

    func testAnEmptyNameIsRefusedWithAnAlert() throws {
        let entry = try selectUserSound()
        studio.beginRename()
        studio.renameText = "   "
        studio.commitRename()

        XCTAssertEqual(studio.alert?.title, "Could not rename “Mine”")
        XCTAssertEqual(try sounds.sound(withID: entry.id)?.name, "Mine")
    }

    func testCancellingARenameWritesNothing() throws {
        let entry = try selectUserSound()
        studio.beginRename()
        studio.renameText = "Other"
        studio.cancelRename()

        XCTAssertNil(studio.renaming)
        XCTAssertEqual(try sounds.sound(withID: entry.id)?.name, "Mine")
    }

    func testAShippedSoundCannotBeRenamed() throws {
        let shipped = try XCTUnwrap(studio.sounds.first { $0.origin == .shipped })
        studio.selection = shipped.id
        studio.beginRename()

        XCTAssertNil(studio.renaming)
        XCTAssertEqual(studio.alert?.title, "“\(shipped.name)” cannot be renamed")
    }

    func testRefilingAUserSound() throws {
        let entry = try selectUserSound()
        studio.recategorizeSelected(to: .pads)

        XCTAssertEqual(try sounds.sound(withID: entry.id)?.category, .pads)
        XCTAssertEqual(studio.selection, entry.id, "The row keeps its identity")
        XCTAssertEqual(studio.statusMessage, "Moved “Mine” to \(SoundCategory.pads.displayName).")
    }

    func testARefileTheLibraryRefusesRaisesAnAlert() throws {
        let entry = try selectUserSound()
        try library.failWrites(.update, on: SoundCatalog.tableName)

        studio.recategorizeSelected(to: .pads)

        XCTAssertEqual(studio.alert?.title, "Could not move “Mine”")
        XCTAssertEqual(try sounds.sound(withID: entry.id)?.category, .keys)
    }

    // MARK: Deleting (REQ-029)

    func testDeletingAnUnusedSoundAsksThenDeletes() throws {
        let entry = try selectUserSound()
        studio.requestDeletionOfSelection()

        XCTAssertEqual(studio.pendingDeletion?.id, entry.id)
        XCTAssertTrue(studio.pendingDeletionWarning.contains("No preset is using it"))

        studio.confirmDeletion(of: entry)

        XCTAssertNil(studio.pendingDeletion)
        XCTAssertNil(try sounds.sound(withID: entry.id))
        XCTAssertNotEqual(studio.selection, entry.id, "The selection moves off a deleted sound")
        XCTAssertEqual(studio.statusMessage, "Deleted “Mine”.")
    }

    func testCancellingADeletionKeepsTheSound() throws {
        let entry = try selectUserSound()
        studio.requestDeletionOfSelection()
        studio.cancelDeletion()

        XCTAssertNil(studio.pendingDeletion)
        XCTAssertNotNil(try sounds.sound(withID: entry.id))
    }

    func testADeleteTheLibraryRefusesRaisesAnAlertAndKeepsTheSound() throws {
        let entry = try selectUserSound()
        studio.requestDeletionOfSelection()
        try library.failWrites(.delete, on: SoundCatalog.tableName)

        studio.confirmDeletion(of: entry)

        XCTAssertEqual(studio.alert?.title, "Could not delete “Mine”")
        XCTAssertNotNil(try sounds.sound(withID: entry.id))
    }

    func testAShippedSoundCannotBeDeleted() throws {
        let shipped = try XCTUnwrap(studio.sounds.first { $0.origin == .shipped })
        studio.selection = shipped.id
        studio.requestDeletionOfSelection()

        XCTAssertNil(studio.pendingDeletion)
        XCTAssertEqual(studio.alert?.title, "“\(shipped.name)” cannot be deleted")
    }

    // MARK: Search and keyboard selection

    func testSearchNarrowsAndKeepsASelectionOnScreen() throws {
        _ = try selectUserSound(named: "Zebra Keys")
        studio.searchText = "zebra"

        XCTAssertEqual(studio.visibleSounds.map(\.name), ["Zebra Keys"])
        XCTAssertEqual(studio.selectedSound?.name, "Zebra Keys")
        XCTAssertTrue(studio.countDescription.hasPrefix("1 of "))

        studio.searchText = "no sound is called this"
        XCTAssertTrue(studio.isSearchEmpty)
        XCTAssertNil(studio.selection)

        studio.clearSearch()
        XCTAssertNotNil(studio.selection)
    }

    func testKeyboardSelectionWalksTheVisibleList() {
        let shown = studio.visibleSounds
        studio.selection = shown.first?.id
        let focus = studio.listFocusRequests

        studio.selectNextSound()
        XCTAssertEqual(studio.selection, shown[1].id)
        studio.selectPreviousSound()
        studio.selectPreviousSound()
        XCTAssertEqual(studio.selection, shown[0].id, "Stops at the top")
        XCTAssertEqual(studio.listFocusRequests, focus + 3)
    }

    // MARK: The two editors and named variants

    func testAnInstrumentSelectionOpensTheInstrumentEditorAndSavesAVariant() throws {
        try library.installFixtureCello()
        studio.reload()
        let cello = try XCTUnwrap(studio.sounds.first { $0.origin == .instrument })

        studio.selection = cello.id

        XCTAssertTrue(studio.isEditingInstrument)
        XCTAssertEqual(studio.instrumentEditor.entry?.id, cello.id)
        XCTAssertFalse(studio.editor.isOpen, "Only one editor is open at a time")

        studio.beginVariantNaming()
        XCTAssertTrue(studio.isNamingVariant)
        studio.variantNameDraft = "Dark Cello"
        studio.commitVariantNaming()

        let variant = try XCTUnwrap(studio.selectedSound)
        XCTAssertEqual(variant.name, "Dark Cello")
        XCTAssertEqual(variant.origin, .user)
        XCTAssertEqual(studio.variantCount, 1)
    }

    func testRevealingASoundClearsTheSearchAndSelectsIt() throws {
        let entry = try sounds.create(patch: .newSound(), named: "Hidden", in: .keys)
        studio.searchText = "nothing matches"

        XCTAssertEqual(studio.reveal(soundID: entry.id)?.id, entry.id)
        XCTAssertEqual(studio.searchText, "")
        XCTAssertEqual(studio.selection, entry.id)
        XCTAssertNil(studio.reveal(soundID: "no-such-sound"))
    }

    func testAnEditorSaveIsFoldedBackIntoTheList() throws {
        let entry = try selectUserSound()
        let current = studio.editor.value(for: .filterCutoff)?.numberValue ?? 1_000
        studio.editor.setValue(.number(current == 2_345 ? 3_456 : 2_345), for: .filterCutoff)
        studio.editor.save()

        XCTAssertEqual(studio.statusMessage, "Saved “Mine”.")
        XCTAssertGreaterThan(
            try XCTUnwrap(studio.sounds.first { $0.id == entry.id }).revision, entry.revision
        )
    }
}
