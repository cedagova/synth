import SwiftUI
import SynthKit

/// The assignment and mixing surface: which sound each line plays, how it sits
/// in the mix, and which preset is showing (REQ-005, REQ-006, REQ-008,
/// REQ-024, REQ-027).
///
/// **A list of named lines, and no notation** (D2). There is no stave, no
/// timeline and no piano roll here on purpose: the thing the owner is choosing
/// is which of four voices is which, and a name does that better than a system
/// of music the app has already said it will not draw.
///
/// Two layout rules are inherited from SYN003 and are not cosmetic:
///
/// * **A plain `VStack`, never a `LazyVStack`.** A lazy stack only builds the
///   rows that are on screen, and a control that has not been built is outside
///   both the keyboard's focus ring and the accessibility tree. An eighteen-line
///   orchestral score must be entirely reachable.
/// * **One presentation per view.** Two `.alert`s on the same view meant
///   neither of them ever appeared; the destructive confirmation therefore sits
///   on the preset bar and the failure alert on the panel.
struct AssignmentPanel: View {
    @Bindable var model: AssignmentModel

    @FocusState private var focusedLine: ScoreLineID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PresetBar(model: model)
            Divider()

            // A line that is silent because its instrument is missing must not
            // be something the owner only finds by scrolling to it (issue #24).
            if let banner = model.instrumentBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.18))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(banner)
                    .accessibilityAddTraits(.updatesFrequently)
                Divider()
            }

            if model.isReady {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.lines) { line in
                            LineStrip(model: model, line: line, focus: $focusedLine)
                            Divider()
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No lines yet", systemImage: "slider.horizontal.3")
                } description: {
                    Text("The line list appears once the piece has been compiled.")
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            MixSummaryBar(model: model)
        }
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.18))
        .alert(
            model.alert?.title ?? "",
            isPresented: alertBinding,
            presenting: model.alert
        ) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text([alert.message, alert.recovery].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .onChange(of: model.lineFocusRequests) { _, _ in focusedLine = model.selectedLineID }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }
}

// MARK: - Presets (REQ-024)

private struct PresetBar: View {
    @Bindable var model: AssignmentModel

    /// Focus goes to the rename field the moment it appears, so a rename
    /// started from the keyboard can be finished from the keyboard — the point
    /// the sound studio's own rename had to learn.
    @FocusState private var isRenaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Preset")

            HStack(spacing: 8) {
                if model.isRenamingPreset {
                    TextField("Preset name", text: $model.presetNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isRenaming)
                        .onAppear { isRenaming = true }
                        .onSubmit { model.commitPresetRename() }
                        .onExitCommand { model.cancelPresetRename() }
                        .accessibilityLabel("Preset name")
                        .accessibilityHint("Type a name and press Return.")
                    Button("Done") { model.commitPresetRename() }
                        .accessibilityLabel("Finish renaming this preset")
                } else {
                    // The picker's own title is its accessible name. Adding
                    // `.accessibilityLabel` beside it does not replace that
                    // title, it prefixes it — the live tree read back
                    // "Preset, Active preset", which is what VoiceOver would
                    // have said.
                    Picker("Active preset", selection: presetSelection) {
                        ForEach(model.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 140)
                    .accessibilityValue(model.spokenPreset)
                    .accessibilityHint(
                        "Switching applies at once — every preset is already saved."
                    )

                    Button {
                        model.createPreset()
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .accessibilityLabel("New preset from this one")
                    .accessibilityHint("Also on the Mix menu as Control Command P.")

                    Button {
                        model.beginPresetRename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Rename this preset")

                    Button(role: .destructive) {
                        model.requestPresetDeletion()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Delete this preset")
                }
            }

            // REQ-024's auto-save indication. There is no Save button because
            // there is nothing to save: every change is one committed
            // transaction, and the revision is the proof it happened.
            Label(model.autoSaveText, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.autoSaveText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(
            model.pendingPresetDeletion.map { "Delete the preset “\($0.name)”?" } ?? "",
            isPresented: deletionBinding,
            presenting: model.pendingPresetDeletion
        ) { preset in
            Button("Delete Preset", role: .destructive) {
                model.confirmPresetDeletion(of: preset)
            }
            Button("Cancel", role: .cancel) { model.cancelPresetDeletion() }
        } message: { preset in
            Text(deletionMessage(for: preset))
        }
    }

    private func deletionMessage(for preset: Preset) -> String {
        let others = model.presets.count - 1
        guard others > 0 else {
            return "This is the only preset this piece has, so Synth will put a fresh one in "
                + "its place with each line back on its automatically chosen sound. Your "
                + "sounds themselves are not touched."
        }
        let rest = others == 1
            ? "The piece's other preset"
            : "The piece's other \(others) presets"
        return "This removes “\(preset.name)” and its mix. \(rest) and all of your sounds are "
            + "untouched."
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { model.activePreset?.id ?? "" },
            set: { model.activate(presetID: $0) }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { model.pendingPresetDeletion != nil },
            set: { if !$0 { model.cancelPresetDeletion() } }
        )
    }
}

// MARK: - One line (REQ-005, REQ-006, REQ-008)

private struct LineStrip: View {
    @Bindable var model: AssignmentModel
    let line: ResolvedLine
    @FocusState.Binding var focus: ScoreLineID?

    @FocusState private var isRenaming: Bool

    private var isSelected: Bool { model.selectedLineID == line.lineID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            nameRow
            soundRow
            mixRow
            if let note = AssignmentDisplay.sourceNote(line.source) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            instrumentAdviceRows
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
        .overlay(alignment: .leading) {
            // Which strip the Mix menu's commands will act on, visible without
            // having to look for a focus ring.
            Rectangle()
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(width: 3)
        }
    }

    // MARK: The name

    @ViewBuilder
    private var nameRow: some View {
        if model.renamingLineID == line.lineID {
            HStack(spacing: 6) {
                TextField("Line name", text: $model.lineNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isRenaming)
                    .onAppear { isRenaming = true }
                    .onSubmit { model.commitLineRename() }
                    .onExitCommand { model.cancelLineRename() }
                    .accessibilityLabel("Name for this line")
                    .accessibilityHint("Type a name and press Return. Escape leaves it as it was.")
                Button("Done") { model.commitLineRename() }
                    .accessibilityLabel("Finish renaming this line")
            }
        } else {
            HStack(spacing: 6) {
                // The whole strip's sentence lives on this one element rather
                // than on the row, because a label on a container is inherited
                // by every control inside it — the defect SYN003's keyboard
                // found. Here it is a real, focusable button of its own.
                Button {
                    model.selectedLineID = line.lineID
                } label: {
                    Text(line.name)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .focused($focus, equals: line.lineID)
                .accessibilityLabel(AssignmentDisplay.spokenStrip(line))
                .accessibilityHint("Selects this line for the Mix menu commands.")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])

                if model.entry(for: line.lineID)?.isRenamed == true {
                    Button {
                        model.resetName(ofLine: line.lineID)
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Put “\(line.name)” back to the name the score gives it")
                }

                Button {
                    model.beginLineRename(line.lineID)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename the line “\(line.name)”")
                .accessibilityHint("Also on the Mix menu as Control Command E.")
            }
        }
    }

    // MARK: The sound

    private var soundRow: some View {
        Picker("Sound for the line “\(line.name)”", selection: soundSelection) {
            // The line's own sound first when it is not something the library
            // can offer — an embedded copy, or a reference that resolved to
            // nothing. Leaving it out would make the picker show some other
            // sound's name beside a line playing this one.
            if !line.source.isLiveLibraryReference {
                Text(line.source.displayName).tag(LineStrip.unassignableTag)
            }
            ForEach(model.paletteByCategory, id: \.category) { group in
                Section(group.category.displayName) {
                    ForEach(group.sounds) { sound in
                        Text(sound.name).tag(sound.id)
                    }
                }
            }
        }
        .labelsHidden()
        .accessibilityValue(line.source.displayName)
        .accessibilityHint("Choosing a sound changes what this line plays straight away.")
    }

    /// The tag used for a selection the library cannot offer back.
    private static let unassignableTag = "\u{0001}not-in-the-library"

    private var soundSelection: Binding<String> {
        Binding(
            get: {
                if case .library(let soundID, _) = line.source { return soundID }
                return LineStrip.unassignableTag
            },
            set: { tag in
                guard tag != LineStrip.unassignableTag else { return }
                model.assign(soundID: tag, toLine: line.lineID)
            }
        )
    }

    // MARK: The instrument flags (issue #24)

    /// Everything the owner has to be told about this line, and the one button
    /// that changes what it plays.
    ///
    /// **A line with a missing instrument is silent until this button is
    /// pressed.** That is the whole gate: quietly playing a synth patch where a
    /// cello was assigned would be the pleasanter failure and the wrong one, so
    /// the line says what is wrong, what it is doing about it, and offers the
    /// substitution as a choice rather than making it.
    @ViewBuilder
    private var instrumentAdviceRows: some View {
        ForEach(Array(line.advice.enumerated()), id: \.offset) { _, advice in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(advice.badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        advice.isSilent
                            ? AnyShapeStyle(.orange.opacity(0.25))
                            : AnyShapeStyle(.secondary.opacity(0.18)),
                        in: Capsule()
                    )
                    .accessibilityHidden(true)

                Text(advice.explanation)
                    .font(.caption)
                    .foregroundStyle(advice.isSilent ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(line.name): \(advice.badge). \(advice.explanation)")
        }

        if let offer = AssignmentDisplay.substitutionOffer(line) {
            Button { model.acceptSubstitution(forLine: line.lineID) } label: {
                Label(offer, systemImage: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityLabel(offer)
            .accessibilityHint(
                "This line is silent because its instrument is missing. Pressing this plays a "
                + "stand-in sound until the instrument is available; downloading the instrument "
                + "puts it back."
            )
        }

        if let withdrawal = AssignmentDisplay.substitutionWithdrawal(line) {
            Button { model.withdrawSubstitution(forLine: line.lineID) } label: {
                Label(withdrawal, systemImage: "speaker.slash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityLabel(withdrawal)
            .accessibilityHint("The line goes back to silence until its instrument is available.")
        }
    }

    // MARK: The mix

    private var mixRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                MixToggle(
                    title: "Mute",
                    symbol: "speaker.slash.fill",
                    isOn: line.mixer.isMuted,
                    label: "Mute the line “\(line.name)”",
                    hint: "Also on the Mix menu as Control Command M."
                ) {
                    model.setMuted(!line.mixer.isMuted, forLine: line.lineID)
                }

                MixToggle(
                    title: "Solo",
                    symbol: "headphones",
                    isOn: line.mixer.isSoloed,
                    label: "Solo the line “\(line.name)”",
                    hint: "While anything is soloed, every line that is not is silent."
                ) {
                    model.setSoloed(!line.mixer.isSoloed, forLine: line.lineID)
                }

                Slider(
                    value: volumeBinding,
                    in: AssignmentDisplay.minimumDecibels...AssignmentDisplay.maximumDecibels,
                    onEditingChanged: { isEditing in
                        // Every intermediate value is heard; only the last one
                        // is written.
                        guard !isEditing else { return }
                        model.commitMixer(forLine: line.lineID, describedAs: "volume")
                    }
                )
                .accessibilityLabel("Volume of the line “\(line.name)”")
                .accessibilityValue(AssignmentDisplay.spokenVolume(line.mixer.volume))
                .accessibilityHint("Arrow keys move it three decibels at a time.")

                Text(AssignmentDisplay.volumeText(line.mixer.volume))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityLabel("Volume of “\(line.name)”")
                    .accessibilityValue(AssignmentDisplay.spokenVolume(line.mixer.volume))
            }

            HStack(spacing: 6) {
                Text("Pan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Slider(
                    value: panBinding,
                    in: -1...1,
                    onEditingChanged: { isEditing in
                        guard !isEditing else { return }
                        model.commitMixer(forLine: line.lineID, describedAs: "pan")
                    }
                )
                .accessibilityLabel("Pan of the line “\(line.name)”")
                .accessibilityValue(AssignmentDisplay.spokenPan(line.mixer.pan))
                .accessibilityHint("Left is negative, right is positive; centre is zero.")

                Text(AssignmentDisplay.panText(line.mixer.pan))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityLabel("Pan of “\(line.name)”")
                    .accessibilityValue(AssignmentDisplay.spokenPan(line.mixer.pan))
            }

            // D7's per-line room send. Beside pan rather than in the instrument
            // editor, because it is a property of how this line sits in this
            // mix and not of what the sound is — which is also why it works the
            // same for a synth line and a sampled one.
            HStack(spacing: 6) {
                Text("Room")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Slider(
                    value: roomSendBinding,
                    in: 0...1,
                    onEditingChanged: { isEditing in
                        guard !isEditing else { return }
                        model.commitMixer(forLine: line.lineID, describedAs: "room send")
                    }
                )
                .accessibilityLabel("Room send of the line “\(line.name)”")
                .accessibilityValue(AssignmentDisplay.spokenRoomSend(line.mixer.roomSend))
                .accessibilityHint("How much of this line reaches the shared room. Zero is dry.")

                Text(AssignmentDisplay.roomSendText(line.mixer.roomSend))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
                    .accessibilityLabel("Room send of “\(line.name)”")
                    .accessibilityValue(AssignmentDisplay.spokenRoomSend(line.mixer.roomSend))
            }
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { AssignmentDisplay.decibels(forVolume: line.mixer.volume) },
            set: {
                model.previewVolume(
                    AssignmentDisplay.volume(forDecibels: $0), forLine: line.lineID
                )
            }
        )
    }

    private var panBinding: Binding<Double> {
        Binding(
            get: { line.mixer.pan },
            set: { model.previewPan($0, forLine: line.lineID) }
        )
    }

    private var roomSendBinding: Binding<Double> {
        Binding(
            get: { line.mixer.roomSend },
            set: { model.previewRoomSend($0, forLine: line.lineID) }
        )
    }
}

/// Mute and solo.
///
/// A `Button` rather than a `Toggle`, deliberately. It is how a mixer draws
/// them, and it is also the only one of the two that an assistive client can
/// press: a SwiftUI `Toggle` refuses `accessibilityPerformPress`, which SYN003
/// found by driving the built app and had to work around with a pointer click.
private struct MixToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let label: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 18)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .secondary)
        .background(
            isOn ? AnyShapeStyle(.tint.opacity(0.30)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - What is actually being heard

private struct MixSummaryBar: View {
    @Bindable var model: AssignmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.mixSummary)
                .font(.caption)
                .accessibilityLabel("Mix: \(model.mixSummary)")
                .accessibilityAddTraits(.updatesFrequently)

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(status)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ResolvedSoundSource {
    /// True when the sound picker can offer this selection back — that is, when
    /// the line holds a live reference to a sound the library still has.
    var isLiveLibraryReference: Bool {
        if case .library = self { return true }
        return false
    }
}
