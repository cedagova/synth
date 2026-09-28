import AppKit
import Foundation
import Observation
import SynthKit

/// Where a stem export is in its life.
enum StemExportPhase: Equatable {
    case ready
    case exporting(AudioStemExportProgress?)
    case finished(AudioStemExportResult)
    case failed(ExportFailure)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

/// The "Export Stems…" surface of the open piece (#90).
///
/// The same shape as `ExportModel`, for the same reasons: everything audible
/// happens in `SynthKit` (`AudioStemExporter`), the request is built on the
/// main actor as values, and the render runs on one detached task whose only
/// shared state is an `AudioExportCancellation`. This model adds the folder
/// choice and the one question a batch can raise that a save panel already
/// answers for a single file: may existing files be replaced?
@Observable
@MainActor
final class StemExportModel {
    var isPresented = false

    /// Container and rate for the stems. The depth is always 32-bit float, so
    /// `bitDepth` here is never read; kept apart from the mix export's own
    /// settings so choosing stems never changes them.
    var settings: AudioExportSettings = .standard {
        didSet { refreshPlan() }
    }

    private(set) var phase: StemExportPhase = .ready

    /// What pressing Export would write, refreshed when the sheet opens and
    /// when the format changes. Empty when every line is muted.
    private(set) var plannedStems: [AudioStem] = []

    /// "WAV · 48 kHz · 32-bit float"
    private(set) var fileDescription = ""

    let pieceTitle: String

    private var cancellation: AudioExportCancellation?
    private var task: Task<Void, Never>?

    /// Builds the batch for the piece as it stands right now. Installed by
    /// `PlaybackModel`; left unwired it returns nil and the export fails
    /// loudly with "nothing to export yet".
    var makeRequest: @MainActor (AudioExportSettings) -> AudioStemExportRequest? = { _ in nil }

    /// Same meaning as `ExportModel.caveat`.
    var caveat: @MainActor () -> String? = { nil }

    /// How the folder is chosen: an `NSOpenPanel` for directories. A seam
    /// because a panel cannot be answered by a test.
    var chooseFolder: @MainActor (_ completion: @escaping @MainActor (URL?) -> Void) -> Void

    /// Asks whether the named files may be replaced. A seam for the same
    /// reason; the shipped one is an alert on the sheet.
    var confirmReplacing: @MainActor (
        _ names: [String], _ folder: URL, _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void

    init(pieceTitle: String) {
        self.pieceTitle = pieceTitle
        self.chooseFolder = StemExportModel.presentFolderPanel
        self.confirmReplacing = StemExportModel.presentReplaceAlert
    }

    // MARK: What the sheet shows

    var isExporting: Bool { phase.isExporting }

    /// False when there is nothing to export (every line muted).
    var canExport: Bool { !plannedStems.isEmpty && !isExporting }

    var progressFraction: Double? {
        guard case .exporting(let progress) = phase else { return nil }
        return progress?.fraction
    }

    /// "Stem 2 of 5 · Violin I · 0:12 of 3:04"
    var progressDescription: String {
        guard case .exporting(let progress) = phase else { return "" }
        guard let progress else { return "Starting the render…" }
        return "Stem \(progress.stemIndex + 1) of \(progress.stemCount) · \(progress.stemName) · "
            + "\(ExportModel.clock(progress.stem.renderedSeconds)) of "
            + "\(ExportModel.clock(progress.stem.totalSeconds))"
    }

    var spokenProgress: String {
        guard case .exporting(let progress) = phase else { return "" }
        guard let progress else { return "Stem export starting" }
        return "Exporting stems, \(Int((progress.fraction * 100).rounded())) percent, "
            + "stem \(progress.stemIndex + 1) of \(progress.stemCount), \(progress.stemName)"
    }

    var statusMessage: String? {
        switch phase {
        case .ready:
            return nil
        case .exporting:
            return "Exporting stems…"
        case .finished(let result):
            return "Exported \(result.files.count) stems to \(result.folder.lastPathComponent) — "
                + "\(ExportModel.byteCount(result.byteCount))."
        case .failed(let failure):
            return failure.wasCancelled ? "Stem export cancelled. Nothing was written." : failure.summary
        }
    }

    // MARK: Doing it

    func present() {
        guard !isExporting else { return }
        phase = .ready
        refreshPlan()
        isPresented = true
    }

    private func refreshPlan() {
        let request = makeRequest(settings)
        plannedStems = request?.stems ?? []
        fileDescription = request?.fileDescription ?? ""
    }

    func chooseFolderAndStart() {
        guard !isExporting else { return }
        chooseFolder { [weak self] folder in
            guard let self, let folder else { return }
            self.start(in: folder)
        }
    }

    /// Render every stem into `folder`, asking first if that would replace
    /// files already there.
    ///
    /// `confirmed` is the set of names the owner agreed to replace. The stems
    /// are rebuilt on every call, so if they now collide with any file outside
    /// that set — the mix changed, or a file appeared — the owner is asked
    /// again about the full list, and SynthKit refuses anything unconfirmed at
    /// publish too.
    func start(in folder: URL, confirmed: Set<String> = []) {
        guard !isExporting else { return }
        guard let request = makeRequest(settings) else {
            phase = .failed(ExportFailure(AudioExportError.nothingToRender))
            return
        }
        guard !request.stems.isEmpty else {
            phase = .failed(ExportFailure(AudioExportError.nothingAudible))
            return
        }
        let existing = request.existingFileNames(in: folder)
        if !Set(existing).isSubset(of: confirmed) {
            confirmReplacing(existing, folder) { [weak self] agreed in
                guard agreed else { return }
                self?.start(in: folder, confirmed: Set(existing))
            }
            return
        }
        // Only what is actually there and was agreed to; never a wider set.
        let replacing = Set(existing)

        let cancellation = AudioExportCancellation()
        self.cancellation = cancellation
        phase = .exporting(nil)

        let onProgress: @Sendable (AudioStemExportProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.publish(progress) }
        }

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> Result<AudioStemExportResult, Error> in
                do {
                    return .success(
                        try AudioStemExporter(request: request).run(
                            into: folder,
                            confirmedReplacements: replacing,
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

    private func publish(_ progress: AudioStemExportProgress) {
        guard case .exporting = phase else { return }
        phase = .exporting(progress)
    }

    /// Stop the batch. Nothing is written: every stem is still staged.
    func cancel() {
        cancellation?.cancel()
    }

    /// The piece is closing. Same reasoning as `ExportModel.close`.
    func close() {
        cancellation?.cancel()
        isPresented = false
    }

    func revealInFinder() {
        guard case .finished(let result) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.files.map(\.url))
    }

    // MARK: Panels

    @MainActor
    private static func presentFolderPanel(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Export Stems"
        panel.prompt = "Export Stems"
        panel.message = "Choose a folder for the stems. One file is written per line."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        panel.beginSheetModal(for: host) { response in
            MainActor.assumeIsolated {
                completion(response == .OK ? panel.url : nil)
            }
        }
    }

    @MainActor
    private static func presentReplaceAlert(
        names: [String], folder: URL, completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? "“\(names[0])” already exists in “\(folder.lastPathComponent)”. Replace it?"
            : "\(names.count) of these stems already exist in “\(folder.lastPathComponent)”. "
                + "Replace them?"
        let listed = names.prefix(6).joined(separator: "\n")
        alert.informativeText = listed
            + (names.count > 6 ? "\n…and \(names.count - 6) more." : "")
            + "\n\nThe existing files are only replaced once every stem has rendered."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: host) { response in
            MainActor.assumeIsolated {
                completion(response == .alertFirstButtonReturn)
            }
        }
    }
}
