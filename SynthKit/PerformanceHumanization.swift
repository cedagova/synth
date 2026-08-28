import Foundation

extension Realization {
    /// Micro-timing at full intensity, in microseconds either side of the
    /// literal position. Twenty-five milliseconds is about the spread between
    /// the hands of a good pianist playing a chord — present, never sloppy.
    static let maximumTimingOffsetMicroseconds = 25_000

    /// Loudness unevenness at full intensity, in MIDI velocity either side.
    static let maximumVelocityJitter = 12

    /// Peak-to-trough of the phrase arch at full intensity, in MIDI velocity.
    static let maximumPhraseAmplitude = 16

    /// Applies humanization to one line's notes (REQ-012).
    ///
    /// Two ingredients, and they are different in kind:
    ///
    /// - **micro-timing and loudness unevenness** — seeded pseudo-noise, one
    ///   value per note derived from that note's own identity, so no note's
    ///   variation depends on how many notes were processed before it; and
    /// - **phrase shaping** — not noise at all, but a deliberate arch across
    ///   each slurred phrase (or, unslurred, each measure), because a player
    ///   swells toward the middle of a phrase and eases out of it. This is
    ///   what makes humanization sound like phrasing rather than like a
    ///   wobble.
    ///
    /// **Off means off.** With humanization disabled — or its intensity at
    /// zero, which changes nothing — this returns without touching a single
    /// value, so the timeline is the literal reading of the score and REQ-012's
    /// "strictly literal" acceptance is a fact about the code path rather than
    /// a threshold a test has to tolerate.
    ///
    /// **Never enough to reorder the music.** The intensity dial alone cannot
    /// set how far a note moves, because a fixed number of milliseconds means
    /// something completely different to a whole note and to one step of a
    /// trill. Each note's offset is additionally bounded by a third of its own
    /// local room — the smaller of the gaps to the notes either side of it —
    /// so two adjacent onsets can close on each other by at most two thirds of
    /// the space between them and can never cross.
    ///
    /// That bound is load-bearing rather than tidy. A reordered trill or a
    /// grace note thrown past its principal is a *different pitch sequence*
    /// from the one this stage realized, so it fails REQ-011 — and it fails it
    /// invisibly, because the result is still perfectly deterministic and every
    /// byte-identity proof still passes. Scaling to the local spacing is also
    /// what a player does: unevenness lives in the note values in front of
    /// them, not in an absolute number of milliseconds.
    func humanize(_ notes: inout [RealizedNote], line: ScoreLine, slurs: [SlurSpan]) {
        guard !settings.humanization.isLiteral else { return }
        let intensity = settings.humanization.intensity

        let timingSpread = Self.maximumTimingOffsetMicroseconds * intensity / 100
        let velocitySpread = Self.maximumVelocityJitter * intensity / 100
        let phraseAmplitude = Self.maximumPhraseAmplitude * intensity / 100
        let room = timingRoomMicroseconds(notes)

        for index in notes.indices {
            let note = notes[index]
            let key = Self.jitterKey(line: line, note: note)
            notes[index].timingOffsetMicroseconds = Int64(
                SeededJitter.signed(
                    SeededJitter.value(seed: seed, key: key),
                    magnitude: min(timingSpread, room[index])
                )
            )
            let uneven = SeededJitter.signed(
                SeededJitter.secondValue(seed: seed, key: key),
                magnitude: velocitySpread
            )
            notes[index].velocity += uneven
                + phraseShape(
                    atTicks: note.onsetTicks,
                    playbackMeasureIndex: note.playbackMeasureIndex,
                    slurs: slurs,
                    amplitude: phraseAmplitude
                )
        }
    }

    /// How far each note may move without colliding with its neighbours: a
    /// third of the smaller gap to the distinct onsets either side of it.
    ///
    /// A third, so that two adjacent notes moving toward each other close at
    /// most two thirds of the space between them and the order is preserved
    /// with room to spare.
    ///
    /// Notes that share an onset — a chord, or two voices of one line — do not
    /// constrain each other: spreading a chord is exactly what humanization is
    /// for. Their room comes from the next *distinct* onset, so a spread chord
    /// still cannot run into the note after it.
    func timingRoomMicroseconds(_ notes: [RealizedNote]) -> [Int] {
        guard !notes.isEmpty else { return [] }

        let order = notes.indices.sorted {
            notes[$0].onsetTicks == notes[$1].onsetTicks
                ? $0 < $1
                : notes[$0].onsetTicks < notes[$1].onsetTicks
        }

        var room = [Int](repeating: Int.max, count: notes.count)
        var position = 0
        var previousOnset: Int?

        while position < order.count {
            // Everything at this onset is one group.
            let onset = notes[order[position]].onsetTicks
            var end = position
            while end + 1 < order.count, notes[order[end + 1]].onsetTicks == onset { end += 1 }
            let nextOnset = end + 1 < order.count ? notes[order[end + 1]].onsetTicks : nil

            let onsetMicroseconds = score.tempoMap.microseconds(atPlaybackTicks: onset)
            var gap = Int64.max
            if let previousOnset {
                gap = min(
                    gap,
                    onsetMicroseconds - score.tempoMap.microseconds(atPlaybackTicks: previousOnset)
                )
            }
            if let nextOnset {
                gap = min(
                    gap,
                    score.tempoMap.microseconds(atPlaybackTicks: nextOnset) - onsetMicroseconds
                )
            }

            let allowance = gap == Int64.max
                ? Self.maximumTimingOffsetMicroseconds
                : Int(max(0, gap / 3))
            for slot in position...end { room[order[slot]] = allowance }

            previousOnset = onset
            position = end + 1
        }
        return room
    }

    /// The canonical identity of one note, for keying its variation.
    ///
    /// Every field that distinguishes this note from another *that should
    /// sound differently* is in here, and nothing else is. In particular the
    /// note's position in any list is not: that is the whole point, because a
    /// list position is exactly the thing that is not stable across a
    /// reordering.
    static func jitterKey(line: ScoreLine, note: RealizedNote) -> String {
        [
            line.id.rawValue,
            String(note.playbackMeasureIndex),
            String(note.onsetTicks),
            String(note.midiNoteNumber),
            note.origin.rawValue,
            String(note.ordinal)
        ].joined(separator: "\u{1F}")
    }

    /// Where this note sits in the arch of its phrase, in MIDI velocity.
    ///
    /// The phrase is the slur when the note is under one and the playback
    /// measure otherwise. The arch is `4x(n-x)/n²` — zero at both ends, one in
    /// the middle — computed in integers so nothing here can round differently
    /// on another machine, and centred so a phrase is not simply louder than
    /// an unphrased one.
    func phraseShape(
        atTicks ticks: Int,
        playbackMeasureIndex: Int,
        slurs: [SlurSpan],
        amplitude: Int
    ) -> Int {
        guard amplitude > 0 else { return 0 }

        var start = 0
        var end = 0
        if let span = Self.slurSpan(containing: ticks, in: slurs) {
            start = span.startTicks
            end = span.endTicks
        } else if score.playbackMeasures.indices.contains(playbackMeasureIndex) {
            let measure = score.playbackMeasures[playbackMeasureIndex]
            start = measure.startTicks
            end = measure.endTicks
        }

        let span = Int64(end - start)
        guard span > 0 else { return 0 }
        let offset = Int64(max(0, min(ticks - start, end - start)))
        let arch = 4_000 * offset * (span - offset) / (span * span)
        return Int(Int64(amplitude) * arch / 1_000) - amplitude / 2
    }

    /// The slur covering `ticks`, or nil.
    ///
    /// Binary search rather than a scan: spans are built in playback order and
    /// cannot overlap, and a long piece has as many of them as it has notes —
    /// a scan per note would make phrase shaping quadratic in the length of
    /// the piece.
    static func slurSpan(containing ticks: Int, in slurs: [SlurSpan]) -> SlurSpan? {
        guard !slurs.isEmpty, ticks >= slurs[0].startTicks else { return nil }

        var low = 0
        var high = slurs.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if slurs[middle].startTicks <= ticks { low = middle } else { high = middle - 1 }
        }
        return ticks < slurs[low].endTicks ? slurs[low] : nil
    }
}
