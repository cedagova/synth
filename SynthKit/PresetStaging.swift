import Foundation

/// Where a line sits on the stage when a piece is opened for the first time
/// (REQ-001): a seating pan curve across the score's parts, a family-aware
/// depth, and a gentle shared-room send.
///
/// **Deterministic.** A pure function of the line's position in score order,
/// the part count, and the instrument family the score names — the same
/// inputs `PresetAutoAssignment` already reads — so two owners with the same
/// score get the same stage, and creating a preset twice cannot produce two
/// different ones.
///
/// **A starting point, not a law.** Every value lands in the preset as an
/// ordinary `LineMixerState` the owner edits like any other mixer value.
/// All taste constants live in this one type.
public enum PresetStaging {
    /// Widest seat, in pan units. The outermost parts of a large ensemble sit
    /// here; smaller ensembles spread proportionally less.
    static let maximumSpread = 0.75

    /// How much of the stage one additional part opens up, until
    /// `maximumSpread` caps it. Four parts reach ±0.45; six or more reach the
    /// full stage.
    static let spreadPerPart = 0.15

    /// Every staged line leans this much into the shared room, before depth
    /// adds its own distance lean in the engine.
    static let roomSend = 0.16

    /// How far back each recognised family sits, 0…1. Strings at the front,
    /// winds behind them, brass behind those, percussion at the back — the
    /// classical stage, coarsely.
    static let familyDepth: [InstrumentCoverage.Family: Double] = [
        .strings: 0.15,
        .keyboards: 0.2,
        .harp: 0.25,
        .woodwinds: 0.3,
        .brass: 0.4,
        .percussion: 0.5
    ]

    /// Depth for a line whose family the score does not name.
    static let defaultDepth = 0.25

    /// Percussion reads from the back of the centre, not an edge seat: its
    /// pan is pulled toward the middle by this factor.
    static let percussionPanFactor = 0.4

    /// The staged mixer for the line at `index` of `count`, playing `family`.
    public static func mixer(
        lineIndex index: Int,
        lineCount count: Int,
        family: InstrumentCoverage.Family?
    ) -> LineMixerState {
        var pan = 0.0
        if count > 1 {
            let spread = min(maximumSpread, spreadPerPart * Double(count - 1))
            pan = -spread + 2 * spread * Double(index) / Double(count - 1)
        }
        if family == .percussion {
            pan *= percussionPanFactor
        }

        // A solo piece stages centred with room only: depth attenuates and
        // darkens, and there is no ensemble for a lone line to sit behind.
        let depth = count <= 1
            ? 0
            : family.flatMap { familyDepth[$0] } ?? defaultDepth

        return LineMixerState(
            volume: 1,
            pan: pan,
            isMuted: false,
            isSoloed: false,
            roomSend: roomSend,
            depth: depth
        )
    }
}
