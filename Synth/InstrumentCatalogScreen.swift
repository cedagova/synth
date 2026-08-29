import SwiftUI
import SynthKit

/// The instrument catalog: what Synth can download, what it costs, what it is
/// legally, and how honest it is being about the quality.
///
/// A list of libraries rather than a store front. Each row says its size before
/// anything is committed to, its licence in the same breath as its name, and —
/// once expanded — exactly which instruments arrive and what is thin about
/// them. REQ-021's "degrade visibly, never fake" starts here, before a single
/// byte is downloaded.
///
/// Everything is reachable from the keyboard, and every control carries a label,
/// a value and a hint (REQ-027). The menu commands in `InstrumentCommands`
/// duplicate every action for the same reason `SoundCommands` does.
struct InstrumentCatalogScreen: View {
    @Bindable var model: InstrumentCatalogModel

    /// Leaves the catalog and goes back to whatever was showing before.
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List(selection: $model.selection) {
                ForEach(model.rows) { row in
                    LibraryRow(model: model, row: row)
                        .tag(row.id)
                }
            }
            .listStyle(.inset)
            .alert(
                removalTitle,
                isPresented: removalConfirmationBinding,
                presenting: pendingRemovalRow
            ) { row in
                Button("Remove", role: .destructive) { model.confirmRemoval(of: row.library) }
                Button("Cancel", role: .cancel) { model.cancelRemoval() }
            } message: { row in
                Text(
                    """
                    This frees \(InstrumentCatalogDisplay.size(row.library.downloadByteCount)) \
                    of disk space. Nothing else is affected — your pieces, presets and \
                    sounds are untouched, and you can download it again at any time.
                    """
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: licenceSheetBinding) { row in
            LicenceSheet(library: row.library) { model.licenceSheetLibraryID = nil }
        }
        .sheet(isPresented: firstRunOfferBinding) {
            FirstRunOffer(
                byteCount: model.catalogByteCount,
                libraryCount: model.libraryCount,
                answer: { model.answerFirstRunOffer(downloadNow: $0) }
            )
        }
        .alert(
            "Synth could not read your instrument library",
            isPresented: alertBinding,
            presenting: model.alert
        ) { _ in
            Button("OK") { model.alert = nil }
        } message: { failure in
            Text([failure.summary, failure.recovery].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .task { model.prepareForFirstRun() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Instruments")
                    .font(.headline)
                Text(model.coverageSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Instruments. \(model.coverageSummary)")

            Spacer()

            Button("Done", action: close)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Goes back to what you were doing.")
        }
        .padding(16)
    }

    // MARK: Sheet and alert plumbing

    private var pendingRemovalRow: InstrumentCatalogModel.Row? {
        model.rows.first { $0.id == model.pendingRemovalLibraryID }
    }

    private var removalTitle: String {
        pendingRemovalRow.map { "Remove “\($0.library.name)”?" } ?? ""
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemovalLibraryID != nil },
            set: { if !$0 { model.cancelRemoval() } }
        )
    }

    private var licenceSheetBinding: Binding<InstrumentCatalogModel.Row?> {
        Binding(
            get: { model.rows.first { $0.id == model.licenceSheetLibraryID } },
            set: { model.licenceSheetLibraryID = $0?.id }
        )
    }

    private var firstRunOfferBinding: Binding<Bool> {
        Binding(
            get: { model.isShowingFirstRunOffer },
            set: { if !$0 { model.answerFirstRunOffer(downloadNow: false) } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }
}

// MARK: - One library

private struct LibraryRow: View {
    let model: InstrumentCatalogModel
    let row: InstrumentCatalogModel.Row

    @State private var isShowingInstruments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.library.name)
                        .font(.body.weight(.medium))
                    Text(row.library.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.status(of: row))
                        .font(.subheadline)
                        .foregroundStyle(row.failure == nil ? .secondary : Color.red)
                        .accessibilityIdentifier("instrument-library-status-\(row.id)")
                }

                Spacer(minLength: 12)

                Button(model.primaryActionTitle(for: row)) {
                    model.performPrimaryAction(on: row.library)
                }
                .accessibilityLabel("\(model.primaryActionTitle(for: row)) \(row.library.name)")
                .accessibilityHint(actionHint)
                .accessibilityIdentifier("instrument-library-action-\(row.id)")
            }

            if let progress = row.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("\(row.library.name) download progress")
                    .accessibilityValue(InstrumentCatalogDisplay.progress(progress))
            }

            if let failure = row.failure {
                FailureNote(libraryName: row.library.name, failure: failure) {
                    model.startDownload(of: row.library)
                }
            }

            HStack(spacing: 16) {
                Button {
                    model.licenceSheetLibraryID = row.id
                } label: {
                    Label(row.library.licence.spdxIdentifier, systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Licence and credits for \(row.library.name)")
                .accessibilityValue(InstrumentCatalogDisplay.licence(row.library))
                .accessibilityIdentifier("instrument-library-licence-\(row.id)")

                Button {
                    isShowingInstruments.toggle()
                } label: {
                    Label(
                        InstrumentCatalogDisplay.instrumentCount(row.library),
                        systemImage: isShowingInstruments ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption)
                }
                .buttonStyle(.link)
                .accessibilityLabel(
                    "\(isShowingInstruments ? "Hide" : "Show") the instruments in \(row.library.name)"
                )
                .accessibilityValue(InstrumentCatalogDisplay.instrumentCount(row.library))

                Spacer()
            }

            if isShowingInstruments {
                InstrumentList(library: row.library)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityDescription(of: row))
    }

    private var actionHint: String {
        switch model.primaryActionTitle(for: row) {
        case "Pause": return "Stops the download. What has already arrived is kept."
        case "Resume": return "Carries on from where the download stopped."
        case "Remove": return "Deletes the downloaded files. You can download them again later."
        case "Download Again": return "Fetches the files this version of Synth expects."
        default: return "Downloads \(InstrumentCatalogDisplay.size(row.library.downloadByteCount))."
        }
    }
}

/// What the owner is actually getting, and what is thin about it.
private struct InstrumentList: View {
    let library: CatalogLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(library.coverage, id: \.identifier) { instrument in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(instrument.name)
                            .font(.caption.weight(.medium))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(InstrumentCatalogDisplay.qualitySummary(instrument))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(instrument.qualityNotes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    ([
                        instrument.name,
                        instrument.family.displayName,
                        InstrumentCatalogDisplay.qualitySummary(instrument)
                    ] + instrument.qualityNotes).joined(separator: ". ")
                )
            }
        }
        .padding(.leading, 8)
        .padding(.top, 2)
    }
}

/// A failure, and the one thing worth doing about it.
private struct FailureNote: View {
    let libraryName: String
    let failure: InstrumentCatalogModel.Failure
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.summary)
                    .font(.caption)
                if let recovery = failure.recovery {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if failure.isRetryable {
                Button("Retry", action: retry)
                    .controlSize(.small)
                    .accessibilityLabel("Retry the \(libraryName) download")
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("instrument-library-failure")
    }
}

// MARK: - Licence

/// The licence and the credit, in full, for a downloaded or downloadable
/// library (REQ-020's "licenses viewable in-app").
private struct LicenceSheet: View {
    let library: CatalogLibrary
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.name).font(.headline)
                Text("by \(library.publisher)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(library.licence.name).font(.body.weight(.medium))
                Text(InstrumentCatalogDisplay.licence(library))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                // No force-unwrap over catalog data: the asset URLs get an
                // HTTPS validation pass and these two do not, so a typo in a
                // future catalog entry should leave the sheet readable rather
                // than crash it.
                if let url = URL(string: library.licence.textURL) {
                    Link(library.licence.textURL, destination: url).font(.caption)
                } else {
                    Text(library.licence.textURL).font(.caption).textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(library.licence.name). \(InstrumentCatalogDisplay.licence(library))"
            )

            if let attribution = InstrumentCatalogDisplay.attribution(library) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Credit this as").font(.caption.weight(.semibold))
                    Text(attribution)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Credit") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(attribution, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityHint("Copies the credit line to the clipboard.")
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("instrument-licence-attribution")
            }

            if let url = URL(string: library.homepageURL) {
                Link("About this library", destination: url).font(.caption)
            }

            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    // Distinct from the catalog header's Done, which is a
                    // different button doing a different thing one window away.
                    .accessibilityIdentifier("instrument-licence-done")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("instrument-licence-sheet")
    }
}

// MARK: - First run

/// The offer, and the fact that declining it costs nothing.
private struct FirstRunOffer: View {
    let byteCount: Int64
    let libraryCount: Int
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(InstrumentCatalogDisplay.firstRunOfferTitle())
                .font(.headline)
            Text(
                InstrumentCatalogDisplay.firstRunOfferBody(
                    byteCount: byteCount, libraryCount: libraryCount
                )
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Everything else keeps working; pieces play synth sounds.")
                Button("Download") { answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Starts downloading every curated library.")
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityIdentifier("instrument-first-run-offer")
    }
}
