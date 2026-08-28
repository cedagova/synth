import Foundation

// MARK: - Articulations

/// An articulation the realizer honours, as MusicXML names it.
///
/// Only marks that change how a note *sounds* are here. Bowings, fingerings
/// and the like stay in the report: they tell a player something, but this
/// build has no sound that could express them.
public enum ScoreArticulation: String, Equatable, Sendable, Codable, CaseIterable, Comparable {
    case accent
    case detachedLegato = "detached-legato"
    case softAccent = "soft-accent"
    case spiccato
    case staccatissimo
    case staccato
    case stress
    case strongAccent = "strong-accent"
    case tenuto
    case unstress

    /// Every MusicXML `<articulations>` child this build realizes.
    static let byElementName: [String: ScoreArticulation] = Dictionary(
        uniqueKeysWithValues: ScoreArticulation.allCases.map { ($0.rawValue, $0) }
    )

    public static func < (lhs: ScoreArticulation, rhs: ScoreArticulation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Ornaments

/// Which conventional figure an ornament sign stands for.
///
/// MusicXML's `<mordent>` is the *lower* mordent (principal, note below,
/// principal) and `<inverted-mordent>` the upper one — the opposite of what
/// the words suggest to an English speaker, and the source of most mordent
/// bugs. The names here follow MusicXML so the mapping stays checkable
/// against the specification rather than against intuition.
public enum ScoreOrnamentKind: String, Equatable, Sendable, Codable, CaseIterable, Comparable {
    case trill
    case mordent
    case invertedMordent
    case turn
    case invertedTurn
    case delayedTurn
    case delayedInvertedTurn

    /// MusicXML `<ornaments>` children this build realizes.
    ///
    /// `shake` is an old name for a trill, and notation software still emits
    /// it; treating it as anything else would silently flatten the ornament.
    static let byElementName: [String: ScoreOrnamentKind] = [
        "trill-mark": .trill,
        "shake": .trill,
        "mordent": .mordent,
        "inverted-mordent": .invertedMordent,
        "turn": .turn,
        "inverted-turn": .invertedTurn,
        "delayed-turn": .delayedTurn,
        "delayed-inverted-turn": .delayedInvertedTurn
    ]

    /// True when the figure sounds only in the second half of the note.
    public var isDelayed: Bool { self == .delayedTurn || self == .delayedInvertedTurn }

    public static func < (lhs: ScoreOrnamentKind, rhs: ScoreOrnamentKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A notated ornament, with any accidental the engraver printed over it.
///
/// The auxiliary notes are diatonic neighbours in the prevailing key unless
/// the score says otherwise, which is the convention every edition assumes.
/// `<accidental-mark>` is that "otherwise": printed above the sign it alters
/// the upper neighbour, below it the lower one.
public struct ScoreOrnament: Equatable, Sendable, Codable {
    public let kind: ScoreOrnamentKind

    /// Semitone alteration of the note above the principal, when printed.
    /// nil takes the alteration from the key signature.
    public let upperAlter: Int?

    /// Semitone alteration of the note below the principal, when printed.
    public let lowerAlter: Int?

    public init(kind: ScoreOrnamentKind, upperAlter: Int? = nil, lowerAlter: Int? = nil) {
        self.kind = kind
        self.upperAlter = upperAlter
        self.lowerAlter = lowerAlter
    }
}

// MARK: - Grace notes

/// One grace note printed before a principal note.
///
/// MusicXML gives grace notes no `<duration>` — they take their time from the
/// notes around them — so the realizer works from the slash, the printed note
/// type, and the optional `steal-time` percentages.
public struct ScoreGraceNote: Equatable, Sendable, Codable {
    public let pitch: ScorePitch

    /// `<grace slash="yes">`: an acciaccatura, crushed against the beat.
    public let isAcciaccatura: Bool

    /// Notated value in ticks from `<type>`, or 0 when the score prints none.
    public let notatedTicks: Int

    /// `<grace steal-time-following="n">`, a percentage of the principal note.
    public let stealTimeFollowingPercent: Int?

    /// `<grace steal-time-previous="n">`, a percentage of the preceding note.
    public let stealTimePreviousPercent: Int?

    /// `<chord/>`: this grace note sounds with the grace note before it rather
    /// than after it.
    public let isChordMember: Bool

    public init(
        pitch: ScorePitch,
        isAcciaccatura: Bool,
        notatedTicks: Int,
        stealTimeFollowingPercent: Int? = nil,
        stealTimePreviousPercent: Int? = nil,
        isChordMember: Bool = false
    ) {
        self.pitch = pitch
        self.isAcciaccatura = isAcciaccatura
        self.notatedTicks = notatedTicks
        self.stealTimeFollowingPercent = stealTimeFollowingPercent
        self.stealTimePreviousPercent = stealTimePreviousPercent
        self.isChordMember = isChordMember
    }
}

// MARK: - Dynamics

/// A dynamic marking, as MusicXML spells it.
///
/// Two families in one type because the score writes them in one place: a
/// **level** stays in force until the next one, and an **accent** such as
/// `sf` colours a single note. `fp` is both — a loud attack and a quiet
/// continuation — which is why `sustainedLevel` is separate from
/// `momentaryBoost` rather than one number.
public enum ScoreDynamic: String, Equatable, Sendable, Codable, CaseIterable, Comparable {
    case pppppp, ppppp, pppp, ppp, pp, p, mp, mf, f, ff, fff, ffff, fffff, ffffff
    case n
    case sf, sfz, sffz, fz, rf, rfz
    case fp, sfp, sfpp, sfzp

    static let byElementName: [String: ScoreDynamic] = Dictionary(
        uniqueKeysWithValues: ScoreDynamic.allCases.map { ($0.rawValue, $0) }
    )

    /// The velocity this marking leaves in force, or nil for a pure accent
    /// that changes nothing after its own note.
    public var sustainedLevel: Int? {
        switch self {
        case .pppppp: return 5
        case .ppppp: return 10
        case .pppp: return 16
        case .ppp: return 24
        case .pp: return 33
        case .p: return 49
        case .mp: return 64
        case .mf: return 80
        case .f: return 96
        case .ff: return 112
        case .fff: return 120
        case .ffff: return 124
        case .fffff: return 126
        case .ffffff: return 127
        case .n: return 1
        case .fp, .sfp, .sfzp: return 49
        case .sfpp: return 33
        case .sf, .sfz, .sffz, .fz, .rf, .rfz: return nil
        }
    }

    /// How much louder the marking makes the one note it is attached to.
    public var momentaryBoost: Int {
        switch self {
        case .sf, .fz, .rf: return 22
        case .sfz, .rfz: return 28
        case .sffz: return 34
        case .fp, .sfp, .sfzp: return 40
        case .sfpp: return 46
        default: return 0
        }
    }

    /// The ladder of plain levels, softest first. A hairpin with no dynamic
    /// printed at its end moves one rung along this.
    public static let ladder: [ScoreDynamic] = [
        .pppppp, .ppppp, .pppp, .ppp, .pp, .p, .mp, .mf, .f, .ff, .fff, .ffff, .fffff, .ffffff
    ]

    public static func < (lhs: ScoreDynamic, rhs: ScoreDynamic) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which way a hairpin points.
public enum ScoreWedgeType: String, Equatable, Sendable, Codable, Comparable {
    case crescendo
    case diminuendo

    public static func < (lhs: ScoreWedgeType, rhs: ScoreWedgeType) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Expression events

/// What one expression event does.
///
/// A flat enumeration with the payload beside it rather than associated
/// values: the event list is sorted into a canonical order and encoded byte
/// for byte, and a flat shape makes both of those obvious instead of
/// dependent on how Swift happens to encode an enumeration payload.
public enum ScoreExpressionKind: String, Equatable, Sendable, Codable, CaseIterable, Comparable {
    case dynamic
    case wedgeStart
    case wedgeStop
    case pedalDown
    case pedalUp
    case pedalChange

    public static func < (lhs: ScoreExpressionKind, rhs: ScoreExpressionKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One expressive direction, bound to where the score prints it.
///
/// Directions belong to a part and, when the engraver says so, to one staff of
/// it. A piano's pedal marking under the bass staff governs both hands, and a
/// dynamic under one staff of a two-staff part governs only that staff; the
/// `staff` field carries that distinction, with `allStaves` for a direction
/// the score does not pin to one.
public struct ScoreExpressionEvent: Equatable, Sendable, Codable, Comparable {
    /// Every staff of the part.
    public static let allStaves = 0

    /// Index into `CompiledScore.sourceMeasures`.
    public let sourceMeasureIndex: Int

    /// Onset in ticks from the start of that source measure.
    public let startTicks: Int

    /// `score-part/@id` the direction was printed in.
    public let partID: String

    /// The staff it governs, or `allStaves`.
    public let staff: Int

    public let kind: ScoreExpressionKind

    /// Set when `kind` is `.dynamic`.
    public let dynamic: ScoreDynamic?

    /// Set when `kind` is `.wedgeStart`.
    public let wedge: ScoreWedgeType?

    public init(
        sourceMeasureIndex: Int,
        startTicks: Int,
        partID: String,
        staff: Int,
        kind: ScoreExpressionKind,
        dynamic: ScoreDynamic? = nil,
        wedge: ScoreWedgeType? = nil
    ) {
        self.sourceMeasureIndex = sourceMeasureIndex
        self.startTicks = startTicks
        self.partID = partID
        self.staff = staff
        self.kind = kind
        self.dynamic = dynamic
        self.wedge = wedge
    }

    /// Whether this event governs `staff` of `partID`.
    public func governs(partID: String, staff: Int) -> Bool {
        self.partID == partID && (self.staff == Self.allStaves || self.staff == staff)
    }

    /// A total order over every field, so the event list is canonical and the
    /// timeline cannot vary with the order the parser met the directions in.
    public static func < (lhs: ScoreExpressionEvent, rhs: ScoreExpressionEvent) -> Bool {
        if lhs.sourceMeasureIndex != rhs.sourceMeasureIndex {
            return lhs.sourceMeasureIndex < rhs.sourceMeasureIndex
        }
        if lhs.startTicks != rhs.startTicks { return lhs.startTicks < rhs.startTicks }
        if lhs.partID != rhs.partID { return lhs.partID < rhs.partID }
        if lhs.staff != rhs.staff { return lhs.staff < rhs.staff }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.dynamic != rhs.dynamic {
            return (lhs.dynamic?.rawValue ?? "") < (rhs.dynamic?.rawValue ?? "")
        }
        return (lhs.wedge?.rawValue ?? "") < (rhs.wedge?.rawValue ?? "")
    }
}

// MARK: - Diatonic neighbours

/// The scale in force, for working out an ornament's auxiliary notes.
///
/// A trill's upper note is "the next note of the scale", not "a tone above" —
/// in E flat major the note above D is E flat, and playing E natural is simply
/// wrong. That rule needs the key signature, which is why this lives beside
/// the ornament rather than inside the realizer's arithmetic.
enum DiatonicScale {
    private static let letters = ["C", "D", "E", "F", "G", "A", "B"]

    /// Order sharps and flats appear in a key signature.
    private static let sharpOrder = ["F", "C", "G", "D", "A", "E", "B"]
    private static let flatOrder = ["B", "E", "A", "D", "G", "C", "F"]

    /// The alteration `fifths` puts on each letter.
    static func signatureAlterations(fifths: Int) -> [String: Int] {
        var result: [String: Int] = [:]
        if fifths > 0 {
            for index in 0..<min(fifths, 7) { result[sharpOrder[index]] = 1 }
        } else if fifths < 0 {
            for index in 0..<min(-fifths, 7) { result[flatOrder[index]] = -1 }
        }
        return result
    }

    /// The note one scale step above `pitch` in the key of `fifths`, or the
    /// note below when `above` is false.
    ///
    /// `alterOverride` is the engraver's printed accidental over the ornament
    /// and always wins over the key signature.
    static func neighbour(
        of pitch: ScorePitch,
        above: Bool,
        fifths: Int,
        alterOverride: Int?
    ) -> ScorePitch? {
        guard let index = letters.firstIndex(of: pitch.step.uppercased()) else { return nil }
        let step = above ? (index + 1) % 7 : (index + 6) % 7
        let letter = letters[step]

        // Only a step across B→C (upward) or C→B (downward) changes octave.
        var octave = pitch.octave
        if above, index == 6 { octave += 1 }
        if !above, index == 0 { octave -= 1 }

        let alter = alterOverride ?? signatureAlterations(fifths: fifths)[letter] ?? 0
        let neighbour = ScorePitch(step: letter, alter: alter, octave: octave)

        // A neighbour must actually lie on the correct side of the principal.
        // An enharmonic accident — a printed double flat over a trill, say —
        // would otherwise produce a "trill" that goes the wrong way.
        guard let principalMIDI = pitch.midiNoteNumber,
              let neighbourMIDI = neighbour.midiNoteNumber,
              above ? neighbourMIDI > principalMIDI : neighbourMIDI < principalMIDI
        else { return nil }
        return neighbour
    }
}
