import SwiftUI

@main
struct SynthApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1_280, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            LibraryCommands(model: model)
            PlaybackCommands(model: model)
            MixCommands(model: model)
            SoundCommands(model: model)
        }
    }
}
