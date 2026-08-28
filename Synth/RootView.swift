import SwiftUI

/// The app shell: launch state, launch failure, or the library.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            // The transport takes the whole window while a piece is open: it is
            // its own place, not a panel beside the list, and later increments
            // extend it rather than the library.
            if let playback = model.playback {
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
        .frame(minWidth: 720, minHeight: 460)
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
