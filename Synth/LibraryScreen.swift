import SwiftUI
import SynthKit
import UniformTypeIdentifiers

/// The library: browse, search, sort, import, remove.
///
/// Everything here is reachable from the keyboard. The list is a `List` with a
/// selection binding, so arrow keys move between pieces and Return/Delete act
/// on the selected one; the toolbar controls are ordinary focusable buttons and
/// a text field; and the destructive path always goes through a confirmation.
/// Each row is one combined accessibility element whose label is
/// `PieceRecord.accessibilityDescription`, so VoiceOver speaks a piece as a
/// sentence instead of reading three anonymous labels.
struct LibraryScreen: View {
    @Bindable var model: LibraryModel

    /// Opens a piece on the transport screen. A closure rather than a
    /// dependency on `AppModel`, so the library still knows nothing about what
    /// happens after a piece is chosen.
    let open: (PieceRecord) -> Void

    @FocusState private var focus: Field?

    fileprivate enum Field: Hashable {
        case search
        case list
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryToolbar(model: model, searchFocus: $focus, open: open)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole surface is the drop target, so a file dropped anywhere on
        // the window imports — including onto the empty state, which is where
        // a first-time owner is most likely to aim.
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter(Self.hasAcceptedExtension)
            // Files with an extension Synth does not import are still handed to
            // the importer: refusing them silently would leave the owner with
            // no idea why nothing happened. REQ-004 wants the named reason.
            let candidates = accepted.isEmpty ? urls : accepted
            guard !candidates.isEmpty else { return false }
            Task { await model.importPieces(from: candidates) }
            return true
        }
        .fileImporter(
            isPresented: $model.isChoosingFiles,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importPieces(from: urls) }
            case .failure(let error):
                model.alert = LibraryAlert(
                    title: "Could not open the file",
                    message: (error as NSError).localizedDescription,
                    recovery: "Your library is unchanged."
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            LibraryStatusBar(model: model)
        }
        .confirmationDialog(
            model.pendingRemoval.map { "Remove “\($0.title)” from your library?" } ?? "",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { piece in
            Button("Remove Piece", role: .destructive) {
                Task { await model.confirmRemoval(of: piece) }
            }
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
        } message: { piece in
            Text(
                "This permanently removes the stored score for “\(piece.title)” and everything saved with it. "
                + "The file you imported from is not affected."
            )
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: alertBinding,
            presenting: model.alert
        ) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text([alert.message, alert.recovery].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .onChange(of: model.searchFocusRequests) { _, _ in
            focus = .search
        }
        .onChange(of: model.listFocusRequests) { _, _ in
            focus = .list
        }
        .task { await model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLibraryEmpty {
            EmptyLibraryView(model: model)
        } else if model.isSearchEmpty {
            NoSearchResultsView(model: model)
        } else {
            pieceList
        }
    }

    private var pieceList: some View {
        List(selection: $model.selection) {
            ForEach(model.visiblePieces) { piece in
                PieceRow(piece: piece)
                    .tag(piece.id)
            }
        }
        // Double-click opens, the way a list of documents does. A row-level
        // TapGesture would steal the click from the List and break single-click
        // selection on macOS, so both the menu and the open action hang off the
        // List's own selection instead.
        .contextMenu(forSelectionType: PieceRecord.ID.self) { ids in
            if let piece = piece(for: ids) {
                Button("Play Piece") {
                    model.selection = piece.id
                    open(piece)
                }
                Divider()
                Button("Remove Piece…", role: .destructive) {
                    model.requestRemoval(of: piece)
                }
            }
        } primaryAction: { ids in
            if let piece = piece(for: ids) {
                model.selection = piece.id
                open(piece)
            }
        }
        .focused($focus, equals: .list)
        // The Delete key on the selected row. It opens the confirmation rather
        // than removing, which is REQ-003's "explicit confirmation".
        .onDeleteCommand { model.requestRemovalOfSelection() }
        .accessibilityLabel("Library pieces")
        .accessibilityHint("Choose a piece with the up and down arrow keys. Press Delete to remove it.")
    }

    private func piece(for ids: Set<PieceRecord.ID>) -> PieceRecord? {
        guard let id = ids.first else { return nil }
        return model.visiblePieces.first { $0.id == id }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemoval != nil },
            set: { if !$0 { model.cancelRemoval() } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )
    }

    // MARK: - Accepted file types

    private static func hasAcceptedExtension(_ url: URL) -> Bool {
        LibraryModel.acceptedFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// What the open panel offers.
    ///
    /// `.musicxml` and `.mxl` are not system-declared types, so
    /// `UTType(filenameExtension:)` returns a dynamic type for them — which is
    /// exactly what the panel needs to enable files with that extension. If a
    /// type cannot be resolved at all the panel falls back to every file, and
    /// the importer still names and refuses anything it cannot read.
    private static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.xml]
        for fileExtension in LibraryModel.acceptedFileExtensions {
            if let type = UTType(filenameExtension: fileExtension) {
                types.append(type)
            }
        }
        return types.isEmpty ? [.item] : types
    }
}

/// One piece in the list.
private struct PieceRow: View {
    let piece: PieceRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(piece.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(piece.subtitleDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(piece.sourceFormat == .compressedMusicXML ? "MXL" : "MusicXML")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // One element, one sentence: VoiceOver says "Prelude in C, composer
        // Bach, movement 2. Andante" rather than reading each label alone.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(piece.accessibilityDescription)
    }
}

/// Search field, sort control, and the import button.
private struct LibraryToolbar: View {
    @Bindable var model: LibraryModel
    @FocusState.Binding var searchFocus: LibraryScreen.Field?
    let open: (PieceRecord) -> Void

    var body: some View {
        HStack(spacing: 12) {
            searchField

            sortMenu

            Button {
                model.toggleSortDirection()
            } label: {
                Image(systemName: model.sort.direction == .ascending
                      ? "arrow.up"
                      : "arrow.down")
            }
            .help("Reverse the sort order")
            .accessibilityLabel("Sort direction, \(model.sort.direction.label(for: model.sort.field))")
            .accessibilityHint("Reverses the order of the library list.")
            .disabled(model.isLibraryEmpty)

            Divider().frame(height: 18)

            Button {
                if let piece = model.selectedPiece { open(piece) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Play the selected piece")
            .accessibilityHint("Opens it on the transport screen.")
            .disabled(model.selectedPiece == nil || model.isWorking)

            Button {
                model.beginImport()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .accessibilityLabel("Import pieces")
            .accessibilityHint("Opens a file chooser for MusicXML files.")
            .disabled(model.isWorking)

            Button(role: .destructive) {
                model.requestRemovalOfSelection()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove the selected piece")
            .accessibilityHint("Asks for confirmation before removing it.")
            .disabled(model.selectedPiece == nil || model.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search title, composer, movement", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocus, equals: .search)
                .accessibilityLabel("Search the library")
                .accessibilityHint("Finds pieces whose title, composer, work, or movement contains what you type.")

            if !model.searchText.isEmpty {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 320)
        .disabled(model.isLibraryEmpty)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortField.allCases) { field in
                Button {
                    model.sortBy(field)
                } label: {
                    if model.sort.field == field {
                        Label(field.label, systemImage: "checkmark")
                    } else {
                        Text(field.label)
                    }
                }
            }
        } label: {
            Label("Sort by \(model.sort.field.label)", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort by \(model.sort.field.label)")
        .accessibilityHint("Chooses which metadata orders the library list.")
        .disabled(model.isLibraryEmpty)
    }
}

/// First run: the library is empty and the owner needs to know what to do.
private struct EmptyLibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        ContentUnavailableView {
            Label("No pieces yet", systemImage: "music.note.list")
        } description: {
            Text(
                "Import a MusicXML score to get started. "
                + "Drag a \(Self.extensionSentence) file onto this window, or use the Import button."
            )
        } actions: {
            Button("Import a Piece…") { model.beginImport() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens a file chooser for MusicXML files.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ".musicxml, .mxl, or .xml", built from the importer's own list.
    private static var extensionSentence: String {
        let names = LibraryModel.acceptedFileExtensions.map { ".\($0)" }
        guard let last = names.last, names.count > 1 else { return names.first ?? "MusicXML" }
        return names.dropLast().joined(separator: ", ") + ", or " + last
    }
}

/// A search that matched nothing. An empty state, never an error.
private struct NoSearchResultsView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        ContentUnavailableView {
            Label("No matching pieces", systemImage: "magnifyingglass")
        } description: {
            Text("No piece in your library matches “\(model.searchText)”.")
        } actions: {
            Button("Clear the Search") { model.clearSearch() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the library lives, what it holds, and what just happened.
private struct LibraryStatusBar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(model.containerPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "internaldrive")
            }
            .accessibilityLabel("Library folder \(model.containerPath)")

            Divider().frame(height: 14)

            Text("Store schema v\(model.schemaVersion)")
                .accessibilityLabel("Store schema version \(model.schemaVersion)")

            Divider().frame(height: 14)

            Text(countDescription)
                .accessibilityLabel(countDescription)

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            Spacer(minLength: 8)

            if let status = model.statusMessage {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Announced rather than merely displayed, so a VoiceOver
                    // user hears the result of an import or a removal.
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel(status)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// "3 pieces", or "2 of 7 pieces" while a search is narrowing the list.
    private var countDescription: String {
        let total = model.pieces.count
        let shown = model.visiblePieces.count
        let noun = total == 1 ? "piece" : "pieces"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
