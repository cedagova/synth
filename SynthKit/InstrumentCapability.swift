import Foundation

/// One thing the customization surface offers to change.
///
/// A closed set so that "which controls exist" is one list rather than a
/// scattering of view code, and so a test can walk every control of every
/// curated instrument and assert that each one is either genuinely supported or
/// carries a sentence saying why it is not.
public enum InstrumentControl: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case toneLow
    case toneHigh
    case dynamicsResponse
    case attack
    case release
    case vibrato
    case tuning
    case articulation

    /// The label the control carries in the editor and in VoiceOver.
    public var displayName: String {
        switch self {
        case .toneLow: return "Low tone"
        case .toneHigh: return "High tone"
        case .dynamicsResponse: return "Dynamics response"
        case .attack: return "Attack softening"
        case .release: return "Release length"
        case .vibrato: return "Vibrato"
        case .tuning: return "Tuning offset"
        case .articulation: return "Articulation"
        }
    }
}

/// Whether one control may be offered, and — when it may not — why.
///
/// **The explanation is the requirement.** REQ-021 does not say "hide the
/// control"; it says unsupported controls are disabled *with an explanation*. A
/// disabled slider with no sentence beside it tells the owner the app is
/// broken; a disabled slider that says "this patch has one sampled dynamic
/// layer" tells them something true about what they downloaded.
public struct InstrumentControlAvailability: Sendable, Equatable {
    public let control: InstrumentControl

    /// True when the asset genuinely supports the control.
    public let isSupported: Bool

    /// Why not, as a complete sentence. Nil exactly when `isSupported`.
    public let explanation: String?

    public init(control: InstrumentControl, isSupported: Bool, explanation: String?) {
        self.control = control
        self.isSupported = isSupported
        self.explanation = isSupported ? nil : explanation
    }

    /// What VoiceOver says about a disabled control, or nil for a live one.
    public var accessibilityExplanation: String? {
        guard let explanation else { return nil }
        return "\(control.displayName) is not available for this instrument. \(explanation)"
    }
}

/// What one downloaded instrument can actually be customized with.
///
/// **Derived from asset facts, never from the library's name** (issue #24's
/// invariant). Two sources feed it and they answer the same question from
/// different sides:
///
/// * `SampledInstrumentFeatures` — INS002's measurement of the files on disk:
///   how many velocity layers any one key really has, whether anything is
///   pitched, whether anything releases.
/// * `InstrumentCoverage` — INS001's editorial record: the catalog's own
///   `dynamicLayerCount` and its plain-language `qualityNotes`.
///
/// The measurement wins where they disagree, because it is a property of the
/// bytes the owner actually has; the catalog's figure is carried into the
/// explanation so a mismatch is visible rather than silently resolved. That is
/// the difference between "we think this is thin" and "this *is* thin, and here
/// is the count".
///
/// Nothing in this type switches on a library identifier. A per-library `if`
/// would be the hardcoded UI switch the issue prohibits, and it would go stale
/// the first time a catalog entry was re-pinned to different bytes.
public struct InstrumentCapabilities: Sendable, Equatable {
    /// Velocity layers measured on the widest-split key. 1 means none.
    public let sampledDynamicLayerCount: Int

    /// What the catalog claims, for the explanation when the two disagree.
    public let catalogDynamicLayerCount: Int

    public let isPitched: Bool
    public let respondsToNoteOff: Bool
    public let hasReleaseTriggers: Bool
    public let roundRobinDepth: Int

    /// Alternate SFZ files this instrument installs, plus keyswitched
    /// articulations inside the entry point.
    public let articulationCount: Int

    /// The catalog's plain-language bounds, shown above the controls whether or
    /// not any control is disabled (REQ-021's "surface quality honestly").
    public let qualityNotes: [String]

    /// The instrument's name, for sentences that have to say which one.
    public let instrumentName: String

    /// Build the capability set for a loaded instrument.
    ///
    /// - Parameters:
    ///   - features: what INS002 measured while loading the SFZ.
    ///   - coverage: what INS001's catalog records about the same instrument.
    ///   - alternateArticulationCount: how many alternate SFZ files are
    ///     installed beside the entry point.
    public init(
        features: SampledInstrumentFeatures,
        coverage: InstrumentCoverage,
        alternateArticulationCount: Int
    ) {
        self.sampledDynamicLayerCount = features.velocityLayerCount
        self.catalogDynamicLayerCount = coverage.dynamicLayerCount
        self.isPitched = features.isPitched
        self.respondsToNoteOff = features.respondsToNoteOff
        self.hasReleaseTriggers = features.hasReleaseTriggers
        self.roundRobinDepth = features.roundRobinDepth
        self.articulationCount = alternateArticulationCount + features.articulationCount
        self.qualityNotes = coverage.qualityNotes
        self.instrumentName = coverage.name
    }

    /// Build the capability set for an instrument that is not installed.
    ///
    /// Everything unknown is reported as unsupported with the same reason: the
    /// files are not here to measure. A not-downloaded instrument therefore
    /// shows the whole control set greyed out and says so, instead of showing a
    /// live editor over an instrument that cannot play.
    public init(uninstalled coverage: InstrumentCoverage) {
        self.sampledDynamicLayerCount = 0
        self.catalogDynamicLayerCount = coverage.dynamicLayerCount
        self.isPitched = false
        self.respondsToNoteOff = false
        self.hasReleaseTriggers = false
        self.roundRobinDepth = 0
        self.articulationCount = 0
        self.qualityNotes = coverage.qualityNotes
        self.instrumentName = coverage.name
    }

    /// True when the instrument's files were never measured.
    public var isMeasured: Bool { sampledDynamicLayerCount > 0 }

    // MARK: The rules

    /// Whether `control` may be offered, and why not when it may not.
    public func availability(of control: InstrumentControl) -> InstrumentControlAvailability {
        guard isMeasured else {
            return InstrumentControlAvailability(
                control: control,
                isSupported: false,
                explanation:
                    "“\(instrumentName)” is not downloaded, so Synth has no samples to measure. "
                    + "Download its library from the instrument catalog and the controls this "
                    + "instrument supports become available."
            )
        }

        switch control {
        // Shelving the output works on any recorded audio, so tone is the one
        // part of the set no asset can fail to support.
        case .toneLow, .toneHigh:
            return supported(control)

        case .dynamicsResponse:
            guard sampledDynamicLayerCount >= 2 else {
                return unsupported(control, dynamicsExplanation)
            }
            return supported(control)

        // Easing an attack is adding to what the file declares, which every
        // sample can do; it never cuts into the recording.
        case .attack:
            return supported(control)

        case .release:
            guard respondsToNoteOff else {
                return unsupported(
                    control,
                    "Every sound in “\(instrumentName)” plays to the end of its own recording "
                        + "and ignores when the note stops, so there is no release to lengthen "
                        + "or shorten."
                )
            }
            return supported(control)

        case .vibrato, .tuning:
            guard isPitched else {
                return unsupported(
                    control,
                    "“\(instrumentName)” pins every sample to the pitch it was recorded at "
                        + "rather than following the key, so changing its pitch is not something "
                        + "this instrument can honestly do."
                )
            }
            return supported(control)

        case .articulation:
            guard articulationCount > 0 else {
                return unsupported(
                    control,
                    "“\(instrumentName)” installs one articulation, so there is nothing to "
                        + "switch between."
                )
            }
            return supported(control)
        }
    }

    /// Every control, in declaration order.
    public var all: [InstrumentControlAvailability] {
        InstrumentControl.allCases.map(availability(of:))
    }

    public func isSupported(_ control: InstrumentControl) -> Bool {
        availability(of: control).isSupported
    }

    /// Controls this instrument cannot offer, in declaration order.
    public var unsupportedControls: [InstrumentControlAvailability] {
        all.filter { !$0.isSupported }
    }

    /// `customization` with every unsupported control put back to the recorded
    /// value.
    ///
    /// **The gate is enforced here, not in the view.** A variant made while a
    /// library was installed, edited, and then played after the owner removed
    /// that library must not keep applying a control the instrument does not
    /// support — and a document written by hand must not be able to reach the
    /// render core with one either. Every path from storage to the engine goes
    /// through this, so "unsupported" means "has no effect", not merely "is
    /// greyed out".
    public func bounded(_ customization: InstrumentCustomization) -> InstrumentCustomization {
        var bounded = customization.clamped()
        if !isSupported(.toneLow) { bounded.toneLowDecibels = 0 }
        if !isSupported(.toneHigh) { bounded.toneHighDecibels = 0 }
        if !isSupported(.dynamicsResponse) { bounded.dynamicsResponse = 1 }
        if !isSupported(.attack) { bounded.attackSeconds = 0 }
        if !isSupported(.release) { bounded.releaseScale = 1 }
        if !isSupported(.vibrato) { bounded.vibratoDepthCents = 0 }
        if !isSupported(.tuning) { bounded.tuningOffsetCents = 0 }
        if !isSupported(.articulation) { bounded.articulationFileName = nil }
        return bounded
    }

    // MARK: Sentences

    /// Why dynamics response cannot be offered, saying both counts when the
    /// files and the catalog disagree.
    private var dynamicsExplanation: String {
        let measured = "“\(instrumentName)” has one sampled dynamic layer, so playing harder "
            + "changes its level but never its tone — there are no recorded dynamics to shape."
        guard catalogDynamicLayerCount > 1 else { return measured }
        return measured
            + " The catalog lists \(catalogDynamicLayerCount) layers for it; the files on disk "
            + "have one, so re-downloading its library may restore the rest."
    }

    private func supported(_ control: InstrumentControl) -> InstrumentControlAvailability {
        InstrumentControlAvailability(control: control, isSupported: true, explanation: nil)
    }

    private func unsupported(
        _ control: InstrumentControl, _ explanation: String
    ) -> InstrumentControlAvailability {
        InstrumentControlAvailability(
            control: control, isSupported: false, explanation: explanation
        )
    }
}
