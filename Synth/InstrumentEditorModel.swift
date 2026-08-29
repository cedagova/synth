import Foundation
import Observation
import SynthKit

/// The instrument under customization: its working variant, what the asset can
/// honestly do, and its way back to the sound library (REQ-021, REQ-023).
///
/// **The sampler's counterpart to `SoundEditorModel`, and deliberately the same
/// shape**, because it is the same job with a different sound underneath:
/// a working value that only exists here until it is saved, a live channel that
/// makes a moved control audible without stopping the music, and a library that
/// is the only thing allowed to say what a legal change is.
///
/// Two things are different, and both come from what a downloaded instrument
/// is:
///
/// * **Every control is gated by the asset, not by this model.**
///   `InstrumentCapabilities` measures the files the owner actually has and
///   answers per control; this only shows the answer. That is REQ-021's "never
///   fake" made structural — a control the samples cannot support is disabled
///   with the measurement's own sentence beside it, and `bounded` makes it inert
///   even if something asked for it anyway.
/// * **An installed instrument is never the working sound.** It is read-only,
///   like a shipped patch, so the editor loads it, shows the whole control set
///   live as a preview, and offers exactly one write: Save as Variant. That is
///   REQ-017's edit-as-copy applied to an instrument, and it is why the
///   downloaded assets can never be reached by an edit.
@Observable
@MainActor
final class InstrumentEditorModel {
    /// The library row being customized — an installed instrument, or the
    /// owner's own variant — or nil when nothing is open.
    private(set) var entry: SoundEntry?

    /// The variant as it currently is, including unsaved changes.
    private(set) var variant: InstrumentVariant?

    /// The variant as the library last stored it. What Revert goes back to.
    private(set) var savedVariant: InstrumentVariant?

    /// What the asset can honestly do. Nil while nothing is open, or while the
    /// instrument's files are not installed to be measured.
    private(set) var capabilities: InstrumentCapabilities?

    /// Where this instrument's downloaded assets stand.
    private(set) var resolution: InstrumentResolution?

    /// The alternate SFZ files installed beside the entry point, by file name.
    private(set) var articulations: [String] = []

    private(set) var statusMessage: String?

    var alert: SoundAlert?

    /// Called with the stored entry after a successful save or a Save as
    /// Variant, so the studio can fold it into the list and select it.
    var onSaved: ((SoundEntry) -> Void)?

    /// Told, with the sound's identity, every time the working variant changes
    /// — so every line of the open piece assigned *this* variant hears it while
    /// the piece plays, and no other line does.
    ///
    /// The instrument half of REQ-018, and the same closure shape
    /// `SoundEditorModel.onPatchEdited` uses, because the transport does the
    /// same thing with both.
    var onVariantEdited: ((String, InstrumentVariant) -> Void)?

    private let library: SoundLibrary
    private let instruments: InstrumentAssetStore
    private let sampled: SampledInstrumentLibrary

    init(store: LibraryStore) {
        self.library = store.sounds
        self.instruments = store.instruments
        self.sampled = store.sampledInstruments
    }

    // MARK: Derived state

    var isOpen: Bool { entry != nil }

    /// True when saving writes back to this row rather than making a new one.
    var isEditable: Bool { entry?.isEditable == true }

    /// True when this is a downloaded instrument rather than the owner's
    /// variant of one — the read-only case, whose only write is Save as Variant.
    var isInstalledInstrument: Bool { entry?.origin == .instrument }

    var hasUnsavedChanges: Bool {
        guard let variant, let savedVariant else { return false }
        return variant != savedVariant
    }

    var title: String { entry?.name ?? "No instrument selected" }

    /// "Strings · a downloaded instrument from VSCO 2 Community Edition", or
    /// "Strings · your variant of Cello section · revision 3".
    var subtitle: String {
        guard let entry, let variant else {
            return "Choose a downloaded instrument or one of your variants."
        }
        var parts = [entry.category.displayName]
        switch entry.origin {
        case .instrument:
            parts.append("a downloaded instrument from “\(variant.reference.libraryName)”")
        case .user:
            parts.append("your variant of “\(variant.reference.instrumentName)”")
            parts.append("revision \(entry.revision)")
        case .shipped:
            parts.append("one of Synth's own sounds")
        }
        return parts.joined(separator: " · ")
    }

    /// The catalog's plain-language bounds for this instrument, shown above the
    /// controls whether or not any control is disabled (REQ-021's "surface
    /// per-instrument quality honestly").
    var qualityNotes: [String] { capabilities?.qualityNotes ?? [] }

    /// Why the whole control set is inert, or nil when the instrument is
    /// playable.
    var unavailableExplanation: String? {
        switch resolution {
        case .installed, .none:
            return nil
        case .notDownloaded(let library, let instrument):
            return "“\(instrument.name)” is not downloaded, so Synth has no samples to measure "
                + "and nothing to customize. Download “\(library.name)” from the instrument "
                + "catalog and every control this instrument supports becomes available."
        case .filesMissing(let library, let instrument):
            return "“\(instrument.name)” is listed as installed but its files are not on disk. "
                + "Re-download “\(library.name)” from the instrument catalog."
        case .notInThisVersion(let reference):
            return "“\(reference.instrumentName)” is not in this version of Synth's catalog, so "
                + "there is nothing to download and nothing to customize. This variant keeps its "
                + "settings in case a later version brings the instrument back."
        }
    }

    /// Whether one control may be offered, and why not when it may not.
    ///
    /// Falls back to the uninstalled capability set — every control disabled
    /// with the download sentence — rather than to "supported", so a missing
    /// measurement can never read as permission.
    func availability(of control: InstrumentControl) -> InstrumentControlAvailability {
        guard let capabilities else {
            return InstrumentControlAvailability(
                control: control,
                isSupported: false,
                explanation: unavailableExplanation
                    ?? "Synth has not measured this instrument's samples."
            )
        }
        return capabilities.availability(of: control)
    }

    func isSupported(_ control: InstrumentControl) -> Bool {
        availability(of: control).isSupported
    }

    /// Every control this instrument cannot offer, for the summary line above
    /// the panel.
    var unsupportedControls: [InstrumentControlAvailability] {
        InstrumentControl.allCases.map(availability(of:)).filter { !$0.isSupported }
    }

    // MARK: Opening and closing

    /// Open `entry` for customization, measuring what its assets support.
    ///
    /// An entry that is not an instrument closes the editor rather than opening
    /// half of one: a synth patch belongs to `SoundEditorModel`, and a panel
    /// showing instrument controls over a patch would be exactly the fake
    /// REQ-021 forbids.
    func load(_ entry: SoundEntry) {
        restoreStoredVariant(of: self.entry)

        guard let variant = entry.instrumentVariant else { return close() }

        self.entry = entry
        self.variant = variant
        self.savedVariant = variant
        self.statusMessage = nil
        measure(variant.reference)
    }

    /// The row was renamed or re-filed. The customization did not change, so
    /// nothing is published and nothing becomes dirty; only the heading moves.
    func adoptRenamed(_ entry: SoundEntry) {
        guard self.entry?.id == entry.id else { return }
        self.entry = entry
        self.savedVariant = entry.instrumentVariant
    }

    func close() {
        restoreStoredVariant(of: entry)
        entry = nil
        variant = nil
        savedVariant = nil
        capabilities = nil
        resolution = nil
        articulations = []
        statusMessage = nil
    }

    /// Measure what the instrument's installed files actually support.
    ///
    /// Loading through the store's shared cache rather than a private one, so
    /// this measures the very instrument the engine plays — a capability the
    /// editor offers is then a capability the render core has, rather than one
    /// measured from a second copy that might differ.
    private func measure(_ reference: InstrumentReference) {
        do {
            let resolved = try instruments.resolve(reference)
            resolution = resolved
            guard case .installed(let available) = resolved else {
                capabilities = resolved.coverage.map(InstrumentCapabilities.init(uninstalled:))
                articulations = []
                return
            }
            articulations = available.alternateSFZURLs.map(\.lastPathComponent)
            capabilities = try sampled.capabilities(for: available)
        } catch {
            resolution = nil
            capabilities = nil
            articulations = []
            alert = SoundAlert(title: "Could not read “\(reference.instrumentName)”", error)
        }
    }

    // MARK: Editing

    /// Change one control. The one path every slider and picker uses.
    ///
    /// **Refuses a control the asset does not support**, so the gate holds even
    /// if a view forgets to disable something or a keyboard command reaches a
    /// control that is off screen. The editor is not the only place this is
    /// enforced — `InstrumentCapabilities.bounded` runs again on the way to the
    /// render core — but it is the place the owner would otherwise see a value
    /// move and hear nothing happen.
    func setValue(_ value: Double, for control: InstrumentControl) {
        guard var current = variant, isSupported(control) else { return }
        var customization = current.customization
        switch control {
        case .toneLow: customization.toneLowDecibels = value
        case .toneHigh: customization.toneHighDecibels = value
        case .dynamicsResponse: customization.dynamicsResponse = value
        case .attack: customization.attackSeconds = value
        case .release: customization.releaseScale = value
        case .vibrato: customization.vibratoDepthCents = value
        case .tuning: customization.tuningOffsetCents = value
        case .articulation: return
        }
        customization = customization.clamped()
        guard customization != current.customization else { return }
        current.customization = customization
        variant = current
        publishWorkingVariant()
    }

    /// Vibrato has two numbers and one gate, so its rate is its own setter
    /// rather than a second control that could be enabled independently of the
    /// depth it modulates.
    func setVibratoRate(_ hertz: Double) {
        guard var current = variant, isSupported(.vibrato) else { return }
        var customization = current.customization
        customization.vibratoRateHz = hertz
        customization = customization.clamped()
        guard customization != current.customization else { return }
        current.customization = customization
        variant = current
        publishWorkingVariant()
    }

    /// Choose which of the instrument's SFZ files this variant plays.
    func setArticulation(_ fileName: String?) {
        guard var current = variant, isSupported(.articulation) else { return }
        guard fileName == nil || articulations.contains(fileName!) else { return }
        guard fileName != current.customization.articulationFileName else { return }
        current.customization.articulationFileName = fileName
        variant = current
        publishWorkingVariant()
    }

    func value(for control: InstrumentControl) -> Double {
        guard let customization = variant?.customization else { return 0 }
        switch control {
        case .toneLow: return customization.toneLowDecibels
        case .toneHigh: return customization.toneHighDecibels
        case .dynamicsResponse: return customization.dynamicsResponse
        case .attack: return customization.attackSeconds
        case .release: return customization.releaseScale
        case .vibrato: return customization.vibratoDepthCents
        case .tuning: return customization.tuningOffsetCents
        case .articulation: return 0
        }
    }

    var vibratoRate: Double { variant?.customization.vibratoRateHz ?? 5 }
    var articulation: String? { variant?.customization.articulationFileName }

    /// Put everything back to the instrument as its library recorded it.
    func resetToRecorded() {
        guard var current = variant else { return }
        guard !current.customization.isAsRecorded else { return }
        current.customization = InstrumentCustomization(
            articulationFileName: current.customization.articulationFileName
        )
        variant = current
        publishWorkingVariant()
        statusMessage = "Back to “\(title)” exactly as its library recorded it."
    }

    /// Put everything back to the stored version of this variant.
    func revert() {
        guard let savedVariant, isEditable else { return }
        variant = savedVariant
        publishWorkingVariant()
        statusMessage = "Reverted “\(title)” to the saved version."
    }

    // MARK: Saving

    /// Write the working variant back to the library row it came from.
    func save() {
        guard let entry, let variant, isEditable, hasUnsavedChanges else { return }
        do {
            let stored = try library.update(entry, variant: variant)
            self.entry = stored
            self.savedVariant = stored.instrumentVariant
            self.variant = stored.instrumentVariant
            publishWorkingVariant()
            statusMessage = "Saved “\(stored.name)”."
            onSaved?(stored)
        } catch {
            alert = SoundAlert(title: "Could not save “\(entry.name)”", error)
        }
    }

    /// REQ-023's named variant: the working customization saved as the owner's
    /// own sound, assignable to a line like any other.
    ///
    /// **The only write a downloaded instrument allows.** The instrument's row
    /// does not exist and its samples are read-only, so this creates a new sound
    /// that references them — which is why customizing an instrument can never
    /// change what anybody else's copy of that library sounds like.
    @discardableResult
    func saveAsVariant(named name: String) -> SoundEntry? {
        guard let entry, let variant else { return nil }
        do {
            let created = try library.createVariant(variant, named: name, in: entry.category)
            statusMessage = "Saved “\(created.name)” to your sound library. "
                + "“\(variant.reference.instrumentName)” itself is unchanged."
            onSaved?(created)
            return created
        } catch {
            alert = SoundAlert(title: "Could not save “\(name)”", error)
            return nil
        }
    }

    /// The name a new variant is offered, based on what has been changed.
    ///
    /// Deterministic and descriptive rather than "New Variant": the owner has
    /// just moved a control, and a name that says which one is the one they
    /// would have typed.
    func suggestedVariantName() -> String {
        guard let variant else { return "New Variant" }
        let base = variant.reference.instrumentName
        guard let changes = variant.customization.changeSummary else { return "\(base) variant" }
        // The first change is the one the owner most recently cared about
        // enough to be the headline.
        let headline = changes.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "variant"
        return "\(base) — \(headline)"
    }

    // MARK: Internals

    /// Publishes the variant as it now stands to every line of the open piece
    /// that plays it (REQ-018).
    ///
    /// **Bounded on the way out, not only on the way in.** `setValue` already
    /// refuses a control this instrument cannot support, but Revert and Reset
    /// publish *stored* values — and a variant saved when its library had two
    /// dynamic layers, played after that library was re-pinned to a
    /// single-layer one, would otherwise carry a dynamics setting straight past
    /// the gate into the running voices. Bounding here is what makes
    /// "unsupported means inert" true of every path out of this editor, the way
    /// `ResolvedLine.voiceProvider` makes it true of every path out of storage.
    private func publishWorkingVariant() {
        guard let entry, var variant, entry.isEditable else { return }
        if let capabilities { variant.customization = capabilities.bounded(variant.customization) }
        onVariantEdited?(entry.id, variant)
    }

    /// Puts a variant the owner edited and then walked away from back to what
    /// the library holds, so an unsaved edit never silently outlives the editor.
    private func restoreStoredVariant(of entry: SoundEntry?) {
        guard let entry, entry.isEditable,
              let variant, let savedVariant, variant != savedVariant else { return }
        onVariantEdited?(entry.id, savedVariant)
    }
}
