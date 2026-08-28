import Foundation

/// Where the sound a line is about to play actually came from.
///
/// Three cases, and the owner can see which (REQ-029 asks for the second one to
/// be visible). The third is the honest answer to store corruption rather than
/// a crash or a silent line.
public enum ResolvedSoundSource: Equatable, Sendable {
    /// A live library sound. Editing it changes this line.
    case library(soundID: String, name: String)

    /// A private copy the delete-in-use path left behind. Frozen.
    case embedded(originalSoundID: String, name: String)

    /// The preset names a library sound that is not there and left no embedded
    /// copy — which the embed path makes impossible, so reaching this means the
    /// store was damaged from outside the app.
    ///
    /// The line falls back to the default voice and says so, because the piece
    /// going quiet on one line, or refusing to open at all, would be a worse
    /// answer to a problem the owner did not cause.
    case missing(soundID: String, wasRetired: Bool)

    /// The name to show for this line's sound.
    public var displayName: String {
        switch self {
        case .library(_, let name), .embedded(_, let name):
            return name
        case .missing:
            return SynthPatch.defaultVoice.name
        }
    }

    public var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }

    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

/// One line of a preset, resolved against the sound library and ready to play.
public struct ResolvedLine: Equatable, Sendable, Identifiable {
    public let lineID: ScoreLineID

    /// The line's name, as the inventory has it — the owner's rename when there
    /// is one (REQ-005).
    public let name: String

    public let source: ResolvedSoundSource

    /// The sound itself. This is what is rendered.
    public let patch: SynthPatch

    public let mixer: LineMixerState

    public var id: ScoreLineID { lineID }

    public init(
        lineID: ScoreLineID,
        name: String,
        source: ResolvedSoundSource,
        patch: SynthPatch,
        mixer: LineMixerState
    ) {
        self.lineID = lineID
        self.name = name
        self.source = source
        self.patch = patch
        self.mixer = mixer
    }

    public var voiceProvider: SynthPatchVoiceProvider { SynthPatchVoiceProvider(patch: patch) }

    /// What VoiceOver says a mixer strip is.
    public var accessibilityDescription: String {
        var sentence = "\(name), \(source.displayName)"
        switch source {
        case .library: break
        case .embedded: sentence += ", embedded copy"
        case .missing: sentence += ", sound missing, playing the default voice"
        }
        if mixer.isMuted { sentence += ", muted" }
        if mixer.isSoloed { sentence += ", soloed" }
        return sentence
    }
}

/// A preset turned into something the engine can play: one sound per line and
/// the mixer state to go with it.
///
/// **The join between the stored preset and PLY003's engine.** Everything
/// audible about a preset happens here — the live reference is dereferenced,
/// an embedded copy is used verbatim, and a reference that resolves to nothing
/// falls back visibly. Resolution is a read, never a write: playing a preset
/// whose sound vanished must not quietly rewrite the preset.
public struct PresetPerformance: Sendable {
    public let preset: Preset

    /// The lines in the compiled score's order, so index and identity agree
    /// with the program the engine builds.
    public let lines: [ResolvedLine]

    public init(preset: Preset, lines: [ResolvedLine]) {
        self.preset = preset
        self.lines = lines
    }

    /// Resolve `preset` against the library.
    ///
    /// A line the preset has no entry for is skipped rather than invented. That
    /// cannot happen through `LibraryStore.openActivePreset(for:)`, which
    /// reconciles first, and it is safe if it ever does: `voiceAssignment`
    /// falls back to the default voice for a line it does not name and
    /// `applyMixer` writes `.neutral`, so the line plays rather than going
    /// silent.
    ///
    /// - Parameters:
    ///   - inventory: supplies each line's display name and the order.
    ///   - library: where a live reference is looked up.
    public static func resolve(
        _ preset: Preset,
        inventory: LineInventory,
        library: SoundLibrary
    ) throws -> PresetPerformance {
        var resolved: [ResolvedLine] = []
        resolved.reserveCapacity(inventory.entries.count)

        for entry in inventory.entries {
            guard let line = preset.line(withID: entry.id) else { continue }

            let source: ResolvedSoundSource
            let patch: SynthPatch

            switch line.assignment {
            case .library(_, let soundID):
                if let sound = try library.sound(withID: soundID) {
                    source = .library(soundID: soundID, name: sound.name)
                    patch = sound.patch
                } else {
                    source = .missing(
                        soundID: soundID, wasRetired: try library.isRetired(id: soundID)
                    )
                    patch = .defaultVoice
                }
            case .embedded(let embedded):
                source = .embedded(
                    originalSoundID: embedded.originalSoundID, name: embedded.name
                )
                patch = embedded.patch
            }

            resolved.append(
                ResolvedLine(
                    lineID: entry.id,
                    name: entry.name,
                    source: source,
                    patch: patch,
                    mixer: line.mixer
                )
            )
        }

        return PresetPerformance(preset: preset, lines: resolved)
    }

    /// True when at least one line's sound could not be found — the flag the UI
    /// shows so a fallback is never silent about being one.
    public var hasMissingSound: Bool { lines.contains { $0.source.isMissing } }

    /// Every line that is playing an embedded copy (REQ-029's visible mark).
    public var embeddedLines: [ResolvedLine] { lines.filter { $0.source.isEmbedded } }

    /// The per-line sounds, for `RenderProgram` and `PlaybackEngine`.
    ///
    /// The fallback matters as much as the lookup: a line the preset does not
    /// mention still gets the default voice rather than silence.
    public var voiceAssignment: LineVoiceAssignment {
        let byLine = Dictionary(
            lines.map { ($0.lineID, $0.voiceProvider as any LineVoiceProvider) },
            uniquingKeysWith: { first, _ in first }
        )
        return LineVoiceAssignment(providersByLine: byLine)
    }

    /// Copy the preset's volume, pan, mute and solo onto the engine's busses
    /// (REQ-008).
    ///
    /// Every line of the loaded program is written, including ones the preset
    /// does not mention: leaving a strip at whatever the previous preset set
    /// would make switching presets depend on which one was showing before,
    /// which is exactly the kind of state REQ-024's "applies immediately"
    /// rules out.
    public func applyMixer(to engine: PlaybackEngine) {
        guard let program = engine.loadedProgram else { return }
        let byLine = Dictionary(
            lines.map { ($0.lineID, $0.mixer) }, uniquingKeysWith: { first, _ in first }
        )
        for (index, lineID) in program.lineIDs.enumerated() {
            guard let strip = engine.mixer(forLineAt: index) else { continue }
            let state = byLine[lineID] ?? .neutral
            strip.gain = Float(state.volume)
            strip.pan = Float(state.pan)
            strip.isMuted = state.isMuted
            strip.isSoloed = state.isSoloed
        }
    }

    /// Put this whole preset on the engine: the sounds, then the mixer.
    ///
    /// Order matters — the mixer addresses lines of the *current* program, so
    /// the program has to be the one this preset's sounds built.
    public func apply(to engine: PlaybackEngine) throws {
        try engine.setVoices(voiceAssignment)
        applyMixer(to: engine)
    }
}
