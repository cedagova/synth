import AppKit
import Foundation
import Observation
import SynthKit
import UniformTypeIdentifiers

/// Where an export is in its life.
enum ExportPhase: Equatable {
    /// Nothing is happening; the sheet shows the format and quality choices.
    case ready
    case exporting(AudioExportProgress?)
    case finished(AudioExportResult)
    case failed(ExportFailure)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

/// A failed export, in the owner's words.
struct ExportFailure: Equatable {
    let summary: String
    let recovery: String?
    /// True when the owner stopped it, so the sheet can say "Cancelled" rather
    /// than showing an error.
    let wasCancelled: Bool

    init(_ error: Error) {
        summary = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        recovery = (error as? LocalizedError)?.recoverySuggestion
        wasCancelled = (error as? AudioExportError)?.isCancellation ?? false
    }
}

/// The export surface of the open piece (REQ-026).
///
/// **Everything audible about an export happens in `SynthKit`.** This class owns
/// three things and no others: which format and quality the owner picked, the
/// thread the render runs on, and what the sheet is currently showing.
///
/// ## The thread boundary, stated plainly
///
/// A render is CPU-bound and can take tens of seconds. Running it on the main
/// actor would freeze the window and make the Cancel button unreachable — the
/// one control that has to work while a long export is in flight — so `start`
/// hands one `AudioExportRequest` to a detached task and that task owns the
/// whole render.
///
/// `PlaybackEngine` is single-owner and not internally synchronised, so the
/// crossing is made as narrow as it can be:
///
/// * the request is **values only** — a timeline, a voice assignment and mixer
///   numbers. There is no `PlaybackEngine` in it, so the engine the owner is
///   listening to cannot be reached from the export's thread;
/// * `AudioExporter.run` builds its own engine inside itself, on that thread,
///   and destroys it before returning; and
/// * the only object the two threads share is `AudioExportCancellation`, one
///   `Bool` behind one lock, which is what the Cancel button writes.
///
/// `AudioExportConcurrencyTests` proves all three in CI, and
/// `ExportWiringTests` proves this class's half — that the request the app
/// builds carries the open piece's real preset and that a cancel from the main
/// actor stops a real background render.
@Observable
@MainActor
final class ExportModel {
    /// True while the export sheet is up.
    var isPresented = false

    /// The owner's format and quality choice. Kept across exports within a
    /// session, because someone who wants 16-bit WAV wants it every time.
    var settings: AudioExportSettings = .standard

    private(set) var phase: ExportPhase = .ready

    /// Where the last export went, so the sheet can offer Reveal in Finder.
    private(set) var lastDestination: URL?

    /// What the piece is called, for the suggested file name.
    let pieceTitle: String

    /// What the current export can be stopped with. Nil when nothing is running.
    private var cancellation: AudioExportCancellation?
    private var task: Task<Void, Never>?

    /// Builds the request for the piece as it stands right now.
    ///
    /// A closure rather than stored state because an export must render *this*
    /// moment's configuration: the humanization the owner just changed, the
    /// sound they just assigned, the strip they just muted. Evaluated on the
    /// main actor at the instant Export is pressed, and everything it returns is
    /// a value, so nothing it read can change underneath the render.
    ///
    /// Installed by `PlaybackModel`, which owns the piece. Left unwired it
    /// returns nil and the export fails loudly with "this piece has nothing to
    /// export yet" — never silently with an empty file — and
    /// `ExportWiringTests` asserts the connection exists at all, because the
    /// increment-004 review found exactly this kind of closure proved nowhere.
    var makeRequest: @MainActor (AudioExportSettings) -> AudioExportRequest? = { _ in nil }

    /// The active preset's name, for the suggested file name.
    var presetName: @MainActor () -> String? = { nil }

    /// A sentence the sheet shows when what is playing is not what will be
    /// exported — the sound studio's play-through being the one case.
    var caveat: @MainActor () -> String? = { nil }

    /// How the destination is chosen.
    ///
    /// An `NSSavePanel` in the app. A seam because a save panel cannot be
    /// answered by a test, and because the sandbox runs it out of process where
    /// nothing in this process can drive it — so `ExportWiringTests` and the
    /// local smoke driver supply a URL directly and everything downstream of the
    /// choice is the production path.
    var chooseDestination: @MainActor (_ suggestedName: String, _ format: AudioExportFormat) -> URL?

    init(pieceTitle: String) {
        self.pieceTitle = pieceTitle
        self.chooseDestination = ExportModel.presentSavePanel
    }

    // MARK: What the sheet shows

    /// The file name the save panel opens on.
    var suggestedFileName: String {
        AudioExportNaming.suggestedFileName(
            pieceTitle: pieceTitle, presetName: presetName(), format: settings.format
        )
    }

    var isExporting: Bool { phase.isExporting }

    /// 0…1 while exporting, nil before the first block lands.
    var progressFraction: Double? {
        guard case .exporting(let progress) = phase else { return nil }
        return progress?.fraction
    }

    /// "1:04 of 3:12 · 22× faster than real time"
    var progressDescription: String {
        guard case .exporting(let progress) = phase else { return "" }
        guard let progress else { return "Starting the render…" }
        var text = "\(Self.clock(progress.renderedSeconds)) of \(Self.clock(progress.totalSeconds))"
        if let speed = progress.speedMultiple, speed >= 1.5 {
            text += " · \(Int(speed.rounded()))× faster than real time"
        }
        return text
    }

    /// One sentence VoiceOver can read without the owner watching a bar.
    var spokenProgress: String {
        guard case .exporting(let progress) = phase else { return "" }
        guard let progress else { return "Export starting" }
        return "Exporting, \(Int((progress.fraction * 100).rounded())) percent, "
            + "\(Self.clock(progress.renderedSeconds)) of \(Self.clock(progress.totalSeconds))"
    }

    /// The status line the transport shows after an export ends.
    var statusMessage: String? {
        switch phase {
        case .ready:
            return nil
        case .exporting:
            return "Exporting \(settings.displayName)…"
        case .finished(let result):
            return "Exported \(result.url.lastPathComponent) — "
                + "\(Self.clock(result.seconds)) of audio, \(Self.byteCount(result.byteCount))."
        case .failed(let failure):
            return failure.wasCancelled ? "Export cancelled. Nothing was written." : failure.summary
        }
    }

    // MARK: Doing it

    /// Show the sheet, forgetting the previous run's outcome.
    func present() {
        guard !isExporting else { return }
        phase = .ready
        isPresented = true
    }

    /// Ask for a destination and start the render.
    ///
    /// Split from `start(to:)` so the destination step — which is a system
    /// panel — is separable from everything this leaf actually owns.
    func chooseDestinationAndStart() {
        guard !isExporting else { return }
        guard let destination = chooseDestination(suggestedFileName, settings.format) else {
            return  // The owner cancelled the panel. Nothing happened.
        }
        start(to: destination)
    }

    /// Render the open piece to `destination` on a background thread.
    func start(to destination: URL) {
        guard !isExporting else { return }
        guard let request = makeRequest(settings) else {
            phase = .failed(ExportFailure(AudioExportError.nothingToRender))
            return
        }

        let cancellation = AudioExportCancellation()
        self.cancellation = cancellation
        lastDestination = destination
        phase = .exporting(nil)

        // Bound once, here, so the render thread's callback holds exactly one
        // weak reference to this model and nothing else. Written outside the
        // task because a closure that re-captures the task's own `self` is a
        // capture of a variable the task later rebinds.
        let onProgress: @Sendable (AudioExportProgress) -> Void = { [weak self] progress in
            // Hop to the main actor to publish: the render thread must never
            // touch observable state.
            Task { @MainActor in self?.publish(progress) }
        }

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> Result<AudioExportResult, Error> in
                do {
                    return .success(
                        try AudioExporter(request: request).run(
                            to: destination,
                            progress: onProgress,
                            cancellation: cancellation
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

            guard let model = self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                model.phase = .finished(result)
            case .failure(let error):
                model.phase = .failed(ExportFailure(error))
            }
            model.cancellation = nil
            model.task = nil
        }
    }

    /// A progress step from the render thread, applied only while the export it
    /// belongs to is still the current one.
    private func publish(_ progress: AudioExportProgress) {
        guard case .exporting = phase else { return }
        phase = .exporting(progress)
    }

    /// Stop the running export. Safe to press repeatedly.
    ///
    /// This is the only thing the main actor does to a render in flight, and it
    /// writes one `Bool` behind one lock. The render notices between blocks,
    /// throws, deletes its staged file, and reports `.cancelled`; the phase is
    /// set from that result rather than optimistically here, so the sheet never
    /// says "cancelled" before the file has actually been cleaned up.
    func cancel() {
        cancellation?.cancel()
    }

    /// The screen is going away. Stops any export rather than leaving a render
    /// running against a model nothing is showing.
    ///
    /// **The wrapper task is deliberately not cancelled.** Cancelling the render
    /// is what stops the work; cancelling the task as well would kill the
    /// continuation that reports the outcome, leaving this model saying
    /// "exporting" for ever and — worse — hiding a real failure. The flag is
    /// enough: the render notices between blocks, deletes its staged file, and
    /// the completion below records that it was cancelled.
    func close() {
        cancellation?.cancel()
        isPresented = false
    }

    func revealLastExportInFinder() {
        guard case .finished(let result) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    // MARK: Destination

    /// The shipped destination chooser: a real save panel.
    @MainActor
    private static func presentSavePanel(
        suggestedName: String, format: AudioExportFormat
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        // The extension is fixed by the format, and changing it in the name
        // field would produce a WAV called `.aiff`.
        panel.isExtensionHidden = false
        if let type = UTType(format.contentTypeIdentifier) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    // MARK: Formatting

    /// `m:ss`, which is what the transport readout uses.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
