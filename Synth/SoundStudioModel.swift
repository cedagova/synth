import Foundation
import Observation
import SynthKit

/// A failure the sound library has to put in front of the owner.
///
/// The same shape as `LibraryAlert`, and for the same reason: a headline and an
/// optional recovery line are exactly what an alert has room for, and
/// `SoundLibraryError` already writes both. The UI never invents wording for a
/// failure the model layer has already described.
struct SoundAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: String?

    init(title: String, message: String, recovery: String?) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }

    init(title: String, _ error: Error) {
        self.title = title
        self.message = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        self.recovery = (error as? LocalizedError)?.recoverySuggestion
    }
}

/// The sound library surface: what sounds exist, which one is being looked at,
/// and everything that creates, copies, renames, files or deletes one.
///
/// **Reads and writes run on the main actor, deliberately.** The piece library
/// pushes its work off-actor because importing a score parses XML and can take
/// a second; a sound is a few hundred numbers, the collection is the shipped
/// thirteen plus however many the owner has made, and every operation here is
/// one small SQLite transaction. Making them `async` would add a suspension
/// point between "the owner pressed Duplicate" and "the list changed" for no
/// gain, and would open a window where a second press duplicates twice.
///
/// The editor is a separate model that this one owns. Selecting a row hands it
/// a sound; saving hands the result back here. Nothing else passes between
/// them, which is what keeps "which sound is selected" and "what is being
/// edited" from having to agree by accident.
@Observable
@MainActor
final class SoundStudioModel {
    private let library: SoundLibrary

    /// Every sound in the library, shipped and the owner's, in list order.
    private(set) var sounds: [SoundEntry] = []

    /// Which sound the list has selected, by identity.
    ///
    /// Identity rather than index, because SYN002 guarantees an id survives a
    /// rename and a re-categorisation — both of which move a row.
    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            loadSelectionIntoEditor()
        }
    }

    /// Substring the owner is looking for. Matches name and category.
    var searchText = "" {
        didSet { if searchText != oldValue { keepSelectionVisible() } }
    }

    /// The last thing that happened, for the status line.
    private(set) var statusMessage: String?

    var alert: SoundAlert?

    /// The sound a delete is waiting for confirmation on.
    private(set) var pendingDeletion: SoundEntry?

    /// The sound being renamed, and the name being typed.
    private(set) var renaming: SoundEntry?
    var renameText = ""

    /// The editor. Always present: an empty editor is a real state, and a
    /// screen that had to cope with `nil` would be a worse one.
    let editor: SoundEditorModel

    /// Bumped so the screen can move keyboard focus where a menu command asked
    /// for it — the same mechanism the piece library uses for Find.
    private(set) var searchFocusRequests = 0
    private(set) var listFocusRequests = 0

    init(store: LibraryStore, editor: SoundEditorModel) {
        self.library = store.sounds
        self.editor = editor
        editor.onSaved = { [weak self] entry in self?.absorbSavedSound(entry) }
    }

    // MARK: Derived state

    /// The sounds the list is showing, after the search.
    var visibleSounds: [SoundEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sounds }
        return sounds.filter { entry in
            entry.name.localizedCaseInsensitiveContains(query)
                || entry.category.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    /// The visible sounds under their category headings, in list order. Empty
    /// categories are left out rather than shown as empty rows.
    var visibleByCategory: [(category: SoundCategory, sounds: [SoundEntry])] {
        let shown = visibleSounds
        return SoundCategory.allCases.compactMap { category in
            let members = shown.filter { $0.category == category }
            return members.isEmpty ? nil : (category, members)
        }
    }

    var selectedSound: SoundEntry? {
        guard let selection else { return nil }
        return sounds.first { $0.id == selection }
    }

    var isLibraryEmpty: Bool { sounds.isEmpty }
    var isSearchEmpty: Bool { !sounds.isEmpty && visibleSounds.isEmpty }

    var userSoundCount: Int { sounds.count { $0.origin == .user } }
    var shippedSoundCount: Int { sounds.count { $0.origin == .shipped } }

    /// "17 sounds", or "3 of 17 sounds" while a search is narrowing the list.
    var countDescription: String {
        let total = sounds.count
        let shown = visibleSounds.count
        let noun = total == 1 ? "sound" : "sounds"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }

    // MARK: Loading

    func reload() {
        do {
            sounds = try library.allSounds()
            keepSelectionVisible()
        } catch {
            alert = SoundAlert(title: "Could not read your sounds", error)
        }
    }

    /// Select something sensible after the list changes.
    ///
    /// A selection that has gone — deleted, or filtered out by a search — is
    /// replaced by the first thing on screen rather than left dangling, because
    /// a list with nothing selected has no keyboard target at all.
    private func keepSelectionVisible() {
        let shown = visibleSounds
        if let selection, shown.contains(where: { $0.id == selection }) { return }
        selection = shown.first?.id
    }

    private func loadSelectionIntoEditor() {
        guard let entry = selectedSound else { return editor.close() }
        editor.load(entry)
    }

    // MARK: Creating and copying

    /// REQ-017's "create from scratch". The new sound is selected and open in
    /// the editor, because the next thing the owner wants is to hear it.
    func createSound() {
        write("create a sound") {
            let entry = try library.create(
                patch: .newSound(), named: uniqueNewName(), in: .keys)
            reload()
            selection = entry.id
            statusMessage = "Created “\(entry.name)”. Press a key to hear it."
        }
    }

    /// REQ-017's duplicate, and its edit-as-copy for a shipped sound. Same
    /// operation either way — `SoundLibrary` says so, and this does not
    /// second-guess it.
    func duplicateSelected() {
        guard let entry = selectedSound else { return }
        duplicate(entry)
    }

    func duplicate(_ entry: SoundEntry) {
        write("duplicate “\(entry.name)”") {
            let copy = try library.makeEditableCopy(of: entry)
            reload()
            selection = copy.id
            statusMessage = entry.origin == .shipped
                ? "“\(entry.name)” is one of Synth's own sounds, so this is your copy of it: "
                    + "“\(copy.name)”. The original is unchanged."
                : "Duplicated “\(entry.name)” as “\(copy.name)”."
        }
    }

    // MARK: Renaming

    func beginRename() {
        guard let entry = selectedSound else { return }
        beginRename(of: entry)
    }

    func beginRename(of entry: SoundEntry) {
        guard entry.isEditable else { return refuseShipped(entry, verb: "renamed") }
        renaming = entry
        renameText = entry.name
    }

    func cancelRename() {
        renaming = nil
        renameText = ""
    }

    func commitRename() {
        guard let entry = renaming else { return }
        let requested = renameText
        renaming = nil
        renameText = ""
        guard requested.trimmingCharacters(in: .whitespacesAndNewlines) != entry.name else { return }

        write("rename “\(entry.name)”") {
            let renamed = try library.rename(entry, to: requested)
            reload()
            selection = renamed.id
            editor.adoptRenamed(renamed)
            statusMessage = "Renamed “\(entry.name)” to “\(renamed.name)”."
        }
    }

    // MARK: Filing

    func recategorizeSelected(to category: SoundCategory) {
        guard let entry = selectedSound else { return }
        guard entry.isEditable else { return refuseShipped(entry, verb: "filed somewhere else") }
        guard entry.category != category else { return }

        write("move “\(entry.name)”") {
            let moved = try library.recategorize(entry, to: category)
            reload()
            selection = moved.id
            editor.adoptRenamed(moved)
            statusMessage = "Moved “\(moved.name)” to \(category.displayName)."
        }
    }

    // MARK: Deleting

    func requestDeletionOfSelection() {
        guard let entry = selectedSound else { return }
        guard entry.isEditable else { return refuseShipped(entry, verb: "deleted") }
        pendingDeletion = entry
    }

    func cancelDeletion() { pendingDeletion = nil }

    func confirmDeletion(of entry: SoundEntry) {
        pendingDeletion = nil
        write("delete “\(entry.name)”") {
            try library.delete(entry)
            if editor.entry?.id == entry.id { editor.close() }
            reload()
            statusMessage = "Deleted “\(entry.name)”."
        }
    }

    // MARK: Keyboard navigation

    /// Reaching the list without a pointer.
    ///
    /// SwiftUI's own arrow-key navigation takes over once a row is selected,
    /// but nothing gets you *into* the list from the search field unless Full
    /// Keyboard Access is on. The piece library learned this the hard way in
    /// LIB003; these commands always work (REQ-027).
    func selectNextSound() { moveSelection(by: 1) }
    func selectPreviousSound() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        let shown = visibleSounds
        guard !shown.isEmpty else { return }
        guard let selection, let index = shown.firstIndex(where: { $0.id == selection }) else {
            self.selection = shown.first?.id
            listFocusRequests += 1
            return
        }
        let next = min(max(index + offset, 0), shown.count - 1)
        self.selection = shown[next].id
        listFocusRequests += 1
    }

    func requestSearchFocus() { searchFocusRequests += 1 }
    func clearSearch() { searchText = "" }

    // MARK: Internals

    /// Every write, in one shape: do it, and turn any failure into an alert
    /// that names what was being attempted.
    ///
    /// `SoundLibrary` guarantees the library is untouched when a write throws,
    /// so there is nothing to undo here — only something to say.
    private func write(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            alert = SoundAlert(title: "Could not \(what)", error)
        }
    }

    private func refuseShipped(_ entry: SoundEntry, verb: String) {
        alert = SoundAlert(
            title: "“\(entry.name)” cannot be \(verb)",
            message: "It is one of Synth's own sounds, and those stay as they are so every "
                + "Synth has the same starting collection.",
            recovery: "Duplicate it to get an editable copy of your own; the original is untouched."
        )
    }

    /// The sound the editor just saved, folded back into the list in place.
    ///
    /// No re-sort and no reload: the editor's save changes only the patch, and
    /// `SoundLibrary.update` keeps the row's name and category exactly as they
    /// were, so the row it replaces is still in the right place. A sound that
    /// somehow is not in the list at all — another window, a stale read — falls
    /// back to a full reload rather than being appended into the wrong order.
    private func absorbSavedSound(_ entry: SoundEntry) {
        if let index = sounds.firstIndex(where: { $0.id == entry.id }) {
            sounds[index] = entry
        } else {
            reload()
        }
        selection = entry.id
        statusMessage = "Saved “\(entry.name)”."
    }

    /// "New Sound", then "New Sound 2". Deterministic and non-colliding for the
    /// same reason `SoundLibrary`'s copy naming is: names are not keys here, so
    /// this exists to keep a list legible rather than to prevent a collision.
    private func uniqueNewName() -> String {
        let base = "New Sound"
        let taken = Set(sounds.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
