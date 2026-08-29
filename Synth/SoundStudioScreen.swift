import SwiftUI
import SynthKit

/// The sound-design surface: the library on the left, the front panel on the
/// right, and a keyboard under it.
///
/// **Laid out as a polysynth's front panel, not as a patch bay (D6).** The
/// panels run in signal order — three oscillators, the mixer, the filter, the
/// two envelopes, the LFOs, the matrix, then the four effects and the voice
/// itself — and every one of them is always there. There is no way to add a
/// stage, no routing to draw, and nothing to connect, because there is nothing
/// in the architecture that varies except the numbers.
///
/// Everything here is reachable from the keyboard. The list is a `List` with a
/// selection binding; every parameter has a text field as well as a slider; the
/// on-screen keys are ordinary buttons; and every action also has a menu
/// command with a shortcut in `SoundCommands`.
struct SoundStudioScreen: View {
    @Bindable var model: SoundStudioModel

    /// Leaves the studio and goes back to whatever was showing before. A
    /// closure rather than a dependency on `AppModel`, so the studio knows
    /// nothing about what else the window can show.
    let close: () -> Void

    @FocusState private var focus: Field?

    fileprivate enum Field: Hashable {
        case search
        case list
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(model: model, searchFocus: $focus, close: close)
            Divider()

            HStack(spacing: 0) {
                soundList
                    .frame(width: 280)
                Divider()
                // Exactly one editor at a time, chosen by what is selected. A
                // synth patch and a downloaded instrument are edited by
                // completely different controls, and showing either set over
                // the other kind would be a panel full of knobs that do nothing.
                if model.isEditingInstrument {
                    InstrumentEditorPane(
                        model: model.instrumentEditor,
                        saveAsVariant: { model.beginVariantNaming() }
                    )
                } else {
                    SoundEditorPane(model: model.editor, duplicateToEdit: duplicateToEdit)
                }
            }
            // The destructive confirmation is attached *here* rather than
            // beside the failure alert below, and that is not cosmetic. Both
            // presentations on one view meant neither of them appeared:
            // driving the app showed the Delete command running, the model's
            // `pendingDeletion` set, and `NSApp.windows` reporting no sheet and
            // no panel at all. One presentation per view, and both work.
            //
            // An alert rather than a `confirmationDialog` for the same reason
            // the piece library's works: it is the presentation this screen
            // already raises for failures, and it is the conventional shape for
            // a destructive confirmation on macOS.
            .alert(
                model.pendingDeletion.map { "Delete “\($0.name)” from your sounds?" } ?? "",
                isPresented: deletionConfirmationBinding,
                presenting: model.pendingDeletion
            ) { entry in
                Button("Delete Sound", role: .destructive) { model.confirmDeletion(of: entry) }
                Button("Cancel", role: .cancel) { model.cancelDeletion() }
            } message: { _ in
                // REQ-029's warning, and the exact count rather than a
                // reassuring generality: ASN001's `usage(ofSoundID:)` knows how
                // many presets and how many pieces this touches, and an owner
                // deciding whether to delete a sound is entitled to that number.
                Text(model.pendingDeletionWarning)
            }

            // The status bar is a row of this stack, not a `safeAreaInset`.
            // The library screen can use an inset because its content is one
            // `List` that knows how to inset its own scroll view; this screen
            // is a fixed split, and the capture from the frozen candidate
            // showed the list's last row drawn straight through the bar's
            // translucent background.
            Divider()
            StudioStatusBar(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            currentAlert?.title ?? "",
            isPresented: alertBinding,
            presenting: currentAlert
        ) { _ in
            Button("OK") { model.alert = nil; model.editor.alert = nil }
        } message: { alert in
            Text([alert.message, alert.recovery].compactMap { $0 }.joined(separator: "\n\n"))
        }
        // The variant name is a sheet rather than a third alert: this view
        // already carries a failure alert and the split below carries the
        // destructive confirmation, and two presentations on one view meant
        // neither of them appeared (see the note on the delete alert above).
        .sheet(isPresented: variantNamingBinding) {
            VariantNameSheet(model: model)
        }
        .onChange(of: model.searchFocusRequests) { _, _ in focus = .search }
        .onChange(of: model.listFocusRequests) { _, _ in focus = .list }
        .task {
            model.reload()
            model.editor.startAuditionIfNeeded()
        }
        .onDisappear { model.editor.suspend() }
    }

    // MARK: The list

    @ViewBuilder
    private var soundList: some View {
        if model.isLibraryEmpty {
            ContentUnavailableView {
                Label("No sounds yet", systemImage: "waveform")
            } description: {
                Text("Synth ships a collection of sounds; if this is empty the library could not be read.")
            }
        } else if model.isSearchEmpty {
            ContentUnavailableView {
                Label("No matching sounds", systemImage: "magnifyingglass")
            } description: {
                Text("No sound matches “\(model.searchText)”.")
            } actions: {
                Button("Clear the Search") { model.clearSearch() }
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.visibleByCategory, id: \.category) { group in
                    Section(group.category.displayName) {
                        ForEach(group.sounds) { entry in
                            SoundRow(entry: entry, model: model)
                                .tag(entry.id)
                        }
                    }
                }
            }
            .focused($focus, equals: .list)
            .onDeleteCommand { model.requestDeletionOfSelection() }
            .accessibilityLabel("Sound library")
            .accessibilityHint("Choose a sound with the up and down arrow keys. Press Delete to remove it.")
        }
    }

    /// The shipped-sound path: make a copy, and select it so the owner is
    /// immediately editing the thing they can actually change.
    private func duplicateToEdit() {
        guard let copy = model.editor.duplicateForEditing() else { return }
        model.reload()
        model.selection = copy.id
    }

    private var currentAlert: SoundAlert? { model.alert ?? model.editor.alert }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { currentAlert != nil },
            set: { if !$0 { model.alert = nil; model.editor.alert = nil } }
        )
    }

    private var variantNamingBinding: Binding<Bool> {
        Binding(
            get: { model.isNamingVariant },
            set: { if !$0 { model.cancelVariantNaming() } }
        )
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelDeletion() } }
        )
    }
}

// MARK: - One sound in the list

private struct SoundRow: View {
    let entry: SoundEntry
    let model: SoundStudioModel

    /// Focus goes to the rename field the moment it appears.
    ///
    /// Without this a rename started from the keyboard puts a text field on
    /// screen that the keyboard is not in, which is a rename nobody can
    /// complete without reaching for the mouse — the opposite of what REQ-027
    /// asks of the command that opened it.
    @FocusState private var isRenaming: Bool

    var body: some View {
        HStack(spacing: 8) {
            if model.renaming?.id == entry.id {
                TextField("Name", text: Binding(get: { model.renameText },
                                                set: { model.renameText = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .focused($isRenaming)
                    .onAppear { isRenaming = true }
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .accessibilityLabel("New name for \(entry.name)")
            } else {
                Text(entry.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.origin == .user, entry.kind == .instrument {
                    // A variant of the owner's own: editable, and worth telling
                    // apart from a synth patch at a glance because the two are
                    // edited by different panels.
                    Image(systemName: "pianokeys")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if entry.origin != .user {
                    // The read-only marker (REQ-017 for a shipped sound,
                    // REQ-021's read-only assets for a downloaded instrument),
                    // said in the row rather than discovered when an edit is
                    // refused.
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityDescription)
        .contextMenu {
            Button(entry.origin == .instrument ? "Save as Variant" : "Duplicate") {
                model.duplicate(entry)
            }
            Button("Rename…") { model.beginRename(of: entry) }
                .disabled(!entry.isEditable)
            Divider()
            Menu("Move to Category") {
                ForEach(SoundCategory.allCases, id: \.self) { category in
                    Button(category.displayName) {
                        model.selection = entry.id
                        model.recategorizeSelected(to: category)
                    }
                    .disabled(!entry.isEditable || entry.category == category)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                model.selection = entry.id
                model.requestDeletionOfSelection()
            }
            .disabled(!entry.isEditable)
        }
    }
}

// MARK: - Toolbar

private struct StudioToolbar: View {
    @Bindable var model: SoundStudioModel
    @FocusState.Binding var searchFocus: SoundStudioScreen.Field?
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Label("Close", systemImage: "chevron.left")
            }
            .accessibilityLabel("Close the sound studio")
            .accessibilityHint("Goes back to the library or the piece you had open.")

            Divider().frame(height: 18)

            searchField

            Spacer(minLength: 8)

            Button { model.createSound() } label: {
                Label("New", systemImage: "plus")
            }
            .accessibilityLabel("Create a sound from scratch")
            .accessibilityHint("Adds a new sound to your library and opens it for editing.")

            Button { model.duplicateSelected() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .accessibilityLabel("Duplicate the selected sound")
            .accessibilityHint("Makes an editable copy of your own. The original is unchanged.")
            .disabled(model.selectedSound == nil)

            Button { model.beginRename() } label: {
                Label("Rename", systemImage: "pencil")
            }
            .accessibilityLabel("Rename the selected sound")
            .disabled(model.selectedSound?.isEditable != true)

            Button(role: .destructive) { model.requestDeletionOfSelection() } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete the selected sound")
            .accessibilityHint("Asks for confirmation before deleting it.")
            .disabled(model.selectedSound?.isEditable != true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search sounds", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocus, equals: .search)
                .accessibilityLabel("Search your sounds")
                .accessibilityHint("Finds sounds whose name or category contains what you type.")

            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: {
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
        .frame(maxWidth: 240)
    }
}

// MARK: - The editor pane

private struct SoundEditorPane: View {
    @Bindable var model: SoundEditorModel
    let duplicateToEdit: () -> Void

    var body: some View {
        if model.isOpen {
            VStack(spacing: 0) {
                EditorHeader(model: model, duplicateToEdit: duplicateToEdit)
                Divider()
                panels
                Divider()
                TestKeyboard(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No sound selected", systemImage: "slider.horizontal.3")
            } description: {
                Text("Choose a sound on the left to edit it, or press ⌘N to build one from scratch.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **A plain `VStack`, not a `LazyVStack`.**
    ///
    /// A lazy stack only builds the panels that are on screen, and a control
    /// that has not been built is not in the accessibility tree and is not in
    /// the keyboard's focus ring. Driving the running app showed exactly that:
    /// with a lazy stack, only Oscillator 1 and 2 existed and the other thirteen
    /// panels were unreachable by anything but scrolling to them with a mouse
    /// first. REQ-027 is about reaching every control, so every control has to
    /// exist. The panels are collapsible for anyone who wants the shorter page.
    private var panels: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SynthParameter.groups, id: \.name) { group in
                    ParameterPanel(
                        title: group.name,
                        parameters: group.parameters,
                        model: model,
                        collapsedGroups: $model.collapsedGroups
                    )
                }
            }
            .padding(16)
        }
    }
}

/// What is being edited, whether it can be, and the two things to do about it.
private struct EditorHeader: View {
    @Bindable var model: SoundEditorModel
    let duplicateToEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(model.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Editing \(model.title). \(model.subtitle).")

                Spacer(minLength: 8)

                if model.isShipped {
                    Button { duplicateToEdit() } label: {
                        Label("Duplicate to Edit", systemImage: "plus.square.on.square")
                    }
                    // No `.defaultAction`: the studio has a search field and a
                    // hundred numeric fields, and Return in any of them has to
                    // mean "commit what I typed" rather than "make a copy".
                    // ⇧⌘D does the same thing from the keyboard.
                    .accessibilityLabel("Duplicate this sound to edit it")
                    .accessibilityHint("Synth's own sounds cannot be changed. This makes a copy "
                                       + "of your own and leaves the original as it is.")
                } else {
                    Button("Revert") { model.revert() }
                        .disabled(!model.hasUnsavedChanges)
                        .accessibilityHint("Puts every parameter back to the saved version.")

                    Button { model.save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    // ⌘S belongs to the menu item; declaring it here as well
                    // gives AppKit two claims on one key.
                    .disabled(!model.hasUnsavedChanges)
                    .accessibilityLabel("Save this sound")
                    .accessibilityHint("Also on the Sounds menu, as Command-S.")
                }
            }

            if model.isShipped {
                Label(
                    "This is one of Synth's own sounds, so it is read-only. "
                    + "Duplicate it to make it yours; the original stays exactly as it is.",
                    systemImage: "lock.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Read-only. This is one of Synth's own sounds. "
                                    + "Duplicate it to make an editable copy; the original stays as it is.")
            } else if model.hasUnsavedChanges {
                Label("Unsaved changes — you are hearing them, but they are not stored yet.",
                      systemImage: "pencil.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if let saved = model.lastSavedDescription {
                Text(saved)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - The keyboard

/// Test notes, with no piece behind them.
///
/// Two octaves from C3, as ordinary buttons rather than a drawn keyboard with
/// hit testing. A button is focusable, activates on Space and Return, carries a
/// VoiceOver label for free, and works with Full Keyboard Access off — which a
/// custom-drawn key would not, and REQ-027 is about the keyboard rather than
/// about how convincing the drawing is.
private struct TestKeyboard: View {
    @Bindable var model: SoundEditorModel

    /// C3 to C5. Low enough for a bass patch to be judged, high enough for a
    /// lead, and short enough to fit under the panels without scrolling.
    private static let lowestNote = 48
    private static let noteCount = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Test notes")
                    .font(.headline)

                Button { model.playTestChord() } label: {
                    Label("Play Chord", systemImage: "play.fill")
                }
                .accessibilityLabel("Play a test chord")
                .accessibilityHint("Plays a C major triad so you can hear the whole sound at once.")

                Button { model.releaseEverything() } label: {
                    Label("All Notes Off", systemImage: "stop.fill")
                }
                .accessibilityLabel("Stop every test note")

                Divider().frame(height: 16)

                Toggle(isOn: Binding(
                    get: { model.isPlayingPieceThroughSound },
                    set: { $0 ? model.startPlayingPieceThroughSound()
                              : model.stopPlayingPieceThroughSound() }
                )) {
                    Text("Play the open piece through this sound")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.isOpen)
                .accessibilityLabel("Play the open piece through this sound")
                .accessibilityHint("Routes the piece you have open through the sound you are "
                                   + "editing, so a parameter change is audible in real music "
                                   + "while it keeps playing.")

                Spacer(minLength: 0)

                if let failure = model.auditionFailure {
                    Label(failure, systemImage: "speaker.slash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            // No label on the row itself: a label on a container is inherited
            // by every child, and driving the running app showed all
            // twenty-five keys reading back as "Test keyboard, two octaves from
            // C3" instead of as the notes they are. `children: .contain` keeps
            // the grouping without taking the keys' own names away.
            HStack(spacing: 2) {
                ForEach(0..<Self.noteCount, id: \.self) { offset in
                    let note = Self.lowestNote + offset
                    KeyButton(note: note, model: model)
                }
            }
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct KeyButton: View {
    let note: Int
    @Bindable var model: SoundEditorModel

    /// Set by the drag gesture on mouse-down, so the `Button` action that
    /// follows on mouse-up knows the pointer already played this note.
    ///
    /// **A key has two activation paths and a pointer click runs both.** The
    /// `Button` is what the keyboard and VoiceOver activate; the drag gesture
    /// is what gives press-and-hold, so a note can be sustained while a knob is
    /// moved. Both are needed. But driving the app showed a plain click firing
    /// each of them, which struck the note twice — a blip from the gesture's
    /// press and release, then a half-second note from the button — on the very
    /// first thing an owner tries, and sounding like an engine fault rather
    /// than a routing one.
    ///
    /// A pointer press always delivers `onChanged` on mouse-down, before the
    /// button's action on mouse-up, so this flag is always set in time. It is
    /// cleared on the next main-actor turn rather than in `onEnded`, because
    /// `onEnded` runs *before* the button action and clearing there would let
    /// the second note through again.
    @State private var pointerIsPlaying = false

    private var isBlack: Bool { [1, 3, 6, 8, 10].contains(note % 12) }
    private var isSounding: Bool { model.soundingNotes.contains(note) }

    var body: some View {
        Button {
            // Keyboard and VoiceOver only. A `Button` has no press-and-hold, so
            // this plays and releases; the pointer's press-and-hold is the
            // gesture below, and this stands aside when that already ran.
            guard !pointerIsPlaying else { return }
            model.noteOn(note)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                model.noteOff(note)
            }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(keyColor)
                .frame(width: isBlack ? 18 : 24, height: isBlack ? 44 : 64)
                .overlay(alignment: .bottom) {
                    if note % 12 == 0 {
                        Text("C\(note / 12 - 1)")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 2)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        // Press-and-hold, so a sustained note can be listened to while a knob
        // is moved. `minimumDistance: 0` makes it fire on the press itself
        // rather than waiting for movement.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    pointerIsPlaying = true
                    model.noteOn(note)
                }
                .onEnded { _ in
                    model.noteOff(note)
                    // After the button action for this click, not before it.
                    Task { @MainActor in pointerIsPlaying = false }
                }
        )
        .accessibilityLabel(Self.name(of: note))
        .accessibilityValue(isSounding ? "Sounding" : "")
        .accessibilityHint("Plays this note with the sound you are editing.")
        .disabled(!model.isOpen)
    }

    private var keyColor: Color {
        if isSounding { return .accentColor }
        return isBlack ? Color.black.opacity(0.75) : Color.white.opacity(0.9)
    }

    /// "C4", "F sharp 3" — spelled out, because VoiceOver reads "F#3" as a
    /// hash sign.
    static func name(of note: Int) -> String {
        let names = ["C", "C sharp", "D", "E flat", "E", "F",
                     "F sharp", "G", "A flat", "A", "B flat", "B"]
        return "\(names[note % 12]) \(note / 12 - 1)"
    }
}

// MARK: - Status bar

private struct StudioStatusBar: View {
    @Bindable var model: SoundStudioModel

    var body: some View {
        HStack(spacing: 16) {
            Text(model.countDescription)
                .accessibilityLabel(model.countDescription)

            Divider().frame(height: 14)

            Text("\(model.shippedSoundCount) shipped · \(model.userSoundCount) yours")
                .accessibilityLabel("\(model.shippedSoundCount) shipped sounds, "
                                    + "\(model.userSoundCount) of your own")

            if model.editor.isPlayingPieceThroughSound {
                Divider().frame(height: 14)
                Label("Piece playing through this sound", systemImage: "waveform.badge.magnifyingglass")
                    .accessibilityLabel("The open piece is playing through the sound you are editing")
            }

            Spacer(minLength: 8)

            if let status = model.editor.statusMessage ?? model.statusMessage {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
    }
}

// MARK: - Naming a variant (REQ-023)

/// Names a new instrument variant before it is saved.
///
/// A sheet with a text field and two buttons, focused the moment it appears, so
/// a variant started from the keyboard can be finished from the keyboard — the
/// point every rename field on this screen had to learn (REQ-027).
private struct VariantNameSheet: View {
    @Bindable var model: SoundStudioModel

    @FocusState private var isNaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save as a named variant")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("This saves your settings as a sound of your own, assignable to any line. "
                 + "The downloaded instrument itself is not changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Variant name", text: $model.variantNameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($isNaming)
                .onAppear { isNaming = true }
                .onSubmit { model.commitVariantNaming() }
                .onExitCommand { model.cancelVariantNaming() }
                .accessibilityLabel("Name for this variant")
                .accessibilityHint("Type a name and press Return.")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelVariantNaming() }
                Button("Save Variant") { model.commitVariantNaming() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.variantNameDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
