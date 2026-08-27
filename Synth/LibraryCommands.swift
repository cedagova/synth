import SwiftUI
import SynthKit

/// Menu commands for the library.
///
/// Real menu items rather than invisible key handlers, for three reasons: they
/// are what macOS keyboard shortcuts are actually made of, they are discoverable
/// in the menu bar, and VoiceOver reads them like any other menu. REQ-027's
/// "fully keyboard-operable" is satisfied here as much as it is in the window.
struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Pieces…") {
                model.library?.beginImport()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(model.library == nil || model.library?.isWorking == true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Remove Selected Piece…") {
                model.library?.requestRemovalOfSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.library?.selectedPiece == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Library") {
                model.library?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.library == nil || model.library?.isLibraryEmpty == true)

            Button("Clear Search") {
                model.library?.clearSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.library?.searchText.isEmpty != false)
        }

        CommandMenu("Library") {
            ForEach(LibrarySortField.allCases) { field in
                Button(sortLabel(for: field)) {
                    model.library?.sortBy(field)
                }
                .disabled(model.library?.isLibraryEmpty != false)
            }

            Divider()

            Button("Reverse Sort Order") {
                model.library?.toggleSortDirection()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model.library?.isLibraryEmpty != false)
        }
    }

    /// A checkmark would be the native affordance, but `Button` in a
    /// `CommandMenu` has no selected state; naming the active field in the item
    /// itself keeps the current ordering readable from the keyboard and to
    /// VoiceOver.
    private func sortLabel(for field: LibrarySortField) -> String {
        guard model.library?.sort.field == field else {
            return "Sort by \(field.label)"
        }
        return "Sort by \(field.label) ✓"
    }
}
