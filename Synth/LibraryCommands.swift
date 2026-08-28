import SwiftUI
import SynthKit

/// Menu commands for the library.
///
/// Real menu items rather than invisible key handlers, for three reasons: they
/// are what macOS keyboard shortcuts are actually made of, they are
/// discoverable in the menu bar, and VoiceOver reads them like any other menu.
/// REQ-027's "fully keyboard-operable" is satisfied here as much as it is in
/// the window.
///
/// **Nothing here is `.disabled`, deliberately.** A `Commands` body is
/// evaluated when the scene is built — before `bootstrap()` has opened the
/// store — and it is not re-evaluated when the model changes afterwards. A
/// condition such as `.disabled(model.library == nil)` therefore latches on at
/// launch and never clears, leaving every shortcut permanently dead. That was
/// observed directly: with the disabling in place, every item reported
/// `enabled=NO` after the library had loaded and none of the shortcuts did
/// anything.
///
/// Availability lives where it can be trusted instead: the window's own
/// controls disable correctly because they are ordinary views, and every model
/// action below already refuses to act when it does not apply — removal
/// without a selection does nothing, and it still requires confirmation when
/// there is one.
struct LibraryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Pieces…") {
                model.library?.beginImport()
            }
            .keyboardShortcut("i", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Remove Selected Piece…") {
                model.library?.requestRemovalOfSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Library") {
                model.library?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Clear Search") {
                model.library?.clearSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu("Library") {
            // Reaching the list without a pointer. SwiftUI's own arrow-key
            // navigation takes over once a row is selected, but nothing gets
            // you *into* the list from the search field unless Full Keyboard
            // Access is on; these commands always do (REQ-027).
            Button("Select Next Piece") {
                model.library?.selectNextPiece()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button("Select Previous Piece") {
                model.library?.selectPreviousPiece()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Divider()

            ForEach(LibrarySortField.allCases) { field in
                Button("Sort by \(field.label)") {
                    model.library?.sortBy(field)
                }
            }

            Divider()

            Button("Reverse Sort Order") {
                model.library?.toggleSortDirection()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}
