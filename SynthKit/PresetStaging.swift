import Foundation

/// Where a line sits on the stage when a piece is opened for the first time
/// (REQ-001): a seating pan curve across the score's parts, a family-aware
/// depth, a register lean on both, and a gentle shared-room send.
///
/// **Deterministic.** A pure function of the line's position in score order,
/// the part count, the instrument family the score names, and the register the
/// score's own notes sound in (STG003) — all of them score-derived, none of
/// them read back from audio (AD-P7) — so two owners with the same score get
/// the same stage, and creating a preset twice cannot produce two different
/// ones.
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

    // MARK: Register (STG003)

    /// How wide the ensemble's register must be, in semitones, before register
    /// biases the seating at all.
    ///
    /// An octave. Below it the parts are in one register and there is no bass
    /// line to single out — three violins are three violins — so the stage is
    /// exactly the one this type derived before register existed.
    static let registerDeadbandSemitones = 12.0

    /// Where the register bias reaches full strength, in semitones.
    ///
    /// Two octaves. Between the deadband and here it ramps, so an ensemble
    /// whose registers are only arguably separate leans a little rather than
    /// jumping to an extreme seat — the definition's "ambiguous registers bias
    /// toward no change".
    static let registerFullSpreadSemitones = 24.0

    /// Where a fully bass-register line is seated, in pan units: centre-right,
    /// which is where a continuo section or a double bass desk sits.
    static let bassSeatPan = 0.3

    /// How much of the way from its score-order seat to `bassSeatPan` a fully
    /// bass-register line is pulled.
    ///
    /// Short of all the way, deliberately: two equally low lines must keep
    /// distinct seats, and a full pull would stack them on one spot.
    static let maximumRegisterPull = 0.8

    /// How much further back a fully bass-register line sits, on top of the
    /// depth its family already has. Low parts carry the room rather than the
    /// front of the stage.
    static let bassDepthLean = 0.15

    /// The ensemble's register, as the seating derivation reads it: every
    /// line's summary in score order.
    ///
    /// **Relative to the piece, not to an absolute pitch, deliberately.**
    /// "Bass" means *this* piece's low line. An absolute threshold would seat
    /// an entire cello ensemble centre-right and leave a piccolo trio's lowest
    /// voice untouched, which is backwards; comparing the lines against each
    /// other is also what makes a single-register piece stage byte-identically
    /// to the pre-STG003 derivation, because then there is nothing to compare.
    public struct StageRegisters: Equatable, Sendable {
        /// Each line's summary in score order, nil where the line has too few
        /// sounding pitches to summarize (see `LineRegister`).
        public let perLine: [LineRegister?]

        /// The lowest median in the ensemble, and the midpoint of its range.
        /// Everything at or above the midpoint keeps its score-order seat.
        private let lowestMedian: Double
        private let midpointMedian: Double

        /// 0 while the ensemble sits in one register, ramping to 1 once it
        /// spans `registerFullSpreadSemitones`.
        private let engagement: Double

        public init(_ perLine: [LineRegister?]) {
            self.perLine = perLine
            let medians = perLine.compactMap { $0 }.map { Double($0.medianMIDINote) }
            guard let low = medians.min(), let high = medians.max() else {
                lowestMedian = 0
                midpointMedian = 0
                engagement = 0
                return
            }
            lowestMedian = low
            midpointMedian = (low + high) / 2
            let ramp = PresetStaging.registerFullSpreadSemitones
                - PresetStaging.registerDeadbandSemitones
            let over = (high - low) - PresetStaging.registerDeadbandSemitones
            engagement = ramp > 0 ? min(1, max(0, over / ramp)) : (over >= 0 ? 1 : 0)
        }

        /// The registers of one piece's lines, in score order.
        public init(inventory: LineInventory) {
            self.init(inventory.entries.map(\.register))
        }

        /// How bass-register the line at `index` is, 0…1.
        ///
        /// 1 for the ensemble's lowest line, 0 for every line at or above the
        /// register midpoint — which is the whole of "treble lines keep their
        /// score-order seat" — and 0 for a line with no register summary, which
        /// is the whole of "too few pitches gets the family-only result".
        func bassness(ofLineAt index: Int) -> Double {
            guard engagement > 0,
                  perLine.indices.contains(index),
                  let register = perLine[index]
            else { return 0 }
            let span = midpointMedian - lowestMedian
            guard span > 0 else { return 0 }
            let position = (midpointMedian - Double(register.medianMIDINote)) / span
            return engagement * min(1, max(0, position))
        }
    }

    /// The staged mixer for the line at `index` of `count`, playing `family`,
    /// in an ensemble whose registers are `registers`.
    ///
    /// `registers` is optional because the seat is still derivable without it —
    /// a score the compiler gave no usable pitches, or a caller that only has
    /// the family — and nil means exactly the family-only result.
    public static func mixer(
        lineIndex index: Int,
        lineCount count: Int,
        family: InstrumentCoverage.Family?,
        registers: StageRegisters? = nil
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
        var depth = count <= 1
            ? 0
            : family.flatMap { familyDepth[$0] } ?? defaultDepth

        // STG003: register leans the seat the score order and the family chose,
        // rather than replacing it. A bass line moves toward centre-right and
        // back; a treble line does not move at all. A solo line is exempt for
        // the same reason it has no depth — there is no ensemble to sit in.
        let bassness = count > 1 ? (registers?.bassness(ofLineAt: index) ?? 0) : 0
        if bassness > 0 {
            pan += bassness * maximumRegisterPull * (bassSeatPan - pan)
            depth = min(1, depth + bassness * bassDepthLean)
        }

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
