import Foundation

// MARK: - Per-passage melody/accompaniment balance (REQ-003)

/// The second half of the expression setting's score reading: which line the ear
/// is meant to follow, passage by passage, and a small amount of level shading
/// that lets it through.
///
/// **Where this belongs, and where it deliberately does not.** The decision is
/// per *passage*, so it lives in the timeline as a velocity shading of realized
/// events (AD-P1) and not on the mixer: a mixer strip is one number for the
/// whole piece, and the line that leads in bar 9 is often not the one that led
/// in bar 1. That is the PR #64 reconciliation the plan records as P65-2 — no
/// static per-line level shading anywhere, per-passage balance here, loudness in
/// the master — and it is why this reads `ScoreLine` notes rather than
/// `LineMixerState`.
///
/// **Its constants live on `Realization` beside the phrasing ones**, which is
/// the home EXP001 established for expression taste; this file holds a different
/// problem from `PerformancePhrasing.swift` for the same reason the realization
/// is split across files at all, not a second constants home.
extension Realization {
    // MARK: Constants

    /// How far the leading line is lifted above what the notation wrote, at
    /// amount 100, in MIDI velocity.
    ///
    /// Six, judged against the two numbers that bracket it: a printed dynamic
    /// step on `ScoreDynamic.ladder` is about sixteen, and the phrase arch is
    /// fourteen peak-to-trough. Six up and six down is a twelve-velocity
    /// separation at the top of the dial — clearly "above the accompaniment",
    /// still inside the dynamic the engraver wrote, and below the shape of the
    /// phrase it sits in. At the default amount of 50 it is three each way.
    static let maximumBalanceLift = 6

    /// How far every other sounding line is set back, at amount 100, in MIDI
    /// velocity.
    ///
    /// The same size as the lift, so balancing a passage separates the lines
    /// without making the passage louder. An asymmetric pair would let the
    /// overall level drift with how many lines happen to be playing, which is
    /// the master's business (MST001) rather than this reading's.
    static let maximumBalanceDuck = 6

    /// How many playback measures one passage spans.
    ///
    /// Two: long enough that a subject entry or an answer is judged as a unit
    /// rather than beat by beat, short enough to follow a melody that moves
    /// between lines. Longer windows average an imitative texture into
    /// ambiguity; a window of one measure flickers on an ordinary exchange.
    static let balancePassageMeasures = 2

    /// How far above every other sounding line a line must sit before it is read
    /// as leading, in semitones.
    ///
    /// A major third. The ear follows the top line, but "top" has to mean
    /// clearly top: two lines weaving inside the same third are a duet, not a
    /// melody and its accompaniment, and the honest answer there is to leave
    /// both alone.
    static let clearLeadSemitones = 4

    /// Fewer attacks than this in a passage and a line is not a candidate to
    /// lead it.
    ///
    /// Two, because two is the least that can show a melodic move at all, and
    /// the move itself is required separately below. A line with one attack in
    /// the passage is holding a note, not stating a melody — and if that note is
    /// the highest thing in the passage, the clear-lead test fails for everyone
    /// and the passage is left alone, which is the right answer rather than a
    /// near miss.
    static let minimumBalanceAttacks = 2

    // MARK: The shading

    /// Velocity shading for one line, passage by passage.
    ///
    /// Carried as a value rather than read back out of a shared table, so one
    /// line's realization cannot see another's — the realizer builds lines
    /// independently and this keeps that true.
    struct PassageBalance {
        /// Start tick of each passage, ascending. Passage `i` runs from
        /// `passageStartTicks[i]` until the next one begins.
        let passageStartTicks: [Int]

        /// What this line's notes are shaded by in each passage, in MIDI
        /// velocity. Same length as `passageStartTicks`.
        let deltaByPassage: [Int]

        /// Nothing to apply: expression off, a texture with no clear lead, or a
        /// line that is silent throughout.
        static let none = PassageBalance(passageStartTicks: [], deltaByPassage: [])

        var isNeutral: Bool { deltaByPassage.allSatisfy { $0 == 0 } }

        /// The shading in force at `ticks`.
        func delta(atTicks ticks: Int) -> Int {
            guard !deltaByPassage.isEmpty else { return 0 }
            return deltaByPassage[
                Realization.passageIndex(ofTicks: ticks, in: passageStartTicks)
            ]
        }
    }

    /// Shades each note by whether its line leads the passage it sits in
    /// (REQ-003).
    func applyPassageBalance(_ notes: inout [RealizedNote], balance: PassageBalance) {
        guard !balance.isNeutral else { return }
        for index in notes.indices {
            notes[index].velocity += balance.delta(atTicks: notes[index].onsetTicks)
        }
    }

    // MARK: Reading the texture

    /// What one line does in one passage, as the ear would take it.
    ///
    /// Attacks rather than notes: a tie continuation is the line still sounding
    /// what it already started, and a chord is one attack at the pitch on top of
    /// it — "the top of a chord is the line the ear follows", the same reading
    /// `PerformancePhrasing` takes for a cadential step.
    struct PassageVoice {
        /// The ticks this line attacks on, ascending.
        let attackTicks: [Int]

        /// The top sounding pitch at each of those attacks, in the same order.
        let attackTopPitches: [Int]

        /// Median of `attackTopPitches`, or -1 when the line does not attack.
        ///
        /// The median, and the lower of two middles, exactly as `LineRegister`
        /// takes it: one high note in an inner part must not move where that
        /// part sits, and the answer should be a pitch the line actually played
        /// rather than a quarter-tone between two.
        let medianMIDINote: Int

        /// How many attacks arrive on a different pitch from the one before.
        let pitchChanges: Int

        var attacks: Int { attackTicks.count }

        /// True when this line attacks on `ticks`.
        func attacks(atTicks ticks: Int) -> Bool {
            var low = 0
            var high = attackTicks.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if attackTicks[middle] == ticks { return true }
                if attackTicks[middle] < ticks { low = middle + 1 } else { high = middle - 1 }
            }
            return false
        }

        /// True when this line's attacks fall on exactly the same ticks as
        /// `other`'s — the two move together.
        func movesWith(_ other: PassageVoice) -> Bool { attackTicks == other.attackTicks }

        init(topByAttackTick: [Int: Int]) {
            // Sorted explicitly: the grouping above is a dictionary, and a
            // reading taken off its iteration order would be a determinism bug
            // that only showed up on some launches. `Int` keys sort totally.
            let ticks = topByAttackTick.keys.sorted()
            let tops = ticks.map { topByAttackTick[$0] ?? 0 }
            self.attackTicks = ticks
            self.attackTopPitches = tops

            let ordered = tops.sorted()
            self.medianMIDINote = ordered.isEmpty ? -1 : ordered[(ordered.count - 1) / 2]

            var changes = 0
            for (earlier, later) in zip(tops, tops.dropFirst()) where earlier != later {
                changes += 1
            }
            self.pitchChanges = changes
        }
    }

    /// The balance for every line of the score, in `score.lines` order.
    ///
    /// Empty — `PassageBalance.none` for every line — in exactly these cases,
    /// and each is a contract rather than a convenience:
    ///
    /// - **expression is off or at zero**, which is REQ-004's bypass. Nothing
    ///   below runs and no velocity moves, so the off state is the realization
    ///   from before this leaf existed rather than one that happens to look
    ///   similar; and
    /// - **the score has fewer than two lines**, where there is no balance to
    ///   strike.
    func passageBalance(streams: [[StreamEntry]]) -> [PassageBalance] {
        let neutral = [PassageBalance](repeating: .none, count: streams.count)
        guard !settings.expression.isNeutral, streams.count >= 2 else { return neutral }

        let starts = balancePassageStartTicks()
        guard !starts.isEmpty else { return neutral }

        let amount = settings.expression.amount
        let lift = Self.maximumBalanceLift * amount / 100
        let duck = Self.maximumBalanceDuck * amount / 100
        guard lift > 0 || duck > 0 else { return neutral }

        let voices = streams.map { passageVoices($0, passageStartTicks: starts) }
        var deltas = [[Int]](
            repeating: [Int](repeating: 0, count: starts.count),
            count: streams.count
        )
        for passage in starts.indices {
            guard let leader = leadingLine(inPassage: passage, voices: voices) else { continue }
            for line in streams.indices where voices[line][passage].attacks > 0 {
                deltas[line][passage] = line == leader ? lift : -duck
            }
        }
        return streams.indices.map {
            PassageBalance(passageStartTicks: starts, deltaByPassage: deltas[$0])
        }
    }

    /// Which line leads `passage`, or nil when the texture does not say.
    ///
    /// **Three surface cues, all three required**, in the shape
    /// `PerformancePhrasing.isCadentialArrival` uses for the same reason: a
    /// single cue fires on textures that are nothing like the thing it is
    /// looking for, and guessing wrongly here is expensive — it ducks three
    /// lines to push forward a part that was never the melody. Failing to fire
    /// is cheap: the passage renders exactly as the notation wrote it.
    ///
    /// - **clearly the top line** — its median attack pitch sits at least
    ///   `clearLeadSemitones` above *every* other line that attacks in the
    ///   passage, including the ones with too few attacks to be candidates
    ///   themselves. That last part is what stops a high sustained note from
    ///   being out-voted and then ducked;
    /// - **melodically active** — it arrives on a new pitch at least half the
    ///   times it attacks. A high ostinato on one note and a drone are the
    ///   textures this rules out; and
    /// - **rhythmically its own** — at least one other line that attacks in the
    ///   passage attacks on a different set of ticks. When every line attacks
    ///   together the texture is homophonic or in unison, there is no melody and
    ///   accompaniment to separate, and the passage balances neutrally.
    ///
    /// No harmonic analysis, deliberately, for the reason the cadence reading
    /// gives: function read out of a compiled line is a guess, and this one
    /// would be heard.
    func leadingLine(inPassage passage: Int, voices: [[PassageVoice]]) -> Int? {
        var active: [Int] = []
        for line in voices.indices where voices[line][passage].attacks > 0 {
            active.append(line)
        }
        guard active.count >= 2 else { return nil }

        // Highest median and runner-up in one scan, in line order, so a tie
        // keeps the earlier line and nothing depends on iteration order. A tie
        // at the top cannot clear the margin below, which is how two equally
        // high lines end up with no leader rather than an arbitrary one.
        var highest = -1
        var runnerUp = -1
        var leader = -1
        for line in active {
            let median = voices[line][passage].medianMIDINote
            if median > highest {
                runnerUp = highest
                highest = median
                leader = line
            } else if median > runnerUp {
                runnerUp = median
            }
        }
        guard leader >= 0, highest - runnerUp >= Self.clearLeadSemitones else { return nil }

        let voice = voices[leader][passage]
        guard voice.attacks >= Self.minimumBalanceAttacks else { return nil }
        guard voice.pitchChanges * 2 >= voice.attacks else { return nil }

        let movesWithEveryone = active.allSatisfy {
            $0 == leader || voices[$0][passage].movesWith(voice)
        }
        return movesWithEveryone ? nil : leader
    }

    /// One line's attacks, bucketed into passages.
    func passageVoices(
        _ stream: [StreamEntry],
        passageStartTicks starts: [Int]
    ) -> [PassageVoice] {
        var topByTick = [[Int: Int]](repeating: [:], count: starts.count)
        for entry in stream {
            // A rest is not an attack, and neither is the far end of a tie: the
            // line is still sounding the note it started earlier, so counting it
            // would make a line of tied whole notes look as busy as a melody.
            guard let midi = entry.note.pitch?.midiNoteNumber, !entry.note.tiesBackward else {
                continue
            }
            let passage = Self.passageIndex(ofTicks: entry.absoluteTicks, in: starts)
            let tick = entry.absoluteTicks
            topByTick[passage][tick] = max(topByTick[passage][tick] ?? midi, midi)
        }
        return topByTick.map { PassageVoice(topByAttackTick: $0) }
    }

    /// Where each passage begins, in absolute playback ticks.
    ///
    /// Measured off the playback measures rather than a fixed tick stride, so a
    /// passage is the same musical length under a time-signature change and a
    /// repeat brings its own passages back with it.
    func balancePassageStartTicks() -> [Int] {
        let measures = score.playbackMeasures
        guard !measures.isEmpty else { return [] }
        var starts: [Int] = []
        var index = 0
        while index < measures.count {
            starts.append(measures[index].startTicks)
            index += Self.balancePassageMeasures
        }
        return starts
    }

    /// Which passage `ticks` falls in.
    ///
    /// Binary search, for the reason the phrase lookup uses one: this is asked
    /// once per realized note. A tick before the first passage belongs to it —
    /// a pickup measure's grace note is in the passage it leads into.
    static func passageIndex(ofTicks ticks: Int, in starts: [Int]) -> Int {
        guard let first = starts.first, ticks > first else { return 0 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= ticks { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
