import SwiftUI
import SynthKit

/// The "Export Stems…" sheet (#90): container and rate, the stems that will be
/// written, a folder, progress over the whole batch, and Cancel.
///
/// Laid out like `ExportSheet` on purpose — one sheet for all four states, the
/// choices greyed while the render runs — so the two exports read as one
/// feature.
struct StemExportSheet: View {
    @Bindable var model: StemExportModel
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            ExportFormatControls(
                settings: $model.settings,
                fixedDepth: AudioSampleEncoding.float32.displayName,
                isDisabled: model.isExporting
            )
            stemList
            if let caveat = model.caveat() {
                Label(caveat, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(caveat)
            }
            Divider()
            outcome
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Export Stems")
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var stemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading("Stems")
            if model.plannedStems.isEmpty {
                Label(
                    "Every line is muted, so there is nothing to export. Unmute a line first.",
                    systemImage: "speaker.slash"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(model.plannedStems.count) files, one per line the mix plays, "
                     + "each with that line’s volume and pan and without the master stage:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.plannedStems) { stem in
                            Text(stem.fileName)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .accessibilityLabel("Stem files")
            }
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.phase {
        case .ready:
            Text("Each stem is rendered through the same audio engine as playback, so "
                 + "together they add up to the mix before its master stage. Nothing is "
                 + "written until every stem has rendered.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .exporting:
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = model.progressFraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Stem export progress")
                        .accessibilityValue(model.spokenProgress)
                } else {
                    ProgressView()
                        .accessibilityLabel("Stem export progress")
                        .accessibilityValue(model.spokenProgress)
                }
                Text(model.progressDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.updatesFrequently)

        case .finished(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Exported \(result.files.count) stems to \(result.folder.lastPathComponent)",
                    systemImage: "checkmark.circle"
                )
                .font(.body.weight(.medium))
                Text("\(ExportModel.clock(result.seconds)) each · "
                     + "\(ExportModel.byteCount(result.byteCount)) · \(model.fileDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    failure.summary,
                    systemImage: failure.wasCancelled ? "xmark.circle" : "exclamationmark.triangle"
                )
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                if let recovery = failure.recovery {
                    Text(recovery)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .finished = model.phase {
                Button("Reveal in Finder") { model.revealInFinder() }
                    .accessibilityHint("Opens a Finder window with the stems selected.")
            }
            Spacer()

            if model.isExporting {
                Button("Cancel Export", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops the render. No stems are written.")
            } else {
                Button("Close") { model.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(exportButtonTitle) { model.chooseFolderAndStart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
                    .accessibilityHint("Choose a folder, then render one file per line.")
            }
        }
    }

    private var exportButtonTitle: String {
        if case .finished = model.phase { return "Export Again…" }
        if case .failed = model.phase { return "Try Again…" }
        return "Choose Folder…"
    }
}
