import SwiftUI
import SynthKit

/// Menu commands for the transport (REQ-027).
///
/// **Nothing here is `.disabled`, for the reason `LibraryCommands` records:** a
/// `Commands` body is evaluated once when the scene is built and is not
/// re-evaluated when the model changes, so any condition latches at launch and
/// never clears. Increment 001 shipped that bug and found it only by driving
/// the built app. Availability lives on the window's own controls, which are
/// ordinary views and update correctly, and every model action below already
/// refuses to act when it does not apply — pressing Play with no piece open is
/// a no-op, not a crash.
///
/// The one shortcut deliberately *not* used is Space. It is what a DAW binds
/// play/pause to, but a menu key equivalent is matched before the first
/// responder sees the key, so binding Space here would make it impossible to
/// type a space into the search field. Command-Return does the same job and
/// steals nothing.
struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Open Selected Piece") {
                model.openSelectedPieceForPlayback()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Back to Library") {
                model.closePlayback()
            }
            .keyboardShortcut("b", modifiers: .command)

            Divider()

            Button("Play / Pause") {
                model.playback?.togglePlayPause()
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("Stop") {
                model.playback?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)

            // Arrow keys with Command and Option. Two things ruled out the
            // obvious alternatives, both observed in the built app's own menu
            // bar rather than guessed: `.keyboardShortcut("[", …)` is stored as
            // `{`, so Command-bracket never matches it; and a plain Command
            // arrow would be taken from the seek fields, where it means
            // beginning and end of line.
            Button("Go to Start") {
                model.playback?.goToStart()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Skip Back 5 Seconds") {
                model.playback?.skip(byMicroseconds: -PlaybackModel.skipMicroseconds)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Skip Forward 5 Seconds") {
                model.playback?.skip(byMicroseconds: PlaybackModel.skipMicroseconds)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Divider()

            // These focus the field rather than acting, because the value has
            // to be typed. Reaching a text field is exactly what a keyboard-only
            // owner cannot otherwise do with Full Keyboard Access off.
            Button("Go to Measure…") {
                model.playback?.requestMeasureFocus()
            }
            .keyboardShortcut("g", modifiers: .command)

            // A different letter, not Shift-Command-G. Two menu items whose
            // shortcuts differ only by Shift are matched ambiguously: driving
            // the built app, Shift-Command-G either activated Go to Measure or
            // matched nothing at all, depending on which character the event
            // carried. Command-T is unused here and unambiguous.
            Button("Go to Time…") {
                model.playback?.requestTimeFocus()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Toggle Loop") {
                model.playback?.toggleLoop()
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

            Button("Toggle Humanization") {
                guard let playback = model.playback else { return }
                Task { await playback.setHumanizationEnabled(!playback.humanization.isEnabled) }
            }
            // Not any flavour of Command-H. Option-Command-H is the standard
            // Hide Others item and AppKit silently dropped this item's key
            // equivalent altogether when it collided; Shift-Command-H still
            // reached Hide in the running app, which hid the window mid-run.
            // Both were observed by driving the built app, not reasoned about.
            .keyboardShortcut("u", modifiers: .command)

            Button("Show Notation Report") {
                model.playback?.isReportShown.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
