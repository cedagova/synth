import SwiftUI
import SynthKit

/// Menu commands for the instrument catalog.
///
/// Real menu items, for the reasons `LibraryCommands` and `SoundCommands`
/// state: they are what macOS keyboard shortcuts are made of, they are
/// discoverable, and VoiceOver reads them like any other menu (REQ-027).
///
/// **Nothing here is `.disabled`,** for the reason LIB003 found by running the
/// app: a `Commands` body is evaluated once when the scene is built, before the
/// store has been opened, and is not re-evaluated — so a condition such as
/// `.disabled(model.instrumentCatalog == nil)` latches on at launch and leaves
/// every shortcut permanently dead. Availability lives on the screen's own
/// controls, and every action below already refuses to act when it does not
/// apply.
///
/// **No shortcut here uses Shift, and every one avoids a combination already in
/// the bar.** AppKit matches a key equivalent loosely across Shift, and the
/// Instruments menu is the last one, so it loses every collision silently — the
/// item stays in the menu, looks enabled, and its key never arrives. Option and
/// Control are matched exactly, so the pairs below are checked against the whole
/// live menu bar rather than against memory.
struct InstrumentCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Instruments") {
            Button("Instrument Catalog") {
                model.openInstrumentCatalog()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Download or Remove Selected Library") {
                model.instrumentCatalog?.performPrimaryActionOnSelection()
            }
            .keyboardShortcut("g", modifiers: [.command, .option])

            Button("Show Licence and Credits…") {
                model.instrumentCatalog?.showLicenceForSelection()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Divider()

            Button("Download Everything") {
                model.instrumentCatalog?.downloadEverythingNotYetInstalled()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button("Pause All Downloads") {
                model.instrumentCatalog?.pauseEverything()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            // Reaching the list without a pointer. SwiftUI's arrow-key
            // navigation takes over once a row is selected, but nothing gets
            // you into the list otherwise unless Full Keyboard Access is on;
            // these always do (REQ-027). Option rather than Control here
            // because ⌃⌘↑/↓ are the Sounds menu's, and n/b rather than the
            // arrows because ⌥⌘↑ is Playback's Go to Start.
            Button("Select Next Library") {
                model.instrumentCatalog?.selectNextLibrary()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Select Previous Library") {
                model.instrumentCatalog?.selectPreviousLibrary()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}
