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
            // The catalog sits above even the studio, because the first-run
            // offer is raised from it before anything else has been chosen.
            if model.isInstrumentCatalogShowing, let catalog = model.instrumentCatalog {
                InstrumentCatalogScreen(model: catalog) { model.closeInstrumentCatalog() }
            } else if model.isStudioShowing, let studio = model.studio {
                SoundStudioScreen(model: studio) { model.closeSoundStudio() }
            } else if let playback = model.playback {
                PlaybackScreen(
                    model: playback,
                    close: { model.closePlayback() },
                    openStudio: { request in model.openSoundStudio(request) }
                )
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
        .modifier(FinderOpenResult(model: model.finderOpen))
    }
}

/// The result of a Finder open over a screen that is not the library (P84-4):
/// a short notice for a success, the library's own named-file alert for a
/// failure. Neither navigates or interrupts what is showing.
private struct FinderOpenResult: ViewModifier {
    @Bindable var model: FinderOpenModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    Text(notice.message)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4)
                        .padding(.top, 12)
                        .onTapGesture { model.notice = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(6))
                            if model.notice?.id == notice.id { model.notice = nil }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.notice)
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(
                    get: { model.alert != nil },
                    set: { if !$0 { model.alert = nil } }
                ),
                presenting: model.alert
            ) { _ in
                Button("OK") { model.alert = nil }
            } message: { alert in
                Text([alert.message, alert.recovery].compactMap { $0 }.joined(separator: "\n\n"))
            }
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
