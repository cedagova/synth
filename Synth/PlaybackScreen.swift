import SwiftUI
import SynthKit

/// The transport: everything the owner does to a piece that is playing
/// (REQ-009, REQ-012, REQ-014, REQ-027).
///
/// **No score and no timeline is drawn**, per D2. That is not a gap to be
/// apologised for in the layout; it is the reason the position readout is the
/// most prominent thing on the screen and is never hidden behind a disclosure.
/// It is the owner's only way to know where they are.
///
/// Everything here is a real focusable control with a label and a hint, and
/// every action also exists as a menu command with a shortcut, because that is
/// what REQ-027 means on macOS.
struct PlaybackScreen: View {
    @Bindable var model: PlaybackModel
    let close: () -> Void

    @FocusState private var focus: Field?
    @State private var tab: Tab = .loop

    fileprivate enum Field: Hashable {
        case measure
        case time
        case loopFrom
        case loopTo
    }

    /// The secondary tools, one at a time. Playing itself — position,
    /// scrubber, transport — is never behind a tab.
    fileprivate enum Tab: Hashable {
        case loop
        case export
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaybackHeader(model: model, close: close)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PositionReadout(model: model, focus: $focus)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            TransportHero(model: model)
                            Divider()
                            ToolTabs(model: model, tab: $tab, focus: $focus)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // The assignment and mixing surface, always present rather than
                // behind a disclosure: from increment 004 on, "which sound is
                // this line playing" is as much a part of listening to a piece
                // as where the playhead is.
                Divider()
                VStack(spacing: 0) {
                    HumanizationBar(model: model)
                    Divider()
                    AssignmentPanel(model: model.assignment)
                }
                .frame(width: 420)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { PlaybackStatusBar(model: model) }
        .overlay { preparationOverlay }
        // An explicit binding rather than `$model.export.isPresented`: `export`
        // is a `let`, so the projected chain has nothing to write through.
        .sheet(isPresented: Binding(
            get: { model.export.isPresented },
            set: { model.export.isPresented = $0 }
        )) {
            ExportSheet(model: model.export, subtitle: exportSubtitle)
        }
        .onChange(of: model.measureFocusRequests) { _, _ in
            model.prefillPositionDraft()
            focus = .measure
        }
        .onChange(of: model.timeFocusRequests) { _, _ in
            model.prefillTimeDraft()
            focus = .time
        }
        .task { await model.prepare() }
        // **No `.onDisappear { model.close() }`.**
        //
        // There is now a second reason this screen can disappear: the sound
        // studio takes the window over it while the piece stays open, which is
        // the whole point of being able to edit a sound while it plays. Closing
        // on disappear stopped the music the moment the studio opened — the
        // frozen candidate's own screenshot caught the transport reading
        // "Stopped" at 3.7 seconds of a 32-second piece.
        //
        // The model's lifetime was never this view's to own anyway.
        // `AppModel.closePlayback()` closes it when the owner leaves the piece,
        // and `openPlayback(for:)` closes the previous one before replacing it.
    }

    /// What the export sheet says it is about to render: the piece, and the
    /// preset when the piece has more than the one it was opened with.
    private var exportSubtitle: String {
        guard let preset = model.assignment.activePreset else { return model.piece.title }
        return "\(model.piece.title) — \(preset.name)"
    }

    /// Loading and failure both sit over the transport rather than replacing
    /// it, so the piece's identity and the Library button never disappear and
    /// the owner is never stranded.
    @ViewBuilder
    private var preparationOverlay: some View {
        switch model.loadState {
        case .preparing(let stage):
            VStack(spacing: 12) {
                ProgressView()
                Text(stage.text)
                Text("You can type a measure or a time now; Synth will jump there as soon as the piece is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Opening the piece. \(stage.text)")

        case .failed(let failure):
            ContentUnavailableView {
                Label("This piece cannot be played", systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 8) {
                    Text(failure.summary)
                    if let recovery = failure.recovery {
                        Text(recovery).foregroundStyle(.secondary)
                    }
                }
            } actions: {
                Button("Back to Library", action: close)
            }
            .background(.regularMaterial)

        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Header

private struct PlaybackHeader: View {
    @Bindable var model: PlaybackModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .accessibilityLabel("Back to the library")
            .accessibilityHint("Stops playback and returns to the list of pieces.")

            Divider().frame(height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.piece.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now open: \(model.piece.accessibilityDescription)")

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Position readout

/// The single most important thing on this screen: where the music is.
///
/// Measure, beat and elapsed time, always visible, never behind a disclosure —
/// and each one is also the way there: the display is the input, the way a
/// DAW's transport counter is. Click a value, type, Return jumps, Escape
/// leaves it alone.
private struct PositionReadout: View {
    @Bindable var model: PlaybackModel
    @FocusState.Binding var focus: PlaybackScreen.Field?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            EditableReadout(
                label: "Position",
                display: model.positionText,
                draft: $model.positionDraft,
                field: .measure,
                focus: $focus,
                editingWidth: 200,
                begin: { model.prefillPositionDraft() },
                commit: { model.commitPositionDraft() },
                help: "Click to type a measure — “12”, or “12 3.5” for a beat within it",
                accessibilityLabel: "Position: \(model.positionText)"
            )

            EditableReadout(
                label: "Elapsed",
                display: model.elapsedText,
                draft: $model.timeDraft,
                field: .time,
                focus: $focus,
                editingWidth: 130,
                begin: { model.prefillTimeDraft() },
                commit: { model.commitTimeDraft() },
                help: "Click to type a time — 1:23, or seconds alone",
                accessibilityLabel: "Elapsed: \(model.spokenPosition)"
            )

            Spacer(minLength: 8)

            // The loop chip lives up here rather than only on the Go To & Loop
            // tab: a loop keeps steering playback while other tabs are open,
            // and steering the owner cannot see reads as a stuck transport.
            if let description = model.loopDescription {
                Label(description, systemImage: "repeat")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .accessibilityLabel(description)
            }

            TransportStateBadge(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// One value of the readout: a large display that becomes a same-sized text
/// field on click. Return commits; Escape or clicking away leaves the value
/// untouched.
private struct EditableReadout: View {
    let label: String
    let display: String
    @Binding var draft: String
    let field: PlaybackScreen.Field
    @FocusState.Binding var focus: PlaybackScreen.Field?
    let editingWidth: CGFloat
    let begin: () -> Void
    let commit: () -> Void
    let help: String
    let accessibilityLabel: String

    @State private var isHovering = false

    private var valueFont: Font { .system(.title, design: .rounded).weight(.medium) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if focus == field {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(valueFont)
                    .monospacedDigit()
                    .focused($focus, equals: field)
                    .onSubmit {
                        commit()
                        focus = nil
                    }
                    .onExitCommand { focus = nil }
                    .frame(width: editingWidth)
                    .accessibilityLabel("\(label), editing")
                    .accessibilityHint("Press Return to jump, Escape to cancel.")
            } else {
                Text(display)
                    .font(valueFont)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    // A quiet hover highlight, so "this big number is a
                    // control" is discoverable without a tooltip.
                    .background(
                        isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .padding(.horizontal, -4)
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .onTapGesture {
                        begin()
                        focus = field
                    }
                    .help(help)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits([.isButton, .updatesFrequently])
                    .accessibilityHint("Click to type a new value.")
            }
        }
    }
}

/// Playing, paused, stopped — and *why* it is paused, when the engine paused
/// itself. A run that stopped because the output device vanished must not look
/// the same as one the owner paused.
private struct TransportStateBadge: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .accessibilityLabel("Transport: \(text)")
    }

    private var text: String {
        switch model.transportState {
        case .playing: return "Playing"
        case .stopped: return "Stopped"
        case .paused:
            switch model.pauseReason {
            case .reachedEnd: return "End of piece"
            case .overload: return "Paused — engine overloaded"
            case .deviceLost: return "Paused — output device lost"
            case .none: return "Paused"
            }
        }
    }

    private var symbol: String {
        switch model.transportState {
        case .playing: return "play.fill"
        case .stopped: return "stop.fill"
        case .paused:
            switch model.pauseReason {
            case .overload, .deviceLost: return "exclamationmark.triangle.fill"
            default: return "pause.fill"
            }
        }
    }
}

// MARK: - Transport hero

/// Playing, front and centre: a scrubber and the transport, styled the way
/// every media player styles them — icon buttons around one prominent
/// play/pause. Nothing here is ever behind a tab.
private struct TransportHero: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        VStack(spacing: 14) {
            ScrubBar(model: model)

            HStack(spacing: 22) {
                Spacer(minLength: 0)

                transportIcon("arrow.counterclockwise", size: 17) {
                    model.goToStart()
                }
                .help("Restart from the beginning")
                .accessibilityLabel("Go to the start of the piece")

                transportIcon("arrow.backward.to.line", size: 16) {
                    model.stepMeasure(by: -1)
                }
                .help("Previous measure (back inside a measure returns to its start)")
                .accessibilityLabel("Previous measure")

                transportIcon("gobackward.5", size: 20) {
                    model.skip(byMicroseconds: -PlaybackModel.skipMicroseconds)
                }
                .help("Back 5 seconds")
                .accessibilityLabel("Skip back five seconds")

                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                // Deliberately no `.defaultAction`: Return belongs to whichever
                // seek field has focus, and Command-Return on the Playback menu
                // is the unambiguous keyboard path.
                .help(model.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(model.isPlaying ? "Pause playback" : "Start playback")
                .accessibilityHint("Also on the Playback menu as Command Return.")
                .disabled(!model.isReady)

                transportIcon("goforward.5", size: 20) {
                    model.skip(byMicroseconds: PlaybackModel.skipMicroseconds)
                }
                .help("Forward 5 seconds")
                .accessibilityLabel("Skip forward five seconds")

                transportIcon("arrow.forward.to.line", size: 16) {
                    model.stepMeasure(by: 1)
                }
                .help("Next measure")
                .accessibilityLabel("Next measure")

                transportIcon("stop.fill", size: 17) {
                    model.stop()
                }
                .help("Stop and return to the start")
                .accessibilityLabel("Stop playback and return to the start")

                Spacer(minLength: 0)
            }
        }
    }

    private func transportIcon(
        _ symbol: String, size: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!model.isReady)
    }
}

/// Direct-manipulation position: drag anywhere in the piece. The readout above
/// stays the precise truth; this is the coarse, immediate way there.
private struct ScrubBar: View {
    @Bindable var model: PlaybackModel

    /// The in-flight thumb lives on the model (`scrubMicroseconds`) so the
    /// readout above follows the drag live — watching where you are is the
    /// point of scrubbing. The seek still commits only on release, so a drag
    /// does not spam the engine.
    var body: some View {
        Slider(
            value: Binding(
                get: { Double(model.scrubMicroseconds ?? model.positionMicroseconds) },
                set: { model.scrubMicroseconds = Int64($0) }
            ),
            in: 0...Double(max(1, model.totalMicroseconds)),
            onEditingChanged: { isDragging in
                guard !isDragging, let target = model.scrubMicroseconds else { return }
                model.seek(toMicroseconds: target)
                model.scrubMicroseconds = nil
            }
        )
        .disabled(!model.isReady)
        .accessibilityLabel("Playback position")
        .accessibilityValue(model.elapsedText)
    }
}

// MARK: - Tool tabs

/// The practice and configuration tools, one surface at a time. Go To and
/// Loop are how a practising player moves; humanization and export are set
/// once and left alone — none of them need to crowd the transport.
private struct ToolTabs: View {
    @Bindable var model: PlaybackModel
    @Binding var tab: PlaybackScreen.Tab
    @FocusState.Binding var focus: PlaybackScreen.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Tools", selection: $tab) {
                Text("Loop").tag(PlaybackScreen.Tab.loop)
                Text("Export").tag(PlaybackScreen.Tab.export)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .accessibilityLabel("Playback tools")

            switch tab {
            case .loop:
                LoopControls(model: model, focus: $focus)
            case .export:
                ExportControls(model: model)
            }
        }
    }
}

// MARK: - Loop

private struct LoopControls: View {
    @Bindable var model: PlaybackModel
    @FocusState.Binding var focus: PlaybackScreen.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Loop")

            // A–B capture, the way every practice looper works: mark the spot
            // while hearing it. The typed range below is the fine-tune.
            HStack(spacing: 8) {
                Button {
                    model.captureLoopStart()
                } label: {
                    Label("Start Here", systemImage: "arrow.down.to.line")
                }
                .help("Loop from the measure playing now")
                .accessibilityLabel("Start the loop at the current measure")
                .disabled(!model.isReady)

                Button {
                    model.captureLoopEnd()
                } label: {
                    Label("End Here", systemImage: "arrow.down.to.line.compact")
                }
                .help("Loop until the measure playing now, then repeat")
                .accessibilityLabel("End the loop at the current measure and start looping")
                .disabled(!model.isReady)

                Button {
                    model.clearLoop()
                } label: {
                    Label("Clear", systemImage: "repeat.circle.fill")
                }
                .help("Stop looping")
                .accessibilityLabel("Stop looping")
                .disabled(!model.isLooping)
            }

            HStack(spacing: 8) {
                Text("From measure")
                TextField("6", text: $model.loopFromField)
                    .frame(width: 56)
                    .focused($focus, equals: .loopFrom)
                    .onSubmit { model.setLoopFromFields() }
                    .accessibilityLabel("First measure of the loop")

                Text("to")
                TextField("7", text: $model.loopToField)
                    .frame(width: 56)
                    .focused($focus, equals: .loopTo)
                    .onSubmit { model.setLoopFromFields() }
                    .accessibilityLabel("Last measure of the loop, played in full")

                Button(model.isLooping ? "Update" : "Set Loop") {
                    model.setLoopFromFields()
                }
                .accessibilityLabel("Loop over that range of measures")
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Humanization (REQ-012)

/// Exactly two controls, and deliberately no more: an enable and an amount
/// (anything deeper is the interpretive modelling D4 rules out). One quiet
/// row above the preset panel, because the setting is part of the preset —
/// stored with it like any other custom value — and rarely touched.
private struct HumanizationBar: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Humanize", isOn: Binding(
                get: { model.humanization.isEnabled },
                set: { isEnabled in Task { await model.setHumanizationEnabled(isEnabled) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("Humanization")
            .accessibilityHint("Off plays the score exactly as written. Saved with the preset.")

            Slider(
                value: $model.intensityDraft,
                in: 0...100,
                step: 5,
                onEditingChanged: { isEditing in
                    // Committed when the drag ends: re-realizing the piece on
                    // every intermediate value would stutter a long score.
                    guard !isEditing else { return }
                    Task { await model.commitIntensity() }
                }
            )
            .controlSize(.small)
            .frame(width: 150)
            .disabled(!model.humanization.isEnabled)
            .accessibilityLabel("Humanization amount")
            .accessibilityValue("\(Int(model.intensityDraft)) percent")

            Text("\(Int(model.intensityDraft))%")
                .monospacedDigit()
                .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Export (REQ-026)

/// One button and one line of status. The choices live in the sheet, because
/// they are answered once per export rather than watched while listening.
private struct ExportControls: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Export")

            HStack(spacing: 10) {
                Button {
                    model.export.present()
                } label: {
                    Label("Export Audio…", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Export this piece to an audio file")
                .accessibilityHint("Renders the piece with its current preset to WAV or AIFF. "
                                   + "Also on the Playback menu as Shift Command E.")
                .disabled(!model.isReady)

                if model.export.isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }

            // Deliberately visible on the transport as well as in the sheet: an
            // export runs in the background and the owner may well have closed
            // the sheet to keep listening.
            if let status = model.export.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(status)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Text("Writes exactly what you hear, including humanization, at CD quality "
                     + "or better.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Status bar

private struct PlaybackStatusBar: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        HStack(spacing: 16) {
            if let status = model.statusMessage {
                Text(status)
                    .lineLimit(2)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel(status)
            }
            Spacer(minLength: 8)
            EngineStatsReadout(model: model)
            if case .preparing = model.loadState {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Opening the piece")
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
}

/// Live render-thread telemetry, so "why did the sound cut out?" is answered
/// by a number instead of a guess. Late blocks climbing during a dropout means
/// the engine missed its deadline; counters staying flat means the silence
/// happened after the engine — the output device (Bluetooth, most often).
private struct EngineStatsReadout: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let stats = model.renderStatistics
            if stats.renderedBlocks > 0 {
                Text(text(for: stats))
                    .font(.caption.monospaced())
                    .foregroundStyle(stats.overloadBlocks > 0 ? .orange : .secondary)
                    .help(
                        "Render thread health. Late blocks took over 85% of their "
                        + "real-time deadline; a forced pause is sustained overload. "
                        + "If sound drops while these stay flat, the engine delivered "
                        + "audio and the output device lost it."
                    )
                    .accessibilityLabel(accessibilityText(for: stats))
            }
        }
    }

    private func text(for stats: PlaybackEngine.RenderStatistics) -> String {
        var parts = [
            "late \(stats.overloadBlocks)/\(stats.renderedBlocks)",
            String(format: "peak %.2f", stats.peakLevel)
        ]
        if stats.overloadPauses > 0 { parts.insert("paused \(stats.overloadPauses)×", at: 1) }
        return parts.joined(separator: " · ")
    }

    private func accessibilityText(for stats: PlaybackEngine.RenderStatistics) -> String {
        "Engine: \(stats.overloadBlocks) late blocks of \(stats.renderedBlocks), "
        + "\(stats.overloadPauses) forced pauses, peak level \(String(format: "%.2f", stats.peakLevel))"
    }
}

struct SectionHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}
