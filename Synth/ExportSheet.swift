import SwiftUI
import SynthKit

/// The export sheet: choose a format and a quality, pick a destination, watch it
/// render, stop it (REQ-026, REQ-027).
///
/// **One sheet for all four states** rather than a wizard, because they are one
/// task: the choices stay visible (greyed) while the render runs, so the owner
/// can see what is being written, and the result replaces them in place instead
/// of in another window.
///
/// Every control is focusable, labelled and reachable from the keyboard, and the
/// sheet itself is opened by ⇧⌘E on the Playback menu.
struct ExportSheet: View {
    @Bindable var model: ExportModel
    /// What the sheet says it is exporting: the piece, and the preset when
    /// there is one.
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            ExportFormatControls(model: model)
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
        // **No `.accessibilityLabel` on this container.** Driving the built app
        // showed that a label here is inherited by every descendant, so the
        // whole sheet came back from `NSAccessibility` as fourteen elements all
        // called "Export audio" — the format buttons, the pickers, Close and
        // Choose Destination indistinguishable from one another. The heading
        // below names the sheet; each control names itself.
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Export Audio")
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Progress, result, or failure — whichever the export is currently in.
    @ViewBuilder
    private var outcome: some View {
        switch model.phase {
        case .ready:
            Text("Synth renders the piece through the same audio engine it plays "
                 + "with, so the file is what you hear. It writes nothing until the "
                 + "render finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .exporting:
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = model.progressFraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Export progress")
                        .accessibilityValue(model.spokenProgress)
                } else {
                    ProgressView()
                        .accessibilityLabel("Export progress")
                        .accessibilityValue(model.spokenProgress)
                }
                Text(model.progressDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.updatesFrequently)

        case .finished(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label("Exported \(result.url.lastPathComponent)", systemImage: "checkmark.circle")
                    .font(.body.weight(.medium))
                Text("\(ExportModel.clock(result.seconds)) of audio · "
                     + "\(ExportModel.byteCount(result.byteCount)) · \(result.settings.displayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if result.didClip {
                    // Worth saying: a mix over unity is inaudible as a number
                    // and unmistakable as a sound.
                    Label(
                        "The mix reached full scale, so the loudest peaks are clipped. "
                            + "Lower the master or a line’s volume and export again.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                Button("Reveal in Finder") { model.revealLastExportInFinder() }
                    .accessibilityHint("Opens a Finder window with the exported file selected.")
            }
            Spacer()

            if model.isExporting {
                // The one control that has to work while a render is in flight.
                // It writes a flag the render reads between blocks; the sheet
                // stays until the render has actually cleaned up after itself.
                Button("Cancel Export", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops the render. Nothing is written.")
            } else {
                Button("Close") { model.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(exportButtonTitle) { model.chooseDestinationAndStart() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Choose where to save, then render the piece.")
            }
        }
    }

    private var exportButtonTitle: String {
        if case .finished = model.phase { return "Export Again…" }
        if case .failed = model.phase { return "Try Again…" }
        return "Choose Destination…"
    }
}

/// Format and quality. Three pickers, because the issue asks for a
/// format/quality choice surface and these are the three things that choice is.
private struct ExportFormatControls: View {
    @Bindable var model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Format and quality")

            Picker("Format", selection: $model.settings.format) {
                ForEach(AudioExportFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("File format")
            .accessibilityHint("Both are uncompressed, so both are exactly what Synth plays.")

            HStack(spacing: 16) {
                Picker("Sample rate", selection: $model.settings.sampleRate) {
                    ForEach(AudioExportSampleRate.allCases, id: \.self) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }
                .frame(maxWidth: 210)
                .accessibilityLabel("Sample rate")

                Picker("Depth", selection: $model.settings.bitDepth) {
                    ForEach(AudioExportBitDepth.allCases, id: \.self) { depth in
                        Text(depth.displayName).tag(depth)
                    }
                }
                .frame(maxWidth: 190)
                .accessibilityLabel("Bit depth")
            }

            Text("44.1 kHz, 16-bit is CD quality. Higher settings make a larger "
                 + "file, not a different performance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Greyed rather than hidden while a render is in flight: the owner can
        // still read what is being written.
        .disabled(model.isExporting)
    }
}
