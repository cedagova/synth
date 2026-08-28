import Foundation

// MARK: - Shaping tables

/// How the notation changes a note's length and loudness.
///
/// A table rather than a chain of conditions, because these are conventions to
/// be read and argued with, not logic. The percentages are the ordinary
/// readings a player would give: a staccato quarter is about half its written
/// length, a marcato is short *and* loud, a tenuto is its full value.
enum ArticulationShaping {
    /// Percentage of the notated value the note actually sounds, or nil when
    /// the articulation does not shorten it.
    static func durationPercent(_ articulation: ScoreArticulation) -> Int? {
        switch articulation {
        case .staccatissimo: return 25
        case .spiccato: return 35
        case .staccato: return 50
        case .strongAccent: return 70
        case .detachedLegato: return 75
        case .tenuto: return 100
        case .accent, .softAccent, .stress, .unstress: return nil
        }
    }

    /// How much louder or softer the articulation makes the note.
    static func velocityDelta(_ articulation: ScoreArticulation) -> Int {
        switch articulation {
        case .strongAccent: return 26
        case .accent: return 16
        case .softAccent: return 8
        case .stress: return 8
        case .tenuto: return 4
        case .unstress: return -8
        case .staccato, .staccatissimo, .spiccato, .detachedLegato: return 0
        }
    }

    /// The shortest reading among the marks on one note, and their combined
    /// loudness change.
    static func combined(_ articulations: [ScoreArticulation]) -> (percent: Int?, velocity: Int) {
        var percent: Int?
        var velocity = 0
        for articulation in articulations {
            if let candidate = durationPercent(articulation) {
                percent = min(percent ?? candidate, candidate)
            }
            velocity += velocityDelta(articulation)
        }
        return (percent, velocity)
    }
}

// MARK: - Intermediate note

/// One sounding note, still measured in ticks.
///
/// Realization happens on the tick grid and converts to microseconds once, at
/// the end. Shaping in ticks keeps every intermediate value exact; shaping in
/// microseconds would round at every step and make a tempo change inside a
/// slur drift.
struct RealizedNote {
    var onsetTicks: Int
    var durationTicks: Int
    var midiNoteNumber: Int
    var velocity: Int
    var origin: PerformanceEventOrigin
    var playbackMeasureIndex: Int
    var sourceMeasureIndex: Int

    /// Distinguishes notes that would otherwise share a humanization key —
    /// the notes of one trill, or two grace notes of one chord.
    var ordinal: Int

    /// Micro-timing, applied after the tick grid has been converted to time.
    ///
    /// Kept out of `onsetTicks` deliberately: the tick is where the score says
    /// the note is, and the transport highlights it there however the
    /// performance leans. Humanization moves when it *sounds*, not where it
    /// *is*.
    var timingOffsetMicroseconds: Int64 = 0
}

extension Realization {
    /// One entry of a line's playback stream: a notated note at the absolute
    /// tick it is played at on this pass.
    struct StreamEntry {
        let note: ScoreNote
        let absoluteTicks: Int
        let playbackMeasureIndex: Int
        let sourceMeasureIndex: Int
    }

    /// A stretch of the timeline under at least one slur.
    struct SlurSpan {
        let startTicks: Int
        let endTicks: Int
    }

    // MARK: Line

    mutating func realize(
        line: ScoreLine,
        curve: DynamicCurve,
        pedalSpans: [PerformancePedalSpan]
    ) -> PerformanceLine {
        let stream = buildStream(line)
        let slurs = slurSpans(stream, line: line)
        var notes = soundNotes(stream, line: line, curve: curve)
        humanize(&notes, line: line, slurs: slurs)

        var events = notes.map { note -> PerformanceEvent in
            let onset = score.tempoMap.microseconds(atPlaybackTicks: note.onsetTicks)
            let end = score.tempoMap.microseconds(
                atPlaybackTicks: min(note.onsetTicks + note.durationTicks, totalTicks)
            )
            return PerformanceEvent(
                onsetMicroseconds: max(0, onset + note.timingOffsetMicroseconds),
                durationMicroseconds: max(1, end - onset),
                midiNoteNumber: note.midiNoteNumber,
                velocity: min(127, max(1, note.velocity)),
                origin: note.origin,
                onsetTicks: note.onsetTicks,
                durationTicks: max(1, note.durationTicks),
                playbackMeasureIndex: note.playbackMeasureIndex,
                sourceMeasureIndex: note.sourceMeasureIndex
            )
        }
        events.sort()

        return PerformanceLine(
            id: line.id,
            name: line.name,
            events: events,
            pedalSpans: pedalSpans
        )
    }

    /// The line's notes laid out on the playback timeline, one entry per note
    /// per pass.
    func buildStream(_ line: ScoreLine) -> [StreamEntry] {
        let bySource = Dictionary(grouping: line.notes, by: \.sourceMeasureIndex)
        var out: [StreamEntry] = []
        for measure in score.playbackMeasures {
            for note in bySource[measure.sourceMeasureIndex] ?? [] {
                out.append(
                    StreamEntry(
                        note: note,
                        absoluteTicks: measure.startTicks
                            + min(note.startTicks, measure.durationTicks),
                        playbackMeasureIndex: measure.index,
                        sourceMeasureIndex: measure.sourceMeasureIndex
                    )
                )
            }
        }
        return out
    }

    /// Where the line is under a slur, in absolute playback ticks.
    ///
    /// Depth-counted rather than flagged, so a phrase slur with a shorter slur
    /// inside it does not end early. A repeat replays the slur, which is what
    /// the printed page says to do.
    mutating func slurSpans(_ stream: [StreamEntry], line: ScoreLine) -> [SlurSpan] {
        var spans: [SlurSpan] = []
        var depth = 0
        var start = 0

        for entry in stream {
            let before = depth
            let opened = min(entry.note.slurStartCount, 8)
            let closed = min(entry.note.slurStopCount, 8)
            if before == 0, opened > 0 { start = entry.absoluteTicks }
            depth = max(0, before + opened - closed)
            if before + opened > 0, depth == 0 {
                spans.append(
                    SlurSpan(
                        startTicks: start,
                        endTicks: entry.absoluteTicks + entry.note.durationTicks
                    )
                )
            }
        }

        if depth > 0 {
            spans.append(SlurSpan(startTicks: start, endTicks: totalTicks))
            report.record(
                .structuralFallback,
                kind: "slur with no end",
                at: ScoreLocation(partID: line.partID, partName: line.partName),
                detail: "it is played to the end of the line"
            )
        }
        return spans
    }

    // MARK: Sounding notes

    /// Turns the stream into sounding notes: ties merged, ornaments expanded,
    /// grace notes placed, lengths and loudness shaped.
    mutating func soundNotes(
        _ stream: [StreamEntry],
        line: ScoreLine,
        curve: DynamicCurve
    ) -> [RealizedNote] {
        // Slur depth is a running total over the whole line, so it is walked
        // once here rather than recomputed per note.
        var depths: [Bool] = []
        depths.reserveCapacity(stream.count)
        var depth = 0
        for entry in stream {
            depth = max(
                0,
                depth + min(entry.note.slurStartCount, 8) - min(entry.note.slurStopCount, 8)
            )
            depths.append(depth > 0)
        }

        // The next *distinct* onset in the line, including rests: a slurred
        // note runs into what comes next, and a rest is exactly the thing that
        // stops it. Distinct matters for chords — the members of one chord all
        // run into the note after the chord, not into each other.
        var nextOnset = [Int](repeating: totalTicks, count: stream.count)
        var upcoming = totalTicks
        var index = stream.count - 1
        while index >= 0 {
            let tick = stream[index].absoluteTicks
            var start = index
            while start > 0, stream[start - 1].absoluteTicks == tick { start -= 1 }
            for position in start...index { nextOnset[position] = upcoming }
            upcoming = tick
            index = start - 1
        }

        var out: [RealizedNote] = []
        out.reserveCapacity(stream.count)

        var openTies: [Int: OpenTie] = [:]
        var ordinal = 0

        for (index, entry) in stream.enumerated() {
            let note = entry.note
            guard let pitch = note.pitch, let midi = pitch.midiNoteNumber else { continue }

            let location = ScoreLocation(
                partID: line.partID,
                partName: line.partName,
                sourceMeasureIndex: entry.sourceMeasureIndex,
                measureNumber: score.sourceMeasures[entry.sourceMeasureIndex].number
            )

            // A tie is one sounding note written twice. Extend the note
            // already sounding rather than re-attacking it.
            //
            // The chain is matched on its *notated* end, never on the length
            // it is currently sounding: the head has already been shortened to
            // its détaché reading, so comparing the sounding end would miss
            // every ordinary tie.
            if note.tiesBackward, var tie = openTies[midi],
               tie.notatedEndTicks == entry.absoluteTicks {
                tie.notatedTicks += note.durationTicks
                tie.notatedEndTicks = entry.absoluteTicks + note.durationTicks
                out[tie.index].durationTicks = shapedDuration(
                    notated: tie.notatedTicks,
                    shortening: tie.shortening,
                    slurredToNext: depths[index],
                    nextOnsetTicks: nextOnset[index],
                    onsetTicks: out[tie.index].onsetTicks
                )
                if note.tiesForward {
                    openTies[midi] = tie
                } else {
                    openTies.removeValue(forKey: midi)
                }
                continue
            }

            let shaping = ArticulationShaping.combined(note.articulations)
            // Read at a tick rather than once per note: an ornament's notes
            // are spread across the principal's span, and inside a hairpin
            // they have to swell with it. Taking one reading at the principal's
            // onset would flatten a trill into thirteen notes at one loudness.
            //
            // The articulation is added *after* any attached dynamic, not
            // before: a note marked `f` with an accent on it is a loud note
            // that is also accented, and folding the articulation in first
            // would let the level overwrite it.
            func velocity(atTicks tick: Int) -> Int {
                var result = curve.velocity(atTicks: tick) + curve.accent(atTicks: tick)
                for dynamic in note.dynamics {
                    if let level = dynamic.sustainedLevel { result = level }
                    result += dynamic.momentaryBoost
                }
                return result + shaping.velocity
            }
            let principalVelocity = velocity(atTicks: entry.absoluteTicks)

            var onset = entry.absoluteTicks
            var duration = shapedDuration(
                notated: note.durationTicks,
                shortening: shaping.percent,
                slurredToNext: depths[index],
                nextOnsetTicks: nextOnset[index],
                onsetTicks: entry.absoluteTicks
            )

            // Grace notes take their time from the principal, so they are
            // placed before it is shaped into events.
            if !note.graceNotes.isEmpty {
                let placement = placeGraceNotes(
                    note.graceNotes,
                    principalOnset: onset,
                    principalDuration: duration,
                    notatedDuration: note.durationTicks,
                    velocity: principalVelocity,
                    entry: entry,
                    ordinal: &ordinal
                )
                out.append(contentsOf: placement.notes)
                onset = placement.principalOnset
                duration = placement.principalDuration
            }

            if let ornament = note.ornaments.first {
                if note.ornaments.count > 1 {
                    report.record(
                        .notHonored,
                        kind: "second ornament on one note",
                        at: location,
                        detail: "only the first ornament printed on a note is realised"
                    )
                }
                let figure = realizeOrnament(
                    ornament,
                    principal: pitch,
                    midiNoteNumber: midi,
                    totalTicks: duration,
                    keyFifths: score.sourceMeasures[entry.sourceMeasureIndex].keyFifths ?? 0,
                    at: location
                )
                if !figure.isEmpty {
                    for step in figure {
                        ordinal += 1
                        out.append(
                            RealizedNote(
                                onsetTicks: onset + step.offsetTicks,
                                durationTicks: step.durationTicks,
                                midiNoteNumber: step.midiNoteNumber,
                                velocity: velocity(atTicks: onset + step.offsetTicks),
                                origin: .ornament,
                                playbackMeasureIndex: entry.playbackMeasureIndex,
                                sourceMeasureIndex: entry.sourceMeasureIndex,
                                ordinal: ordinal
                            )
                        )
                    }
                    // An ornamented note is consumed by its figure, so a tie
                    // out of it has nothing plain left to extend.
                    continue
                }
            }

            ordinal += 1
            out.append(
                RealizedNote(
                    onsetTicks: onset,
                    durationTicks: max(1, duration),
                    midiNoteNumber: midi,
                    velocity: velocity(atTicks: onset),
                    origin: .notated,
                    playbackMeasureIndex: entry.playbackMeasureIndex,
                    sourceMeasureIndex: entry.sourceMeasureIndex,
                    ordinal: ordinal
                )
            )
            if note.tiesForward {
                openTies[midi] = OpenTie(
                    index: out.count - 1,
                    shortening: shaping.percent,
                    notatedTicks: note.durationTicks,
                    notatedEndTicks: entry.absoluteTicks + note.durationTicks
                )
            }
        }
        return out
    }

    /// A tie chain still waiting for its continuation.
    struct OpenTie {
        /// Position in the output of the note the chain is sounding as.
        let index: Int

        /// The shortening the head note's articulation asked for, kept so the
        /// whole chain is released the way its first note was marked.
        let shortening: Int?

        /// Notated length of the chain so far.
        var notatedTicks: Int

        /// Where the chain's notation currently ends, which is what the next
        /// tied note has to start at.
        var notatedEndTicks: Int
    }

    /// How long a note actually sounds.
    func shapedDuration(
        notated: Int,
        shortening: Int?,
        slurredToNext: Bool,
        nextOnsetTicks: Int,
        onsetTicks: Int
    ) -> Int {
        guard notated > 0 else { return 0 }
        if let percent = shortening {
            // An articulation that shortens wins over the slur: staccato
            // under a slur is portato, not legato.
            return max(1, notated * percent / 100)
        }
        if slurredToNext {
            // Legato: hold into the next note and overlap it slightly, so the
            // engine has something to bind rather than a gap to disguise.
            let overlap = max(1, ticksPerQuarter / 32)
            let gap = max(notated, nextOnsetTicks - onsetTicks)
            return max(1, gap + overlap)
        }
        return max(1, notated * PerformanceRealizer.detachedPercent / 100)
    }
}
