import SwiftUI

@main
struct SynthApp: App {
    @NSApplicationDelegateAdaptor(SynthAppDelegate.self) private var appDelegate

    /// Owned by the delegate, because the delegate is where AppKit hands over
    /// files opened from Finder — on a cold launch, before any view exists.
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        // One window, as a `Window` rather than a `WindowGroup` (#88). A
        // window group answers a file opened from Finder by routing it to a
        // window, and whenever its window is busy with an alert or a sheet it
        // makes a second window for it — smoke-tested: a damaged file opened
        // twice gave four windows, each showing the same alert. A `Window`
        // cannot be made twice, and a launch *by* opening a file still opens
        // it. The app never offered a second window anyway (`LibraryCommands`
        // replaces File ▸ New), and the whole shell assumes one.
        Window("Synth", id: "main") {
            RootView(model: model)
                .task {
                    model.installKeyboardControl()
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1_280, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            LibraryCommands(model: model)
            PlaybackCommands(model: model)
            MixCommands(model: model)
            SoundCommands(model: model)
            InstrumentCommands(model: model)
        }
    }
}

/// Receives files opened from Finder — double-click or Open With (#88).
///
/// The files go straight into `FinderOpenModel`'s queue, which holds them
/// until the library is ready, so an open that launches the app is not lost
/// before any view exists.
@MainActor
final class SynthAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        model.finderOpen.open(urls)
    }

    /// Closing the window leaves the app running, as it did before the scene
    /// became a single `Window`: a download or a playing piece carries on, and
    /// the Dock or the next Finder open brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
