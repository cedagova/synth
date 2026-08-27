import SwiftUI

/// The app shell. Increment 001's later leaves replace the library area with
/// the real browse/search/import surface; the store status bar stays.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                LoadingView()
            case .ready(let summary):
                LibraryView(summary: summary)
            case .failed(let failure):
                StoreFailureView(failure: failure) {
                    await model.retry()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
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

/// The library area over an opened store.
///
/// This leaf can only ever reach the empty state through the app, because
/// importing arrives with the import pipeline. The non-empty branch exists so
/// the shell never contradicts its own status bar when the container already
/// holds pieces; the library UI leaf replaces it with the real browse surface.
struct LibraryView: View {
    let summary: StoreSummary

    var body: some View {
        Group {
            if summary.pieceCount == 0 {
                ContentUnavailableView {
                    Label("No pieces yet", systemImage: "music.note.list")
                } description: {
                    Text("Your library is ready and empty. Importing MusicXML files arrives in the next step.")
                }
            } else {
                ContentUnavailableView {
                    Label("Library not browsable yet", systemImage: "music.note.list")
                } description: {
                    Text("\(summary.pieceCount) stored \(summary.pieceCount == 1 ? "piece is" : "pieces are") waiting. Browsing them arrives with the library screen.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            StoreStatusBar(summary: summary)
        }
    }
}

/// Shows that the persistent container and versioned store really exist.
struct StoreStatusBar: View {
    let summary: StoreSummary

    var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(summary.containerPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "internaldrive")
            }
            .accessibilityLabel("Library folder \(summary.containerPath)")

            Divider().frame(height: 14)

            Text("Store schema v\(summary.schemaVersion)")
                .accessibilityLabel("Store schema version \(summary.schemaVersion)")

            Divider().frame(height: 14)

            Text(summary.pieceCount == 1 ? "1 piece" : "\(summary.pieceCount) pieces")

            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
