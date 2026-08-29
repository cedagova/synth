import SwiftUI
import SynthKit

/// The customization surface for one downloaded instrument (REQ-021, D7).
///
/// **The whole point of this screen is what it refuses to offer.** Every
/// control below is enabled only when the samples the owner actually downloaded
/// can do the thing it claims, and a control that cannot is drawn disabled with
/// the measurement's own sentence under it — "one sampled dynamic layer, so
/// playing harder changes its level but never its tone" — rather than hidden,
/// greyed out anonymously, or worse, left live and doing nothing. That is
/// REQ-021's "degrade visibly, never fake" as a layout rule.
///
/// Two conventions are inherited from SYN003's front panel and are not
/// cosmetic:
///
/// * **A plain `VStack`, never a `LazyVStack`.** A control that has not been
///   built is outside both the keyboard's focus ring and the accessibility
///   tree, and REQ-027 is about reaching every control.
/// * **Every control has a text field beside its slider**, because a slider
///   alone is a pointer-only control and an exact value cannot be typed into
///   one.
struct InstrumentEditorPane: View {
    @Bindable var model: InstrumentEditorModel

    /// Opens the name sheet for Save as Variant. A closure rather than a
    /// dependency on the studio, so this pane knows nothing about the list
    /// beside it.
    let saveAsVariant: () -> Void

    var body: some View {
        if model.isOpen {
            VStack(spacing: 0) {
                InstrumentEditorHeader(model: model, saveAsVariant: saveAsVariant)
                Divider()
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No instrument selected", systemImage: "pianokeys")
            } description: {
                Text("Choose a downloaded instrument or one of your variants on the left.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let unavailable = model.unavailableExplanation {
                    Label(unavailable, systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(unavailable)
                }

                // The catalog's own plain-language bounds, shown whether or not
                // any control is disabled. An instrument can be fully
                // customizable and still be a section patch standing in for a
                // solo line, and the owner is owed that before they rely on it.
                ForEach(model.qualityNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("About this instrument: \(note)")
                }

                InstrumentControlGroup(title: "Tone") {
                    InstrumentSlider(
                        model: model, control: .toneLow,
                        range: InstrumentCustomization.toneDecibelRange,
                        format: { "\(signed($0)) dB" },
                        spoken: { "\(signed($0)) decibels" }
                    )
                    InstrumentSlider(
                        model: model, control: .toneHigh,
                        range: InstrumentCustomization.toneDecibelRange,
                        format: { "\(signed($0)) dB" },
                        spoken: { "\(signed($0)) decibels" }
                    )
                }

                InstrumentControlGroup(title: "Dynamics") {
                    InstrumentSlider(
                        model: model, control: .dynamicsResponse,
                        range: InstrumentCustomization.dynamicsResponseRange,
                        format: { String(format: "%.2f×", $0) },
                        spoken: { String(format: "%.2f times as recorded", $0) }
                    )
                }

                InstrumentControlGroup(title: "Envelope") {
                    InstrumentSlider(
                        model: model, control: .attack,
                        range: InstrumentCustomization.attackSecondsRange,
                        format: { "+\(Int(($0 * 1000).rounded())) ms" },
                        spoken: { "\(Int(($0 * 1000).rounded())) milliseconds softer" }
                    )
                    InstrumentSlider(
                        model: model, control: .release,
                        range: InstrumentCustomization.releaseScaleRange,
                        format: { String(format: "%.2f×", $0) },
                        spoken: { String(format: "%.2f times the recorded release", $0) }
                    )
                }

                InstrumentControlGroup(title: "Pitch") {
                    InstrumentSlider(
                        model: model, control: .vibrato,
                        range: InstrumentCustomization.vibratoDepthCentsRange,
                        format: { "\(Int($0.rounded())) cents" },
                        spoken: { "\(Int($0.rounded())) cents deep" }
                    )
                    InstrumentVibratoRate(model: model)
                    InstrumentSlider(
                        model: model, control: .tuning,
                        range: InstrumentCustomization.tuningOffsetCentsRange,
                        format: { "\(signed($0)) cents" },
                        spoken: { "\(signed($0)) cents" }
                    )
                }

                InstrumentControlGroup(title: "Articulation") {
                    InstrumentArticulationPicker(model: model)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(Int(rounded.rounded()))
            : String(format: "%.1f", abs(rounded))
        return rounded < 0 ? "−\(text.replacingOccurrences(of: "-", with: ""))" : "+\(text)"
    }
}

// MARK: - Header

/// What is being customized, whether it can be saved in place, and the one
/// write a downloaded instrument allows.
private struct InstrumentEditorHeader: View {
    @Bindable var model: InstrumentEditorModel
    let saveAsVariant: () -> Void

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
                .accessibilityLabel("Customizing \(model.title). \(model.subtitle).")

                Spacer(minLength: 8)

                Button("Reset") { model.resetToRecorded() }
                    .accessibilityLabel("Reset every control to the recorded instrument")

                Button { saveAsVariant() } label: {
                    Label("Save as Variant…", systemImage: "plus.square.on.square")
                }
                .accessibilityLabel("Save these settings as a named variant")
                .accessibilityHint("Also on the Sounds menu, as Shift Command V. The downloaded "
                                   + "library is not changed.")

                if model.isEditable {
                    Button("Revert") { model.revert() }
                        .disabled(!model.hasUnsavedChanges)
                        .accessibilityHint("Puts every control back to the saved version.")

                    Button { model.save() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!model.hasUnsavedChanges)
                    .accessibilityLabel("Save this variant")
                    .accessibilityHint("Also on the Sounds menu, as Command-S.")
                }
            }

            if model.isInstalledInstrument {
                Label(
                    "This is a downloaded instrument, so its samples are read-only. Move the "
                    + "controls to hear what they do, then save your settings as a named "
                    + "variant — the library itself is never changed.",
                    systemImage: "lock.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Read-only. This is a downloaded instrument and its samples "
                                    + "cannot be changed. Save your settings as a named variant "
                                    + "instead.")
            } else if model.hasUnsavedChanges {
                Label("Unsaved changes — you are hearing them, but they are not stored yet.",
                      systemImage: "pencil.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            let unsupported = model.unsupportedControls
            if !unsupported.isEmpty {
                // The count up front, so an owner who is wondering why a slider
                // will not move finds the answer without hunting for the one
                // greyed-out row.
                let names = unsupported.map(\.control.displayName).joined(separator: ", ")
                Label(
                    "\(unsupported.count) control\(unsupported.count == 1 ? "" : "s") "
                    + "unavailable for this instrument: \(names). Each one says why below.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "\(unsupported.count) controls are unavailable for this instrument: \(names). "
                    + "Each one is disabled with an explanation."
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A group of controls

private struct InstrumentControlGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - One control

/// One customization control: a slider, a readout, and — when the asset cannot
/// support it — the sentence saying so.
///
/// The disabled state is the interesting one. The slider is `.disabled`, the
/// readout is dimmed, and the explanation is a real piece of text under it that
/// VoiceOver reads as part of the control's own label rather than as a
/// neighbouring paragraph it might skip.
private struct InstrumentSlider: View {
    @Bindable var model: InstrumentEditorModel
    let control: InstrumentControl
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let spoken: (Double) -> String

    private var availability: InstrumentControlAvailability {
        model.availability(of: control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(control.displayName)
                    .font(.callout)
                    .frame(width: 140, alignment: .leading)
                    .foregroundStyle(availability.isSupported ? .primary : .secondary)
                    .accessibilityHidden(true)

                Slider(value: binding, in: range)
                    .disabled(!availability.isSupported)
                    .accessibilityLabel(control.displayName)
                    .accessibilityValue(
                        availability.isSupported
                            ? spoken(model.value(for: control))
                            : "unavailable"
                    )
                    .accessibilityHint(
                        availability.accessibilityExplanation
                            ?? "Changes are heard on every line playing this instrument."
                    )

                Text(format(model.value(for: control)))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 86, alignment: .trailing)
                    .foregroundStyle(availability.isSupported ? .secondary : .tertiary)
                    .accessibilityHidden(true)
            }

            if let explanation = availability.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 148)
                    // Not hidden from VoiceOver: the hint above carries it for
                    // the slider, and this is what a sighted owner reads. Both
                    // audiences get the same sentence.
                    .accessibilityLabel("\(control.displayName) is unavailable. \(explanation)")
            }
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { model.value(for: control) },
            set: { model.setValue($0, for: control) }
        )
    }
}

/// Vibrato's rate, gated by the same availability as its depth.
private struct InstrumentVibratoRate: View {
    @Bindable var model: InstrumentEditorModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Vibrato rate")
                .font(.callout)
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(model.isSupported(.vibrato) ? .primary : .secondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { model.vibratoRate },
                    set: { model.setVibratoRate($0) }
                ),
                in: InstrumentCustomization.vibratoRateHzRange
            )
            .disabled(!model.isSupported(.vibrato))
            .accessibilityLabel("Vibrato rate")
            .accessibilityValue(String(format: "%.1f hertz", model.vibratoRate))
            .accessibilityHint(
                model.availability(of: .vibrato).accessibilityExplanation
                    ?? "How fast the vibrato swings. Depth of zero silences it whatever this says."
            )

            Text(String(format: "%.1f Hz", model.vibratoRate))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
                .foregroundStyle(model.isSupported(.vibrato) ? .secondary : .tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Which of the instrument's SFZ files this variant plays.
private struct InstrumentArticulationPicker: View {
    @Bindable var model: InstrumentEditorModel

    private static let entryPointTag = "\u{0001}entry-point"

    private var availability: InstrumentControlAvailability {
        model.availability(of: .articulation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Articulation", selection: binding) {
                Text("Default").tag(Self.entryPointTag)
                ForEach(model.articulations, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .disabled(!availability.isSupported)
            .accessibilityValue(model.articulation ?? "default")
            .accessibilityHint(
                availability.accessibilityExplanation
                    ?? "Chooses which of this instrument's recorded articulations plays."
            )

            if let explanation = availability.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Articulation is unavailable. \(explanation)")
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { model.articulation ?? Self.entryPointTag },
            set: { model.setArticulation($0 == Self.entryPointTag ? nil : $0) }
        )
    }
}
