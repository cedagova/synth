import Foundation

// MARK: - Phrases

extension Realization {
    /// One phrase of one line: where it starts, where it ends, and how firmly
    /// it ends.
    ///
    /// A phrase is the unit both halves of this stage are measured against — a
    /// dynamic arch spans one, a breath falls between two — so it is a value
    /// rather than a pair of loose indices. Ticks rather than list positions,
    /// because ornament and grace notes are placed inside a principal's span
    /// and have no position in the group list at all.
    struct Phrase {
        /// Notated onset of the phrase's first sounding group.
        let startTicks: Int

        /// Notated end of the phrase's last sounding group. The arch is
        /// measured over `startTicks..<endTicks`.
        let endTicks: Int

        /// Onset of the phrase's last sounding group, which is the group a
        /// breath shortens.
        let lastOnsetTicks: Int

        /// How firmly the phrase ends, 1…3. A written silence is the clearest
        /// ending there is (3), a slur or a cadential arrival a clear one (2),
        /// and a break taken only because the phrase had run long is the
        /// weakest (1). Both the breath and the cadential softening scale with
        /// it, so the reading stays proportional to the evidence for it.
        let endStrength: Int

        /// How many sounding groups the phrase holds.
        let onsetCount: Int
    }

    // MARK: Constants

    /// Peak-to-trough of the phrase arch at amount 100, in MIDI velocity.
    ///
    /// Smaller than a printed dynamic step on purpose: this is the shape
    /// *inside* whatever the engraver wrote, and a phrase that swelled through
    /// a `p` marking into an `f` would be overruling the notation rather than
    /// performing it.
    static let maximumPhraseAmplitudeExpressive = 14

    /// How much a cadence eases off at amount 100 and the firmest ending, in
    /// MIDI velocity.
    static let maximumCadenceSoftening = 10

    /// How long the easing-off before a phrase end lasts, in quarter notes.
    static let cadenceTailQuarters = 2

    /// The longest breath, at amount 100 and the firmest ending, in
    /// microseconds. Seventy milliseconds is an audible lift between phrases
    /// and well inside the quarter-note spacing of even a fast piece — and it
    /// is bounded again by the local note spacing before it is applied.
    static let maximumBreathMicroseconds = 70_000

    /// The largest fraction of its own sounding length a phrase-final note is
    /// released early by, as a reciprocal: a quarter of it, at amount 100 and
    /// the firmest ending.
    ///
    /// Bounding the lift by the note's *own* length is what makes it safe
    /// without a neighbour check: a note released early can never run into
    /// anything.
    static let breathLiftDivisor = 4

    /// Below this sounding length a note is not lifted at all: a trill step or
    /// a crushed grace note has no release to shape, and shortening it further
    /// would only risk making it inaudible.
    static let shortestLiftableMicroseconds: Int64 = 20_000

    /// A gap at least this long — an eighth note — between one group's notated
    /// end and the next group's onset is read as a phrase end.
    ///
    /// Measured on *notated* ends rather than sounding ones, so the ordinary
    /// détaché shortening every unmarked note already gets cannot manufacture
    /// a silence the score never wrote.
    var phraseRestThresholdTicks: Int { max(1, ticksPerQuarter / 2) }

    /// How long a phrase may run before it is broken at a measure line anyway.
    ///
    /// Without this a line of unbroken, unslurred, evenly-valued notes would be
    /// one phrase from bar 1 to the end and its arch would flatten into
    /// nothing. Four measures is the default phrase length of most of the
    /// repertoire this plays.
    static let maximumPhrasePlaybackMeasures = 4

    /// Fewer sounding groups than this is not a phrase. A one-note "phrase"
    /// has no arch to shape and no interior to breathe into.
    static let minimumPhraseOnsets = 2

    // MARK: Segmentation

    /// One sounding or silent position on the line's notated grid.
    private struct OnsetGroup {
        let onsetTicks: Int
        let notatedEndTicks: Int
        let notatedDurationTicks: Int
        /// Highest sounding pitch of the group, or nil when every member is a
        /// rest. The top of a chord is the line the ear follows, which is what
        /// a cadential step has to be measured on.
        let topMidiNoteNumber: Int?
    }

    /// The line's phrases, or an empty list when this line gets no shaping at
    /// all.
    ///
    /// Empty is returned in exactly two cases, and both are contracts rather
    /// than conveniences:
    ///
    /// - **expression is off or at zero** — REQ-004's bypass. Nothing below
    ///   runs, so the timeline is the realization from before this setting
    ///   existed, byte for byte, rather than one that happens to look similar;
    ///   and
    /// - **the line has fewer than two sounding positions** — a degenerate
    ///   line passes through untouched, because there is no phrase to read.
    func expressionPhrases(_ stream: [StreamEntry], slurs: [SlurSpan]) -> [Phrase] {
        guard !settings.expression.isNeutral else { return [] }

        let groups = onsetGroups(stream)
        let sounding = groups.filter { $0.topMidiNoteNumber != nil }
        guard sounding.count >= Self.minimumPhraseOnsets else { return [] }

        // Slur ends, as a set of notated end ticks: a slur closes a phrase at
        // the notated end of the note it closes on.
        let slurEnds = Set(slurs.map(\.endTicks))

        var phrases: [Phrase] = []
        var startIndex = 0
        var measuresSpanned = 1

        for index in sounding.indices {
            let group = sounding[index]
            let isLast = index == sounding.count - 1
            let next: OnsetGroup? = isLast ? nil : sounding[index + 1]

            if let next,
               measureIndex(atTicks: next.onsetTicks) != measureIndex(atTicks: group.onsetTicks) {
                measuresSpanned += 1
            }

            var strength = 0
            if let next, next.onsetTicks - group.notatedEndTicks >= phraseRestThresholdTicks {
                // A written silence: the clearest phrase end there is.
                strength = 3
            } else if slurEnds.contains(group.notatedEndTicks) {
                strength = 2
            } else if isCadentialArrival(at: index, in: sounding) {
                strength = 2
            } else if measuresSpanned >= Self.maximumPhrasePlaybackMeasures,
                      let next,
                      measureIndex(atTicks: next.onsetTicks)
                        != measureIndex(atTicks: group.onsetTicks) {
                // Nothing in the notation said to break, but the phrase has
                // run its length; break at the bar line rather than let the
                // arch flatten.
                strength = 1
            }
            // The last sounding group always closes the last phrase, at full
            // strength: the end of the line is the firmest ending there is,
            // whether or not the engraver marked it. It gets the easing-off
            // that goes with that — but no breath, because there is no next
            // phrase to breathe into and a final note should ring rather than
            // be clipped.
            if isLast { strength = 3 }

            guard strength > 0 else { continue }
            phrases.append(
                Phrase(
                    startTicks: sounding[startIndex].onsetTicks,
                    endTicks: max(sounding[startIndex].onsetTicks + 1, group.notatedEndTicks),
                    lastOnsetTicks: group.onsetTicks,
                    endStrength: strength,
                    onsetCount: index - startIndex + 1
                )
            )
            startIndex = index + 1
            measuresSpanned = 1
        }

        return Self.merginglyShortPhrasesRemoved(phrases)
    }

    /// The line's notated positions, one per distinct onset, in ascending tick
    /// order.
    ///
    /// Sorted explicitly rather than trusting the stream's order: the stream is
    /// built per measure from a grouped dictionary, and a phrase read off a
    /// list that was *nearly* sorted would be a determinism bug that only
    /// showed up on some scores. The sort is on `(ticks, position)`, so it is
    /// total and cannot reorder between runs.
    private func onsetGroups(_ stream: [StreamEntry]) -> [OnsetGroup] {
        let order = stream.indices.sorted {
            stream[$0].absoluteTicks == stream[$1].absoluteTicks
                ? $0 < $1
                : stream[$0].absoluteTicks < stream[$1].absoluteTicks
        }

        var groups: [OnsetGroup] = []
        var position = 0
        while position < order.count {
            let onset = stream[order[position]].absoluteTicks
            var end = position
            while end + 1 < order.count,
                  stream[order[end + 1]].absoluteTicks == onset { end += 1 }

            var notatedEnd = onset
            var duration = 0
            var top: Int?
            for slot in position...end {
                let note = stream[order[slot]].note
                guard let midi = note.pitch?.midiNoteNumber else { continue }
                notatedEnd = max(notatedEnd, onset + note.durationTicks)
                duration = max(duration, note.durationTicks)
                top = max(top ?? midi, midi)
            }
            // A group of nothing but rests still holds its place on the grid,
            // so the gap it makes is measured from where it ends.
            if top == nil {
                for slot in position...end {
                    notatedEnd = max(notatedEnd, onset + stream[order[slot]].note.durationTicks)
                }
            }

            groups.append(
                OnsetGroup(
                    onsetTicks: onset,
                    notatedEndTicks: notatedEnd,
                    notatedDurationTicks: duration,
                    topMidiNoteNumber: top
                )
            )
            position = end + 1
        }
        return groups
    }

    /// True when this group reads as a cadential arrival.
    ///
    /// Two surface cues a single line actually carries, and both are required:
    ///
    /// - **agogic weight** — the note is at least twice as long as the one
    ///   before it, which is how a player hears an arrival when no harmony
    ///   analysis is available; and
    /// - **approach by step** — the line moves into it by a semitone or a
    ///   tone, the motion every cadence in this repertoire ends with.
    ///
    /// Requiring both is what keeps this from firing on every long note in a
    /// sustained inner part. Deliberately no harmonic analysis: reading
    /// function out of a single line would be guessing, and guessing wrongly
    /// here puts a breath in the middle of a phrase.
    private func isCadentialArrival(at index: Int, in sounding: [OnsetGroup]) -> Bool {
        guard index > 0 else { return false }
        let group = sounding[index]
        let previous = sounding[index - 1]
        guard group.notatedDurationTicks >= 2 * max(1, previous.notatedDurationTicks) else {
            return false
        }
        guard let top = group.topMidiNoteNumber, let before = previous.topMidiNoteNumber else {
            return false
        }
        let step = abs(top - before)
        return step >= 1 && step <= 2
    }

    /// Which playback measure a tick falls in, or -1 past the end.
    private func measureIndex(atTicks ticks: Int) -> Int {
        let measures = score.playbackMeasures
        guard !measures.isEmpty, ticks >= measures[0].startTicks else { return -1 }

        var low = 0
        var high = measures.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if measures[middle].startTicks <= ticks { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Folds any phrase too short to shape into its neighbour.
    ///
    /// A single note left over between two breaks — the tail of a slur that
    /// ends one note before a rest, say — would otherwise get a full arch
    /// across one note and a breath on both sides of it, which is a hiccup
    /// rather than phrasing.
    static func merginglyShortPhrasesRemoved(_ phrases: [Phrase]) -> [Phrase] {
        guard phrases.count > 1 else { return phrases }

        var out: [Phrase] = []
        for phrase in phrases {
            guard phrase.onsetCount < minimumPhraseOnsets, let previous = out.last else {
                out.append(phrase)
                continue
            }
            // Absorbed backwards: the stub belongs to the phrase it trails,
            // and that phrase now ends where the stub does.
            out[out.count - 1] = Phrase(
                startTicks: previous.startTicks,
                endTicks: max(previous.endTicks, phrase.endTicks),
                lastOnsetTicks: phrase.lastOnsetTicks,
                endStrength: max(previous.endStrength, phrase.endStrength),
                onsetCount: previous.onsetCount + phrase.onsetCount
            )
        }

        // A leading stub has nothing behind it to join, so it joins forwards.
        if let first = out.first, first.onsetCount < minimumPhraseOnsets, out.count > 1 {
            let second = out[1]
            out[1] = Phrase(
                startTicks: first.startTicks,
                endTicks: second.endTicks,
                lastOnsetTicks: second.lastOnsetTicks,
                endStrength: second.endStrength,
                onsetCount: first.onsetCount + second.onsetCount
            )
            out.removeFirst()
        }
        return out
    }

    /// The phrase `ticks` belongs to, or nil when there are none.
    ///
    /// Binary search, for the reason `slurSpan(containing:)` uses one: phrases
    /// are as numerous as the phrases in the piece and this is asked once per
    /// note. A tick past a phrase's end but before the next one begins — the
    /// silence of a breath — belongs to the phrase it just left, which is what
    /// makes a note placed inside a rest region shade with its own phrase.
    static func phrase(containing ticks: Int, in phrases: [Phrase]) -> Phrase? {
        guard let first = phrases.first else { return nil }
        guard ticks >= first.startTicks else { return first }

        var low = 0
        var high = phrases.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if phrases[middle].startTicks <= ticks { low = middle } else { high = middle - 1 }
        }
        return phrases[low]
    }

    // MARK: Shaped dynamics (REQ-003)

    /// Shades each note by where it sits in its phrase (REQ-003).
    ///
    /// **Two shapes, and they are different in kind.** An arch across the
    /// phrase — a player leans into a phrase and eases out of it — and an
    /// easing-off into the phrase's ending, proportional to how firm that
    /// ending is. The first is what makes a long line breathe; the second is
    /// what makes a cadence sound like an arrival instead of a note that
    /// happens to be last.
    ///
    /// **Not the same thing as humanization's arch, and not a duplicate of
    /// it.** Humanization arches over a slur or, failing that, a single
    /// measure, symmetrically, and scales with the humanization amount: it is
    /// the shape of a *gesture*. This arches over a phrase — which may be four
    /// measures of several slurs and is bounded by rests and cadences as well
    /// — asymmetrically, peaking past the middle, and scales with the
    /// expression amount. They add, as two things a player does at once.
    ///
    /// Every value is an integer and every division is exact: nothing here can
    /// round differently on another machine, which is what the frozen digests
    /// rely on.
    func shapePhraseDynamics(_ notes: inout [RealizedNote], phrases: [Phrase]) {
        guard !phrases.isEmpty else { return }
        let amount = settings.expression.amount
        let amplitude = Self.maximumPhraseAmplitudeExpressive * amount / 100
        let softening = Self.maximumCadenceSoftening * amount / 100
        let tail = ticksPerQuarter * Self.cadenceTailQuarters

        for index in notes.indices {
            guard let phrase = Self.phrase(containing: notes[index].onsetTicks, in: phrases) else {
                continue
            }
            notes[index].velocity += Self.phraseArch(
                atTicks: notes[index].onsetTicks, phrase: phrase, amplitude: amplitude
            )
            notes[index].velocity -= Self.cadentialEasing(
                atTicks: notes[index].onsetTicks,
                phrase: phrase,
                tailTicks: tail,
                magnitude: softening
            )
        }
    }

    /// Where `ticks` sits in the arch of `phrase`, in MIDI velocity.
    ///
    /// Peaking at five eighths of the way through rather than halfway, because
    /// that is where a phrase's weight actually falls — a symmetrical hump is
    /// the shape of a swell, not of a phrase. Centred on zero, so a phrase is
    /// shaped rather than simply made louder and the written dynamic still
    /// governs the level.
    static func phraseArch(atTicks ticks: Int, phrase: Phrase, amplitude: Int) -> Int {
        guard amplitude > 0 else { return 0 }
        let span = phrase.endTicks - phrase.startTicks
        guard span > 0 else { return 0 }

        let offset = max(0, min(ticks - phrase.startTicks, span))
        let peak = max(1, min(span - 1, span * 5 / 8))
        let rise = offset <= peak
            ? 1_000 * offset / peak
            : 1_000 * (span - offset) / max(1, span - peak)
        return amplitude * rise / 1_000 - amplitude / 2
    }

    /// How much `ticks` eases off into its phrase's ending, in MIDI velocity.
    ///
    /// Zero until the last couple of beats of the phrase, then a straight ramp
    /// to the full amount at the very end, scaled by how firm the ending is: a
    /// phrase broken only because it had run long barely eases at all, a
    /// phrase ending in a written silence eases fully.
    static func cadentialEasing(
        atTicks ticks: Int,
        phrase: Phrase,
        tailTicks: Int,
        magnitude: Int
    ) -> Int {
        guard magnitude > 0, tailTicks > 0 else { return 0 }
        let span = phrase.endTicks - phrase.startTicks
        let window = min(tailTicks, span)
        guard window > 0 else { return 0 }

        let remaining = phrase.endTicks - ticks
        guard remaining < window else { return 0 }
        let depth = window - max(0, remaining)
        return magnitude * phrase.endStrength * depth / (3 * window)
    }

    // MARK: Breathing (REQ-003)

    /// Lets the line breathe at its phrase ends (REQ-003).
    ///
    /// Two halves of one gesture: the phrase's last note is lifted a little
    /// early, and the next phrase starts a little late. Both scale with the
    /// amount and with how firm the ending is.
    ///
    /// **The transport cannot move.** Nothing here touches `onsetTicks` or
    /// `playbackMeasureIndex` — the lateness is carried in
    /// `timingOffsetMicroseconds`, exactly as humanization's micro-timing is,
    /// so the measure the readout names is still the measure the score wrote
    /// however the performance leans. That is the constraint in the issue about
    /// breathing never breaking the readout's measure alignment, and it is
    /// satisfied structurally rather than by keeping the numbers small.
    ///
    /// **And the order cannot change.** The lateness is clamped, together with
    /// whatever humanization already asked for, into the same local-room bound
    /// humanization uses: a third of the smaller gap to the onsets either side.
    /// A breath that pushed a note past its neighbour would be a different
    /// pitch sequence from the one this stage realized — deterministically
    /// wrong, and invisible to every byte-identity proof.
    func breathe(_ notes: inout [RealizedNote], phrases: [Phrase]) {
        guard phrases.count > 1 else { return }
        let amount = settings.expression.amount

        // Where a breath falls: the tick a phrase ends on, and the tick the
        // next phrase starts on, with the strength of the ending between them.
        var liftStrength: [Int: Int] = [:]
        var delayStrength: [Int: Int] = [:]
        for (index, phrase) in phrases.enumerated() where index + 1 < phrases.count {
            liftStrength[phrase.lastOnsetTicks] = max(
                liftStrength[phrase.lastOnsetTicks] ?? 0, phrase.endStrength
            )
            let nextStart = phrases[index + 1].startTicks
            delayStrength[nextStart] = max(delayStrength[nextStart] ?? 0, phrase.endStrength)
        }

        let room = timingRoomMicroseconds(notes)
        for index in notes.indices {
            if let strength = delayStrength[notes[index].onsetTicks] {
                let breath = Int64(Self.maximumBreathMicroseconds * amount / 100 * strength / 3)
                let allowance = Int64(room[index] == Int.max ? Int.max / 2 : room[index])
                notes[index].timingOffsetMicroseconds = min(
                    allowance,
                    max(-allowance, notes[index].timingOffsetMicroseconds + breath)
                )
            }

            guard let strength = liftStrength[notes[index].onsetTicks] else { continue }
            let note = notes[index]
            let sounding = score.tempoMap.microseconds(
                atPlaybackTicks: min(note.onsetTicks + note.durationTicks, totalTicks)
            ) - score.tempoMap.microseconds(atPlaybackTicks: note.onsetTicks)
            guard sounding > Self.shortestLiftableMicroseconds else { continue }
            notes[index].breathShorteningMicroseconds =
                sounding * Int64(amount) * Int64(strength)
                    / Int64(100 * 3 * Self.breathLiftDivisor)
        }
    }
}
