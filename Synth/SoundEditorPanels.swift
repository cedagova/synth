import SwiftUI
import SynthKit

/// One panel of the front panel: a heading and the controls under it.
///
/// Collapsible, but open by default. A synthesizer does not hide its filter
/// behind a disclosure triangle, and D6's "fixed but rich" only reads as rich
/// if the owner can see what there is to move.
struct ParameterPanel: View {
    let title: String
    let parameters: [SynthParameter]
    let model: SoundEditorModel

    @Binding var collapsedGroups: Set<String>

    private var isCollapsed: Bool { collapsedGroups.contains(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isCollapsed { collapsedGroups.remove(title) } else { collapsedGroups.insert(title) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) panel")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint("Shows or hides the \(parameters.count) controls in this panel.")

            if !isCollapsed {
                VStack(spacing: 6) {
                    ForEach(parameters) { parameter in
                        ParameterRow(parameter: parameter, model: model)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One parameter, whichever kind it is.
///
/// The row is built from the descriptor rather than written by hand, which is
/// what makes "every parameter is editable" a property of `SynthParameter.all`
/// instead of a claim about how carefully this file was typed. It also means
/// every control gets the same three things without anyone remembering to add
/// them: a label, a help tag, and a VoiceOver hint that says the same thing the
/// help tag does.
struct ParameterRow: View {
    let parameter: SynthParameter
    let model: SoundEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
                .accessibilityHidden(true)

            control
        }
        .help(parameter.detail)
        .disabled(!model.isEditable)
    }

    @ViewBuilder
    private var control: some View {
        switch parameter.kind {
        case .number:
            ParameterNumberControl(parameter: parameter, model: model)
        case .integer(let range):
            ParameterStepperControl(parameter: parameter, model: model, range: range)
        case .flag:
            ParameterToggleControl(parameter: parameter, model: model)
        case .option(let values, let labels):
            ParameterOptionControl(parameter: parameter, model: model, values: values, labels: labels)
        }
    }
}

// MARK: - Continuous

/// A slider and a typed field for the same number.
///
/// Both, rather than one or the other, and for two different reasons. The
/// slider is how a sound is *found* — a cutoff is swept, not calculated — and
/// it is the control the live-editing path exists for. The field is how a
/// number is *stated*, and it is the one that is unconditionally reachable
/// from the keyboard whether or not Full Keyboard Access is switched on, which
/// is what REQ-027 needs to be true of every parameter rather than of most.
private struct ParameterNumberControl: View {
    let parameter: SynthParameter
    let model: SoundEditorModel

    /// What is in the field while it is being typed in.
    ///
    /// Separate from the patch, because a half-typed "1" on the way to "1200"
    /// must not become a cutoff of 20 Hz and then snap the slider under the
    /// owner's hand. The value is committed on Return or when focus leaves.
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    private var number: Double { model.value(for: parameter.id)?.numberValue ?? 0 }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { parameter.normalized(number) },
            set: { model.setValue(.number(parameter.denormalized($0)), for: parameter.id) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            // A stock `Slider`, left as one.
            //
            // Wrapping it in `.accessibilityElement()` with a hand-written
            // adjustable action was tried, so that VoiceOver would read the
            // cutoff as "3 kilohertz" rather than as "0.725" — SwiftUI's own
            // value for a slider is its position along its travel, and
            // `.accessibilityValue` does not displace it. Driving the running
            // app showed that cure to be worse than the complaint: the control
            // stopped being an `AXSlider` at all and became an `AXUnknown`,
            // losing the role that tells an assistive client it is adjustable
            // in the first place.
            //
            // So the slider stays a slider — labelled, hinted, adjustable by
            // the arrow keys, reading its position — and the field beside it is
            // where the value is stated in the units the parameter is in. The
            // pair is what makes a parameter both findable by ear and legible;
            // the field is also the half that is keyboard-reachable with Full
            // Keyboard Access off.
            Slider(value: sliderBinding, in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(parameter.accessibilityLabel)
                .accessibilityValue(parameter.spokenValue(for: .number(number)))
                .accessibilityHint(parameter.detail
                                   + " The field beside this slider states the value.")

            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 92)
                .focused($isFieldFocused)
                .onSubmit(commit)
                .onChange(of: isFieldFocused) { _, focused in
                    if focused { draft = Self.editableText(number) } else { commit() }
                }
                .onChange(of: number) { _, _ in
                    if !isFieldFocused { draft = parameter.displayText(for: .number(number)) }
                }
                .onAppear { draft = parameter.displayText(for: .number(number)) }
                .accessibilityLabel("\(parameter.accessibilityLabel) value")
                .accessibilityValue(parameter.spokenValue(for: .number(number)))
                .accessibilityHint("Type a value and press Return. Anything outside the range is "
                                   + "brought back into it.")
        }
    }

    /// The value as a plain number, for editing — no unit, no thousands
    /// separator, and the same units the parameter is stored in.
    private static func editableText(_ number: Double) -> String {
        var text = String(format: "%.4f", number)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Take what was typed, clamp it, and show what actually happened.
    ///
    /// A field that cannot be read at all goes back to the value it had rather
    /// than to zero: an owner who typed nonsense meant to type something, and
    /// silently setting a cutoff to 20 Hz because of a stray keystroke is worse
    /// than doing nothing.
    private func commit() {
        let cleaned = draft
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" || $0 == "E" || $0 == "+" }

        if let typed = Double(cleaned) {
            model.setValue(.number(parameter.clamp(typed)), for: parameter.id)
        }
        draft = parameter.displayText(for: .number(number))
    }
}

// MARK: - Whole numbers

private struct ParameterStepperControl: View {
    let parameter: SynthParameter
    let model: SoundEditorModel
    let range: ClosedRange<Int>

    private var number: Int { model.value(for: parameter.id)?.integerValue ?? range.lowerBound }

    /// The filter's slope is the one whole-number parameter with a gap in it:
    /// two poles or four, never three.
    private var step: Int {
        if case .filterPoles = parameter.id { return 2 }
        return 1
    }

    var body: some View {
        HStack(spacing: 8) {
            Stepper(
                value: Binding(
                    get: { number },
                    set: { model.setValue(.integer($0), for: parameter.id) }
                ),
                in: range,
                step: step
            ) {
                Text(parameter.displayText(for: .integer(number)))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 64, alignment: .leading)
            }
            .accessibilityLabel(parameter.accessibilityLabel)
            .accessibilityValue(parameter.displayText(for: .integer(number)))
            .accessibilityHint(parameter.detail)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Switches

private struct ParameterToggleControl: View {
    let parameter: SynthParameter
    let model: SoundEditorModel

    private var flag: Bool { model.value(for: parameter.id)?.flagValue ?? false }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { flag },
                    set: { model.setValue(.flag($0), for: parameter.id) }
                )
            ) {
                Text(parameter.displayText(for: .flag(flag)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(parameter.accessibilityLabel)
            .accessibilityValue(parameter.displayText(for: .flag(flag)))
            .accessibilityHint(parameter.detail)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Closed sets

private struct ParameterOptionControl: View {
    let parameter: SynthParameter
    let model: SoundEditorModel
    let values: [String]
    let labels: [String]

    private var raw: String { model.value(for: parameter.id)?.optionValue ?? values.first ?? "" }

    var body: some View {
        HStack(spacing: 8) {
            Picker(
                "",
                selection: Binding(
                    get: { raw },
                    set: { model.setValue(.option($0), for: parameter.id) }
                )
            ) {
                ForEach(Array(zip(values, labels)), id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)
            .accessibilityLabel(parameter.accessibilityLabel)
            .accessibilityValue(parameter.displayText(for: .option(raw)))
            .accessibilityHint(parameter.detail)

            Spacer(minLength: 0)
        }
    }
}
