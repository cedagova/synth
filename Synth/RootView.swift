import SwiftUI

/// The app shell: launch state, launch failure, or the library.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            // The studio takes the window over whatever else is showing, and
            // deliberately does not close it. An open piece keeps playing while
            // a sound is designed — that is what "live editing during playback"
            // means when there is one window — so leaving the studio comes back
            // to a transport that has been running all along.
            if model.isStudioShowing, let studio = model.studio {
                SoundStudioScreen(model: studio) { model.closeSoundStudio() }
            } else if let playback = model.playback {
                PlaybackScreen(model: playback) { model.closePlayback() }
                    // Keyed by piece so opening another one rebuilds the screen
                    // and re-runs its preparation task.
                    .id(playback.piece.id)
            } else {
                switch model.state {
                case .loading:
                    LoadingView()
                case .ready(let library):
                    LibraryScreen(model: library) { piece in
                        model.openPlayback(for: piece)
                    }
                case .failed(let failure):
                    StoreFailureView(failure: failure) {
                        await model.retry()
                    }
                }
            }
        }
        // Wider than increment 003's 720 because the transport now sits beside
        // the assignment and mixing panel, and squeezing a fader to nothing to
        // keep an old number is not a saving.
        .frame(minWidth: 1_040, minHeight: 560)
        .navigationTitle("Synth")
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening your library…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening your library")
    }
}

/// The launch-error state required by the store's failure behavior.
struct StoreFailureView: View {
    let failure: StoreFailure
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Synth could not open your library", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(failure.summary)
                if let recovery = failure.recovery {
                    Text(recovery).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
