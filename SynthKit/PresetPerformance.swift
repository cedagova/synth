import Foundation

/// Where the sound a line is about to play actually came from.
///
/// Four cases, and the owner can see which (REQ-029 asks for the second one to
/// be visible, and issue #24 for the fourth). The third is the honest answer to
/// store corruption rather than a crash or a silent line.
public enum ResolvedSoundSource: Equatable, Sendable {
    /// A live library sound — a synth patch, an installed instrument, or the
    /// owner's variant of one. Editing it changes this line.
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

    /// The preset names a downloaded instrument that is not installed right
    /// now (issue #24).
    ///
    /// **Deliberately not `missing`.** Nothing is damaged and the owner did
    /// nothing wrong: they have not downloaded that library, or they removed
    /// it, and downloading it puts the line straight back. Folding this into
    /// the store-corruption case would tell them their library was broken and
    /// hand them the wrong next step.
    case instrumentNotInstalled(soundID: String, reference: InstrumentReference)

    /// The name to show for this line's sound.
    public var displayName: String {
        switch self {
        case .library(_, let name), .embedded(_, let name):
            return name
        case .missing:
            return SynthPatch.defaultVoice.name
        case .instrumentNotInstalled(_, let reference):
            return reference.instrumentName
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

    /// The library identity this names, whichever case it is.
    public var soundID: String? {
        switch self {
        case .library(let id, _), .missing(let id, _), .instrumentNotInstalled(let id, _):
            return id
        case .embedded(let id, _):
            return id
        }
    }
}

/// The synth sound a line falls back to while its instrument is missing and the
/// owner has said they want to hear something.
public struct LineSubstitute: Equatable, Sendable {
    public let soundID: String
    public let name: String
    public let patch: SynthPatch

    public init(soundID: String, name: String, patch: SynthPatch) {
        self.soundID = soundID
        self.name = name
        self.patch = patch
    }
}

/// One line of a preset, resolved against the sound library and ready to play.
public struct ResolvedLine: Equatable, Sendable, Identifiable {
    public let lineID: ScoreLineID

    /// The line's name, as the inventory has it — the owner's rename when there
    /// is one (REQ-005).
    public let name: String

    public let source: ResolvedSoundSource

    /// The sound itself. This is what is rendered — unless `advice` says it
    /// cannot be, in which case the line is silent or substituted and says so.
    public let content: SoundContent

    /// For an instrument sound, where its downloaded assets stand right now.
    /// Nil for a synth sound, which has no assets to be missing.
    public let instrumentResolution: InstrumentResolution?

    /// Everything true about this line that the owner has to see (issue #24).
    /// Empty is the normal case and means the line plays exactly what it says.
    public let advice: [LineInstrumentAdvice]

    /// The owner has accepted a substitute for a missing instrument on this
    /// line.
    public let acceptsSubstitution: Bool

    /// What that substitute is. Present whenever a substitute could be offered,
    /// whether or not it has been accepted, so the button can name it before it
    /// is pressed.
    public let substitute: LineSubstitute?

    public let mixer: LineMixerState

    public var id: ScoreLineID { lineID }

    public init(
        lineID: ScoreLineID,
        name: String,
        source: ResolvedSoundSource,
        content: SoundContent,
        instrumentResolution: InstrumentResolution? = nil,
        advice: [LineInstrumentAdvice] = [],
        acceptsSubstitution: Bool = false,
        substitute: LineSubstitute? = nil,
        mixer: LineMixerState
    ) {
        self.lineID = lineID
        self.name = name
        self.source = source
        self.content = content
        self.instrumentResolution = instrumentResolution
        self.advice = advice
        self.acceptsSubstitution = acceptsSubstitution
        self.substitute = substitute
        self.mixer = mixer
    }

    /// The synth patch this line renders, when it renders one.
    public var patch: SynthPatch? { content.synthPatch }

    /// The instrument variant this line renders, when it renders one.
    public var variant: InstrumentVariant? { content.instrumentVariant }

    /// True when this line is currently producing no sound at all.
    public var isSilent: Bool { advice.contains { $0.isSilent } }

    /// True when the owner could be offered a substitute for this line — the
    /// instrument is missing and they have not answered yet.
    public var canOfferSubstitution: Bool {
        !acceptsSubstitution && substitute != nil && advice.contains { $0.isSilent }
    }

    /// The provider that renders this line.
    ///
    /// **The one place the decision is made**, so it cannot be made differently
    /// by live playback and by an offline render:
    ///
    /// * a synth sound plays its patch;
    /// * an installed instrument plays its samples, with the owner's
    ///   customization bounded to what the asset supports;
    /// * a missing instrument the owner has accepted a substitute for plays
    ///   that named substitute; and
    /// * a missing instrument they have not answered about plays **silence**,
    ///   because issue #24 allows a substitution only with explicit
    ///   acknowledgment and a quiet synth patch in a cello's place is exactly
    ///   the state that rules out.
    ///
    /// - Parameters:
    ///   - instruments: the loaded-instrument cache. Nil means no sampled
    ///     instrument can be built, which is the right answer for a caller that
    ///     has none — and produces silence with a flag rather than a surprise.
    ///   - live: the channel a sampled line publishes customization edits
    ///     through, keyed by sound identity. Nil for an offline render, which
    ///     wants a frozen sound.
    public func voiceProvider(
        instruments: SampledInstrumentLibrary? = nil,
        live: ((String) -> SampledInstrumentLiveVoices?)? = nil
    ) -> any LineVoiceProvider {
        switch content {
        case .synth(let patch):
            return SynthPatchVoiceProvider(patch: patch)

        case .instrument(let variant):
            if case .installed(let available)? = instrumentResolution, let instruments {
                if let provider = try? sampledProvider(
                    variant, available, instruments, live
                ) {
                    return provider
                }
                // The load failed between resolution and now — files removed
                // under the app. `advice` already carries the reason; the line
                // goes quiet rather than becoming something else.
                return silence(named: variant.reference.instrumentName)
            }

            if acceptsSubstitution, let substitute {
                return SynthPatchVoiceProvider(patch: substitute.patch)
            }
            return silence(named: variant.reference.instrumentName)
        }
    }

    private func sampledProvider(
        _ variant: InstrumentVariant,
        _ available: AvailableInstrument,
        _ instruments: SampledInstrumentLibrary,
        _ live: ((String) -> SampledInstrumentLiveVoices?)?
    ) throws -> SampledInstrumentVoiceProvider {
        let articulation = variant.articulationFileName.flatMap { name in
            available.alternateSFZURLs.first { $0.lastPathComponent == name }
        }
        let loaded = try instruments.instrument(for: available, articulation: articulation)
        let capabilities = InstrumentCapabilities(
            features: loaded.features,
            coverage: available.coverage,
            alternateArticulationCount: available.alternateSFZURLs.count
        )
        return SampledInstrumentVoiceProvider(
            instrument: loaded,
            // Bounded here, at the last step before the render core, so a
            // control the instrument cannot honestly support has no effect even
            // if a stored document or a stale editor asks for one.
            customization: capabilities.bounded(variant.customization),
            live: source.soundID.flatMap { live?($0) }
        )
    }

    private func silence(named name: String) -> SilentVoiceProvider {
        SilentVoiceProvider(
            identifier: source.soundID.map { "silent:\($0)" } ?? "silent:\(lineID.rawValue)",
            displayName: name
        )
    }

    /// What VoiceOver says a mixer strip is.
    public var accessibilityDescription: String {
        var sentence = "\(name), \(source.displayName)"
        switch source {
        case .library: break
        case .embedded: sentence += ", embedded copy"
        case .missing: sentence += ", sound missing, playing the default voice"
        case .instrumentNotInstalled: break
        }
        for item in advice { sentence += ", \(item.badge.lowercased())" }
        if mixer.isMuted { sentence += ", muted" }
        if mixer.isSoloed { sentence += ", soloed" }
        return sentence
    }
}

/// A preset turned into something the engine can play: one sound per line and
/// the mixer state to go with it.
///
/// **The join between the stored preset and PLY003's engine.** Everything
/// audible about a preset happens here — the live reference is dereferenced, an
/// embedded copy is used verbatim, a reference that resolves to nothing falls
/// back visibly, and an instrument whose assets are absent goes quiet with a
/// reason attached. Resolution is a read, never a write: playing a preset whose
/// sound vanished must not quietly rewrite the preset.
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
    ///   - instruments: where an instrument reference is checked against what
    ///     is actually installed. Nil means "this caller cannot answer that",
    ///     and an instrument line is then reported as not installed rather than
    ///     assumed playable — the safe direction, because the alternative is a
    ///     silent line nobody flagged.
    public static func resolve(
        _ preset: Preset,
        inventory: LineInventory,
        library: SoundLibrary,
        instruments: InstrumentAssetStore? = nil
    ) throws -> PresetPerformance {
        var resolved: [ResolvedLine] = []
        resolved.reserveCapacity(inventory.entries.count)

        // Read once for the whole preset rather than per line: an 18-line score
        // would otherwise stat every installed SFZ eighteen times.
        let palette = try library.allSounds()
        let synthPalette = palette.filter { $0.kind == .synth }

        for entry in inventory.entries {
            guard let line = preset.line(withID: entry.id) else { continue }

            let source: ResolvedSoundSource
            let content: SoundContent

            switch line.assignment {
            case .library(_, let soundID):
                if let sound = try library.sound(withID: soundID) {
                    source = .library(soundID: soundID, name: sound.name)
                    content = sound.content
                } else if let reference = try uninstalledInstrument(
                    soundID: soundID, instruments: instruments
                ) {
                    // An instrument identity with no installed instrument
                    // behind it. Not a damaged store — a library the owner has
                    // not downloaded, or removed.
                    source = .instrumentNotInstalled(soundID: soundID, reference: reference)
                    content = .instrument(InstrumentVariant(reference: reference))
                } else {
                    source = .missing(
                        soundID: soundID, wasRetired: try library.isRetired(id: soundID)
                    )
                    content = .synth(.defaultVoice)
                }
            case .embedded(let embedded):
                source = .embedded(
                    originalSoundID: embedded.originalSoundID, name: embedded.name
                )
                content = embedded.content
            }

            let (resolution, advice) = try instrumentState(
                of: content, source: source, instruments: instruments
            )

            resolved.append(
                ResolvedLine(
                    lineID: entry.id,
                    name: entry.name,
                    source: source,
                    content: content,
                    instrumentResolution: resolution,
                    advice: advice + scoreAdvice(
                        for: entry, source: source, advice: advice
                    ),
                    acceptsSubstitution: line.acceptsSubstitution,
                    substitute: advice.contains(where: \.isSilent) || line.acceptsSubstitution
                        ? substitute(for: entry, from: synthPalette)
                        : nil,
                    mixer: line.mixer
                )
            )
        }

        return PresetPerformance(preset: preset, lines: resolved)
    }

    /// The reference behind an `instrument:` identity that the library could
    /// not resolve, or nil when the identity is not one.
    private static func uninstalledInstrument(
        soundID: String, instruments: InstrumentAssetStore?
    ) throws -> InstrumentReference? {
        guard let parts = InstrumentReference.soundID(soundID) else { return nil }
        // The catalog still knows the names even when nothing is installed, so
        // the flag can say "Cello section, from VSCO 2 Community Edition"
        // rather than an identifier.
        let library = instruments?.catalogLibraries.first { $0.identifier == parts.libraryID }
        let coverage = library?.coverage.first { $0.identifier == parts.instrumentID }
        if let library, let coverage {
            return InstrumentReference(library: library, coverage: coverage)
        }
        return InstrumentReference(
            libraryID: parts.libraryID,
            instrumentID: parts.instrumentID,
            libraryName: library?.name ?? parts.libraryID,
            instrumentName: coverage?.name ?? parts.instrumentID
        )
    }

    /// Where an instrument line's assets stand, and what the owner must be told.
    private static func instrumentState(
        of content: SoundContent,
        source: ResolvedSoundSource,
        instruments: InstrumentAssetStore?
    ) throws -> (InstrumentResolution?, [LineInstrumentAdvice]) {
        guard case .instrument(let variant) = content else { return (nil, []) }
        let reference = variant.reference

        guard let instruments else {
            return (
                .notInThisVersion(reference: reference),
                [.notInThisVersion(instrumentName: reference.instrumentName)]
            )
        }

        let resolution = try instruments.resolve(reference)
        switch resolution {
        case .installed:
            return (resolution, [])
        case .notDownloaded:
            return (resolution, [
                .notDownloaded(
                    instrumentName: reference.instrumentName,
                    libraryName: reference.libraryName
                )
            ])
        case .filesMissing:
            return (resolution, [
                .filesMissing(
                    instrumentName: reference.instrumentName,
                    libraryName: reference.libraryName
                )
            ])
        case .notInThisVersion:
            return (resolution, [
                .notInThisVersion(instrumentName: reference.instrumentName)
            ])
        }
    }

    /// The honest note about an instrument the score names that no openly
    /// licensed source supplies (INS001's owner ruling).
    ///
    /// **Separate from the assignment's own advice, because it is a different
    /// fact.** "You have not downloaded the cello" is about this owner's disk;
    /// "there is no harpsichord anywhere" is about this build, and no amount of
    /// downloading changes it. A line whose part is one of the uncovered
    /// instruments says so even when it is happily playing the closest thing
    /// available, so the owner knows why they are hearing a piano.
    private static func scoreAdvice(
        for entry: LineEntry,
        source: ResolvedSoundSource,
        advice: [LineInstrumentAdvice]
    ) -> [LineInstrumentAdvice] {
        let text = [entry.partName, entry.defaultName].compactMap { $0 }.joined(separator: " ")
            .lowercased()
        guard let uncovered = InstrumentCatalog.knownUncoveredInstruments.first(
            where: { text.contains($0) }
        ) else { return [] }
        // Only worth saying when the line is actually playing something. A line
        // that is already silent has a more urgent sentence.
        guard !advice.contains(where: \.isSilent) else { return [] }
        return [
            .noOpenlyLicensedSource(
                scoreInstrumentName: uncovered, playingName: source.displayName
            )
        ]
    }

    /// The synth sound this line would fall back to, chosen exactly as a first
    /// open would choose it (REQ-007).
    ///
    /// Deterministic, so the button says the same name every time it is shown
    /// and the substitution the owner accepts is the one they were offered.
    private static func substitute(
        for entry: LineEntry, from synthPalette: [SoundEntry]
    ) -> LineSubstitute? {
        guard let sound = PresetAutoAssignment.sound(for: entry, from: synthPalette),
              let patch = sound.synthPatch
        else { return nil }
        return LineSubstitute(soundID: sound.id, name: sound.name, patch: patch)
    }

    /// True when at least one line's sound could not be found — the flag the UI
    /// shows so a fallback is never silent about being one.
    public var hasMissingSound: Bool { lines.contains { $0.source.isMissing } }

    /// Every line that is playing an embedded copy (REQ-029's visible mark).
    public var embeddedLines: [ResolvedLine] { lines.filter { $0.source.isEmbedded } }

    /// Every line the owner has something to be told about (issue #24).
    public var flaggedLines: [ResolvedLine] { lines.filter { !$0.advice.isEmpty } }

    /// Every line that is currently producing no sound at all.
    public var silentLines: [ResolvedLine] { lines.filter(\.isSilent) }

    /// The per-line sounds, for `RenderProgram` and `PlaybackEngine`.
    ///
    /// The fallback matters as much as the lookup: a line the preset does not
    /// mention still gets the default voice rather than silence.
    public func voiceAssignment(
        instruments: SampledInstrumentLibrary? = nil,
        live: ((String) -> SampledInstrumentLiveVoices?)? = nil
    ) -> LineVoiceAssignment {
        LineVoiceAssignment(providersByLine: providers(instruments: instruments, live: live))
    }

    /// The provider per line, as a dictionary, for a caller that needs to
    /// inspect them — `LineRenderHealth` reads this to find a line whose voice
    /// could not be built.
    public func providers(
        instruments: SampledInstrumentLibrary? = nil,
        live: ((String) -> SampledInstrumentLiveVoices?)? = nil
    ) -> [ScoreLineID: any LineVoiceProvider] {
        Dictionary(
            lines.map { ($0.lineID, $0.voiceProvider(instruments: instruments, live: live)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Copy the preset's volume, pan, mute, solo and room send onto the
    /// engine's busses (REQ-008, D7).
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
            strip.roomSend = Float(state.roomSend)
        }
    }

    /// Put this whole preset on the engine: the sounds, then the mixer.
    ///
    /// Order matters — the mixer addresses lines of the *current* program, so
    /// the program has to be the one this preset's sounds built.
    public func apply(
        to engine: PlaybackEngine,
        instruments: SampledInstrumentLibrary? = nil,
        live: ((String) -> SampledInstrumentLiveVoices?)? = nil
    ) throws {
        try engine.setVoices(voiceAssignment(instruments: instruments, live: live))
        applyMixer(to: engine)
    }
}
