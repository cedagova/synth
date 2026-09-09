import AppKit
import Foundation

/// The computer keyboard as an instrument and as a transport (REQ-018, REQ-027).
///
/// **Why this is not a set of menu shortcuts.** A menu key equivalent is
/// matched before the first responder ever sees the key, which is why
/// `PlaybackCommands` could never bind Space: it would have made a space
/// untypeable in every search and rename field. And a key that has to
/// *release* a note on key-up is not a menu item at all. So both live here,
/// on a local `NSEvent` monitor, which sees every key the app receives and
/// can decide — per key, with the window's state in hand — whether to act on
/// it or hand it on untouched.
///
/// **What the monitor refuses to touch**, so nothing the owner could type is
/// ever stolen from them:
///
/// * a key while any text field has focus (the search, a rename, a parameter
///   value, the variant name);
/// * a key carrying Command, Control or Option — those are the menus';
/// * a key while a sheet or alert is up — that window's controls own it;
/// * a key while the instrument catalog is showing, which has nothing to play.
///
/// The one thing deliberately taken is Space on a focused button under Full
/// Keyboard Access while a piece is open: Space plays and pauses, the way it
/// does in every DAW and media player, and Return still activates the button.
@MainActor
final class KeyboardControl {
    private weak var model: AppModel?
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
    }

    /// Start watching the app's key events. Idempotent.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let stroke = KeyStroke(event: event) else { return event }
            return self.handle(stroke) ? nil : event
        }
        // A key released while another app is frontmost never reaches this
        // monitor, and a note that never hears its key-up sounds forever.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.studio?.editor.releaseEverything() }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Act on one key, or say that it was not for us.
    ///
    /// Returns true when the key was consumed, and the event must not travel
    /// on to the responder chain. A note key's release is consumed too, so the
    /// press and its release are treated alike.
    @discardableResult
    func handle(_ stroke: KeyStroke) -> Bool {
        guard let model,
              !stroke.hasMenuModifiers,
              !stroke.isTypingText,
              !stroke.isInSecondaryWindow,
              !model.isInstrumentCatalogShowing else { return false }

        // The studio: letters are notes when a synth sound is under edit.
        if model.isStudioShowing, let studio = model.studio,
           !studio.isEditingInstrument, studio.editor.isOpen,
           let key = MusicalTypingKey(keyCode: stroke.keyCode) {
            play(key, on: studio.editor, stroke: stroke)
            return true
        }

        guard let playback = model.playback,
              let key = TransportKey(keyCode: stroke.keyCode) else { return false }
        // Under the studio the piece keeps playing, and Space is the one
        // transport key an owner designing a sound reaches for. The others
        // stay the studio's — Return finishes a rename, the arrows move a
        // slider — so they are not taken from it.
        if model.isStudioShowing, key != .playPause { return false }
        guard stroke.isKeyDown else { return true }
        // Holding Space must not play, pause, play, pause. Holding an arrow
        // should keep skipping, the way it does in a media player.
        if stroke.isRepeat, !key.repeats { return true }
        apply(key, to: playback)
        return true
    }

    private func play(_ key: MusicalTypingKey, on editor: SoundEditorModel, stroke: KeyStroke) {
        switch key {
        case .note(let semitone):
            guard !stroke.isRepeat else { return }
            stroke.isKeyDown ? editor.typingKeyDown(semitone: semitone)
                             : editor.typingKeyUp(semitone: semitone)
        case .octaveDown:
            if stroke.isKeyDown, !stroke.isRepeat { editor.shiftTypingOctave(by: -1) }
        case .octaveUp:
            if stroke.isKeyDown, !stroke.isRepeat { editor.shiftTypingOctave(by: 1) }
        case .velocityDown:
            if stroke.isKeyDown { editor.nudgeTypingVelocity(by: -SoundEditorModel.typingVelocityStep) }
        case .velocityUp:
            if stroke.isKeyDown { editor.nudgeTypingVelocity(by: SoundEditorModel.typingVelocityStep) }
        }
    }

    private func apply(_ key: TransportKey, to playback: PlaybackModel) {
        switch key {
        case .playPause: playback.togglePlayPause()
        case .stop: playback.stop()
        case .skipBack: playback.skip(byMicroseconds: -PlaybackModel.skipMicroseconds)
        case .skipForward: playback.skip(byMicroseconds: PlaybackModel.skipMicroseconds)
        case .previousMeasure: playback.stepMeasure(by: -1)
        case .nextMeasure: playback.stepMeasure(by: 1)
        }
    }
}

// MARK: - One key, and the state that decides what it means

/// A key event reduced to what `KeyboardControl` decides on, so the decision
/// can be tested without an `NSEvent` or a window.
struct KeyStroke: Equatable, Sendable {
    /// The hardware key code. **Positional, not the character**, which is the
    /// convention every DAW's musical typing follows: the row of keys under
    /// the left hand is the octave whatever the layout prints on it, so a
    /// Spanish or German keyboard plays the same keyboard an American one does.
    let keyCode: UInt16
    let isKeyDown: Bool
    let isRepeat: Bool

    /// Command, Control or Option is held: the key belongs to a menu.
    let hasMenuModifiers: Bool

    /// A text field has focus and the key is a character being typed.
    let isTypingText: Bool

    /// A sheet, alert or panel is the key window; its own controls own the key.
    let isInSecondaryWindow: Bool

    init(
        keyCode: UInt16, isKeyDown: Bool = true, isRepeat: Bool = false,
        hasMenuModifiers: Bool = false, isTypingText: Bool = false,
        isInSecondaryWindow: Bool = false
    ) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.isRepeat = isRepeat
        self.hasMenuModifiers = hasMenuModifiers
        self.isTypingText = isTypingText
        self.isInSecondaryWindow = isInSecondaryWindow
    }

    /// Read the state off the live event and the key window. Nil for an event
    /// that is neither a press nor a release.
    @MainActor
    init?(event: NSEvent) {
        switch event.type {
        case .keyDown: isKeyDown = true
        case .keyUp: isKeyDown = false
        default: return nil
        }
        keyCode = event.keyCode
        isRepeat = event.isARepeat
        hasMenuModifiers = !event.modifierFlags
            .intersection([.command, .control, .option]).isEmpty

        let window = NSApp.keyWindow
        // A focused SwiftUI text field hands typing to the window's field
        // editor, which is an `NSTextView`; a bare `NSTextField` covers the
        // AppKit-hosted cases. Anything else — the hosting view, a table — is
        // not somewhere a letter would be typed.
        let responder = window?.firstResponder
        isTypingText = responder is NSTextView || responder is NSTextField
        isInSecondaryWindow = window.map { $0 is NSPanel || $0.sheetParent != nil } ?? false
    }
}

// MARK: - Musical typing

/// The keyboard layout every DAW's musical typing shares — GarageBand and
/// Logic's Musical Typing, Ableton's Computer MIDI Keyboard, FL Studio's typing
/// keyboard — so an owner who has used any of them already knows this one.
///
/// The home row is the white keys and the row above it the black keys, one
/// octave and a fourth from A to the quote key. Z and X move the octave, C
/// and V the velocity. Key codes are the ANSI positions, so the layout is
/// where the keys *are*, whatever they print.
enum MusicalTypingKey: Equatable, Sendable {
    case note(semitone: Int)
    case octaveDown, octaveUp
    case velocityDown, velocityUp

    /// Semitone above the base note, by key code: A W S E D F T G Y H U J K O L P ; '
    private static let semitoneByKeyCode: [UInt16: Int] = [
        0: 0,   // A  C
        13: 1,  // W  C♯
        1: 2,   // S  D
        14: 3,  // E  E♭
        2: 4,   // D  E
        3: 5,   // F  F
        17: 6,  // T  F♯
        5: 7,   // G  G
        16: 8,  // Y  A♭
        4: 9,   // H  A
        32: 10, // U  B♭
        38: 11, // J  B
        40: 12, // K  C
        31: 13, // O  C♯
        37: 14, // L  D
        35: 15, // P  E♭
        41: 16, // ;  E
        39: 17  // '  F
    ]

    init?(keyCode: UInt16) {
        switch keyCode {
        case 6: self = .octaveDown      // Z
        case 7: self = .octaveUp        // X
        case 8: self = .velocityDown    // C
        case 9: self = .velocityUp      // V
        default:
            guard let semitone = Self.semitoneByKeyCode[keyCode] else { return nil }
            self = .note(semitone: semitone)
        }
    }

    /// How many semitones the note keys span: A to the quote key.
    static let noteSpan = 18
}

// MARK: - Transport keys

/// The transport on the bare keys every player and DAW agrees on: Space plays
/// and pauses, Return stops, the arrows skip, comma and period step a measure
/// the way Logic's do.
enum TransportKey: Equatable, Sendable {
    case playPause, stop, skipBack, skipForward, previousMeasure, nextMeasure

    init?(keyCode: UInt16) {
        switch keyCode {
        case 49: self = .playPause          // Space
        case 36, 76: self = .stop           // Return, keypad Enter
        case 123: self = .skipBack          // ←
        case 124: self = .skipForward       // →
        case 43: self = .previousMeasure    // ,
        case 47: self = .nextMeasure        // .
        default: return nil
        }
    }

    /// Whether holding the key should keep acting.
    var repeats: Bool {
        switch self {
        case .playPause, .stop: return false
        case .skipBack, .skipForward, .previousMeasure, .nextMeasure: return true
        }
    }
}
