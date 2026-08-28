import SwiftUI
import SynthKit

/// Menu commands for the assignment and mixing surface (REQ-027).
///
/// **Every one of these is reachable without a pointer, and every one of them
/// is also an on-screen control.** The menu exists for the gap SwiftUI leaves:
/// arrow keys move between strips only once a strip has focus, and nothing puts
/// focus there in the first place unless Full Keyboard Access is on. That is the
/// same gap the piece library and the sound studio both had to close.
///
/// **Nothing here is `.disabled`**, for the reason `LibraryCommands` records: a
/// `Commands` body is evaluated once when the scene is built, so any condition
/// latches at launch and never clears. Every action below already refuses to act
/// when it does not apply.
///
/// **No shortcut here uses Shift, and none of them is a bare Command letter.**
/// AppKit matches a key equivalent loosely across Shift and takes the first
/// matching item in menu-bar order, which silently killed five of the sound
/// studio's shortcuts in SYN003. Control-Command is used throughout because it
/// collides with nothing in the Playback, Sounds or Library menus, and the two
/// arrow shortcuts are Control-Command left and right, which the Sounds menu's
/// Control-Command up and down leave free.
struct MixCommands: Commands {
    let model: AppModel

    private var assignment: AssignmentModel? { model.playback?.assignment }

    var body: some Commands {
        CommandMenu("Mix") {
            Button("Next Line") { assignment?.selectNextLine() }
                .keyboardShortcut("n", modifiers: [.command, .control])

            Button("Previous Line") { assignment?.selectPreviousLine() }
                .keyboardShortcut("b", modifiers: [.command, .control])

            Divider()

            // Focuses the field rather than acting, because the name has to be
            // typed. The field takes focus itself when it appears, so the whole
            // rename happens from the keyboard.
            Button("Rename Line…") { assignment?.beginRenameOfSelectedLine() }
                .keyboardShortcut("e", modifiers: [.command, .control])

            Button("Mute Line") { assignment?.toggleMuteOnSelectedLine() }
                .keyboardShortcut("m", modifiers: [.command, .control])

            Button("Solo Line") { assignment?.toggleSoloOnSelectedLine() }
                .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            Button("Line Louder") {
                assignment?.nudgeVolumeOnSelectedLine(byDecibels: AssignmentDisplay.decibelStep)
            }
            .keyboardShortcut("u", modifiers: [.command, .control])

            Button("Line Quieter") {
                assignment?.nudgeVolumeOnSelectedLine(byDecibels: -AssignmentDisplay.decibelStep)
            }
            .keyboardShortcut("j", modifiers: [.command, .control])

            Button("Pan Line Left") {
                assignment?.nudgePanOnSelectedLine(by: -AssignmentDisplay.panStep)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])

            Button("Pan Line Right") {
                assignment?.nudgePanOnSelectedLine(by: AssignmentDisplay.panStep)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])

            Button("Centre Line Pan") { assignment?.centrePanOnSelectedLine() }
                .keyboardShortcut("0", modifiers: [.command, .control])

            Divider()

            Button("New Preset") { assignment?.createPreset() }
                .keyboardShortcut("p", modifiers: [.command, .control])

            Button("Rename Preset…") { assignment?.beginPresetRename() }
                .keyboardShortcut("y", modifiers: [.command, .control])

            Button("Next Preset") { assignment?.activateNextPreset() }
                .keyboardShortcut("v", modifiers: [.command, .control])

            Button("Delete Preset…") { assignment?.requestPresetDeletion() }
                .keyboardShortcut(.delete, modifiers: [.command, .control])
        }
    }
}
