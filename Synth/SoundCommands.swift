import SwiftUI
import SynthKit

/// Menu commands for the sound studio.
///
/// Real menu items, for the reasons `LibraryCommands` states: they are what
/// macOS keyboard shortcuts are made of, they are discoverable, and VoiceOver
/// reads them like any other menu.
///
/// **Nothing here is `.disabled`,** for the reason LIB003 found by running the
/// app: a `Commands` body is evaluated when the scene is built, before the
/// store has been opened, and is not re-evaluated afterwards — so a condition
/// such as `.disabled(model.studio == nil)` latches on at launch and leaves
/// every shortcut permanently dead. Availability lives on the window's own
/// controls, which are ordinary views and update correctly, and every model
/// action below already refuses to act when it does not apply.
///
/// **Every shortcut here avoids one already spoken for.** The Sounds menu is
/// the last one in the bar, so it loses every collision silently: the item
/// stays in the menu, looks enabled, and its key simply never arrives. Driving
/// the running app found four of these — ⇧⌘R behind Playback's Show Notation
/// Report, ⌘T behind Go to Time, ⇧⌘Z behind Redo (SwiftUI dropped the key
/// entirely rather than register it), and ⌥⌘↑ behind Go to Start. One of them
/// was worse than dead: ⇧⌘⌫ was consumed by Edit's ⌘⌫ Remove Selected Piece,
/// because AppKit matches the delete character loosely across Shift, so
/// pressing it in the studio armed a *piece* removal that would surface the
/// next time the owner went back to the library. `menu-bar.txt` in the smoke
/// evidence is the dump this set was checked against.
struct SoundCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Sounds") {
            Button("Sound Studio") {
                model.openSoundStudio()
            }
            .keyboardShortcut("d", modifiers: .command)

            Divider()

            Button("New Sound") {
                model.studio?.createSound()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Duplicate Sound") {
                model.studio?.duplicateSelected()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Rename Sound…") {
                model.studio?.beginRename()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Delete Sound…") {
                model.studio?.requestDeletionOfSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])

            Divider()

            Button("Save Sound") {
                model.studio?.editor.save()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Revert Sound") {
                model.studio?.editor.revert()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])

            Divider()

            // Reaching the list without a pointer. SwiftUI's arrow-key
            // navigation takes over once a row is selected, but nothing gets
            // you into the list from the search field unless Full Keyboard
            // Access is on; these always do (REQ-027).
            Button("Select Next Sound") {
                model.studio?.selectNextSound()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])

            Button("Select Previous Sound") {
                model.studio?.selectPreviousSound()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

            Button("Find in Sounds") {
                model.studio?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button("Play Test Chord") {
                model.studio?.editor.playTestChord()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button("All Test Notes Off") {
                model.studio?.editor.releaseEverything()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Play the Open Piece Through This Sound") {
                model.studio?.editor.togglePlayingPieceThroughSound()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
