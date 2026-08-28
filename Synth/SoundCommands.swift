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
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Delete Sound…") {
                model.studio?.requestDeletionOfSelection()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])

            Divider()

            Button("Save Sound") {
                model.studio?.editor.save()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Revert Sound") {
                model.studio?.editor.revert()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider()

            // Reaching the list without a pointer. SwiftUI's arrow-key
            // navigation takes over once a row is selected, but nothing gets
            // you into the list from the search field unless Full Keyboard
            // Access is on; these always do (REQ-027).
            Button("Select Next Sound") {
                model.studio?.selectNextSound()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Button("Select Previous Sound") {
                model.studio?.selectPreviousSound()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Find in Sounds") {
                model.studio?.requestSearchFocus()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button("Play Test Chord") {
                model.studio?.editor.playTestChord()
            }
            .keyboardShortcut("t", modifiers: .command)

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
