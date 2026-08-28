import Foundation

extension Realization {
    /// One note of a realized ornament figure, relative to the principal.
    struct OrnamentStep {
        let midiNoteNumber: Int
        let offsetTicks: Int
        let durationTicks: Int
    }

    /// Realizes an ornament sign as the figure a player would sound (REQ-011).
    ///
    /// The readings are the conventional modern ones and nothing more
    /// adventurous, because choosing between period practices is an explicit
    /// non-goal (D4):
    ///
    /// | sign | figure |
    /// | --- | --- |
    /// | trill | principal and upper note alternating, beginning and ending on the principal |
    /// | mordent | principal, note below, principal |
    /// | inverted mordent | principal, note above, principal |
    /// | turn | above, principal, below, principal |
    /// | inverted turn | below, principal, above, principal |
    /// | delayed turn | the principal held, then the turn over the second half |
    ///
    /// Auxiliary notes are the diatonic neighbours in the key in force unless
    /// the engraver printed an accidental over the sign. Returning an empty
    /// figure means the ornament could not be realized; the caller sounds the
    /// plain note and the reason is already in the report.
    mutating func realizeOrnament(
        _ ornament: ScoreOrnament,
        principal: ScorePitch,
        midiNoteNumber: Int,
        totalTicks: Int,
        keyFifths: Int,
        at location: ScoreLocation
    ) -> [OrnamentStep] {
        let kind = ornament.kind
        let needsUpper = kind != .mordent
        let needsLower = kind == .mordent || kind == .turn || kind == .invertedTurn
            || kind == .delayedTurn || kind == .delayedInvertedTurn

        var upper: Int?
        var lower: Int?
        if needsUpper {
            upper = DiatonicScale.neighbour(
                of: principal,
                above: true,
                fifths: keyFifths,
                alterOverride: ornament.upperAlter
            )?.midiNoteNumber
        }
        if needsLower {
            lower = DiatonicScale.neighbour(
                of: principal,
                above: false,
                fifths: keyFifths,
                alterOverride: ornament.lowerAlter
            )?.midiNoteNumber
        }
        if (needsUpper && upper == nil) || (needsLower && lower == nil) {
            report.record(
                .notHonored,
                kind: "ornament: \(kind.rawValue)",
                at: location,
                detail: "its auxiliary note falls outside the playable range; the note is "
                    + "sounded plain"
            )
            return []
        }

        let pattern: [Int]
        let head: Int
        switch kind {
        case .trill:
            return trill(
                principal: midiNoteNumber,
                upper: upper ?? midiNoteNumber,
                totalTicks: totalTicks,
                at: location,
                kind: kind
            )
        case .mordent:
            pattern = [midiNoteNumber, lower ?? midiNoteNumber, midiNoteNumber]
            head = 0
        case .invertedMordent:
            pattern = [midiNoteNumber, upper ?? midiNoteNumber, midiNoteNumber]
            head = 0
        case .turn, .delayedTurn:
            pattern = [
                upper ?? midiNoteNumber, midiNoteNumber, lower ?? midiNoteNumber, midiNoteNumber
            ]
            head = kind == .delayedTurn ? totalTicks / 2 : 0
        case .invertedTurn, .delayedInvertedTurn:
            pattern = [
                lower ?? midiNoteNumber, midiNoteNumber, upper ?? midiNoteNumber, midiNoteNumber
            ]
            head = kind == .delayedInvertedTurn ? totalTicks / 2 : 0
        }

        // Every note of the figure must be audible. A sixteenth with a turn on
        // it cannot hold four distinct notes at any sane tempo, and inventing
        // four one-tick events would be a worse answer than saying so.
        let figureTicks = totalTicks - head
        guard figureTicks >= pattern.count else {
            report.record(
                .notHonored,
                kind: "ornament: \(kind.rawValue)",
                at: location,
                detail: "the note is too short to hold the figure; it is sounded plain"
            )
            return []
        }

        // The quick notes take an ornamental value and the principal keeps
        // what is left, which is how the figure is written out in an urtext
        // edition.
        let quick = max(1, min(ticksPerQuarter / 8, figureTicks / pattern.count))
        var steps: [OrnamentStep] = []
        var offset = 0
        if head > 0 {
            steps.append(
                OrnamentStep(
                    midiNoteNumber: midiNoteNumber,
                    offsetTicks: 0,
                    durationTicks: head
                )
            )
            offset = head
        }
        for (index, midi) in pattern.enumerated() {
            let isLast = index == pattern.count - 1
            let ticks = isLast ? max(1, totalTicks - offset) : quick
            steps.append(
                OrnamentStep(midiNoteNumber: midi, offsetTicks: offset, durationTicks: ticks)
            )
            offset += ticks
        }
        return steps
    }

    /// A trill: the principal and the note above it, alternating.
    ///
    /// An odd number of notes so the figure begins and ends on the principal,
    /// which is what makes it resolve rather than stop mid-shake. The speed is
    /// a thirty-second note at the piece's own tick grid, bounded so a held
    /// whole note does not produce hundreds of events.
    mutating func trill(
        principal: Int,
        upper: Int,
        totalTicks: Int,
        at location: ScoreLocation,
        kind: ScoreOrnamentKind
    ) -> [OrnamentStep] {
        let unit = max(1, ticksPerQuarter / 8)
        guard totalTicks >= 3 * unit else {
            report.record(
                .notHonored,
                kind: "ornament: \(kind.rawValue)",
                at: location,
                detail: "the note is too short to alternate; it is sounded plain"
            )
            return []
        }

        var count = min(Self.maximumTrillNotes, totalTicks / unit)
        if count.isMultiple(of: 2) { count -= 1 }
        count = max(3, count)

        var steps: [OrnamentStep] = []
        var offset = 0
        for index in 0..<count {
            let isLast = index == count - 1
            let ticks = isLast
                ? max(1, totalTicks - offset)
                : max(1, totalTicks / count)
            steps.append(
                OrnamentStep(
                    midiNoteNumber: index.isMultiple(of: 2) ? principal : upper,
                    offsetTicks: offset,
                    durationTicks: ticks
                )
            )
            offset += ticks
        }
        return steps
    }

    /// Most notes one trill may produce. A fermata over a trilled whole note
    /// is real music; ten thousand events for one note is a runaway.
    static let maximumTrillNotes = 65

    // MARK: Grace notes

    /// Where a group of grace notes and their principal end up.
    struct GracePlacement {
        let notes: [RealizedNote]
        let principalOnset: Int
        let principalDuration: Int
    }

    /// Places the grace notes printed before a principal note.
    ///
    /// Two readings, and the score chooses between them:
    ///
    /// - an **acciaccatura** (`<grace slash="yes">`) is crushed against the
    ///   beat and takes almost nothing; and
    /// - an **appoggiatura** leans on the beat and takes a real share of the
    ///   principal — half of it, the classical reading.
    ///
    /// `steal-time-previous` moves the group in front of the beat instead,
    /// which is what an engraver writing it means; the principal then keeps
    /// its own onset and full value.
    mutating func placeGraceNotes(
        _ graceNotes: [ScoreGraceNote],
        principalOnset: Int,
        principalDuration: Int,
        notatedDuration: Int,
        velocity: Int,
        entry: StreamEntry,
        ordinal: inout Int
    ) -> GracePlacement {
        // Chorded grace notes share an onset with the one before them.
        var slots: [[ScoreGraceNote]] = []
        for grace in graceNotes {
            if grace.isChordMember, !slots.isEmpty {
                slots[slots.count - 1].append(grace)
            } else {
                slots.append([grace])
            }
        }
        guard !slots.isEmpty, notatedDuration > 0 else {
            return GracePlacement(
                notes: [],
                principalOnset: principalOnset,
                principalDuration: principalDuration
            )
        }

        let first = graceNotes[0]
        let beforeTheBeat = first.stealTimePreviousPercent != nil
        let requested = Self.requestedGraceTicks(
            slots: slots,
            first: first,
            notatedDuration: notatedDuration,
            ticksPerQuarter: ticksPerQuarter
        )
        // Never more than three quarters of the principal: past that the
        // ornament has eaten the note it decorates.
        let total = max(slots.count, min(requested, notatedDuration * 3 / 4))
        let each = max(1, total / slots.count)

        var notes: [RealizedNote] = []
        var offset = beforeTheBeat ? -total : 0
        for (index, slot) in slots.enumerated() {
            let isLast = index == slots.count - 1
            let ticks = isLast ? max(1, total - each * index) : each
            for grace in slot {
                guard let midi = grace.pitch.midiNoteNumber else { continue }
                ordinal += 1
                notes.append(
                    RealizedNote(
                        onsetTicks: max(0, principalOnset + offset),
                        durationTicks: ticks,
                        midiNoteNumber: midi,
                        // A shade under the note it leans on, so the principal
                        // still reads as the note being played.
                        velocity: velocity - 8,
                        origin: .grace,
                        playbackMeasureIndex: entry.playbackMeasureIndex,
                        sourceMeasureIndex: entry.sourceMeasureIndex,
                        ordinal: ordinal
                    )
                )
            }
            offset += ticks
        }

        if beforeTheBeat {
            return GracePlacement(
                notes: notes,
                principalOnset: principalOnset,
                principalDuration: principalDuration
            )
        }
        return GracePlacement(
            notes: notes,
            principalOnset: principalOnset + total,
            principalDuration: max(1, principalDuration - total)
        )
    }

    /// How much time the grace group asks for, before it is capped.
    static func requestedGraceTicks(
        slots: [[ScoreGraceNote]],
        first: ScoreGraceNote,
        notatedDuration: Int,
        ticksPerQuarter: Int
    ) -> Int {
        if let percent = first.stealTimeFollowingPercent {
            return notatedDuration * percent / 100
        }
        if let percent = first.stealTimePreviousPercent {
            return notatedDuration * percent / 100
        }
        if first.isAcciaccatura {
            // Crushed: a thirty-second note apiece, however it is printed.
            return max(1, ticksPerQuarter / 8) * slots.count
        }
        // An appoggiatura leans on the beat. Its printed value when it has
        // one, half the principal when it does not.
        let notated = slots.reduce(0) { $0 + ($1.first?.notatedTicks ?? 0) }
        return notated > 0 ? notated : notatedDuration / 2
    }
}
