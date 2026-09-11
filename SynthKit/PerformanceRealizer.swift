import Foundation

/// Turns a compiled score into the performance event timeline the engine
/// plays (REQ-011, REQ-012).
///
/// **Purity is the contract, exactly as it is for `ScoreCompiler`.** `realize`
/// reads no clock, draws nothing by chance, consults no environment and holds
/// no state between calls: the timeline is a function of the compiled score
/// and the settings alone. `PerformanceTimelinePurityTests` enforces that by
/// freezing canonical digests a fresh process must reproduce and by scanning
/// these sources for the APIs that would break it.
///
/// Two consequences the rest of the product is built on:
///
/// - humanization can be "on by default" without playback ever surprising the
///   owner, because the variation is a seeded function of the configuration
///   rather than something drawn afresh each time (AD5, REQ-012); and
/// - the offline export (REQ-026) renders the very value live playback used,
///   so export-equals-live is structural instead of a QA hope.
///
/// What this stage does *not* do is interpret freely. Rubato, period-
/// performance conventions and phrase-by-phrase editing are explicit non-goals
/// (D4). The shaping here is the literal meaning of the notation, plus a small
/// bounded amount of human unevenness (`PerformanceHumanization`), plus — when
/// the owner leaves the expression setting on — a deterministic reading of the
/// phrase structure the notation already states: an arch across each phrase, a
/// breath between phrases (`PerformancePhrasing`, REQ-003) and a little room
/// above the accompaniment for whichever line is leading the passage
/// (`PerformanceBalance`, REQ-003). Every one of those is derived from the
/// compiled score and the settings, so all of them stay inside the purity
/// contract above, and the three the setting owns have an off state that skips
/// their code path entirely (REQ-004).
///
/// The articulation reading — legato under a slur, détaché otherwise, a written
/// articulation winning over both (`Realization.shapedLength`) — is in the first
/// group rather than the third. It is what the page says, so it is on in every
/// state and is not scaled by the expression amount; REQ-004's bypass keeps the
/// written notation and suppresses only the interpretation laid over it.
public struct PerformanceRealizer: Sendable {
    /// Velocity used before the score says anything about loudness. `mf` is
    /// what a player defaults to and what every notation program assumes.
    public static let defaultVelocity = 80

    /// How far past a hairpin's end a printed dynamic may sit and still be
    /// read as that hairpin's target: one whole note. Engravers habitually
    /// place the target a beat or two late, and a wider window would let a
    /// dynamic in the next phrase reach back and change this one.
    public static let hairpinTargetWindowQuarters = 4

    /// Fraction of a notated value a plain, unmarked note actually sounds, so
    /// two repeated notes re-attack instead of fusing. A player's default
    /// détaché, not an articulation.
    ///
    /// Read on the tick grid and then corrected through the tempo map
    /// (`Realization.gridResidualMicroseconds`), for the reason
    /// `legatoOverlapMicroseconds` gives below: on the grid alone the ten
    /// percent floored to nothing at coarse division settings and the note
    /// kept its full value (#80).
    public static let detachedPercent = 90

    /// How far a slurred note is carried past the onset it runs into, in
    /// microseconds, so the engine has an overlap to bind rather than a gap to
    /// disguise.
    ///
    /// **In microseconds, and that is the point.** The overlap used to be
    /// `ticksPerQuarter / 32`, and `ticksPerQuarter` is the least common
    /// multiple of the `<divisions>` values the *engraver* happened to write
    /// (`ScoreCompiler.resolveTicksPerQuarter`) — not a normalized grid. A
    /// score at 480 divisions got the intended thirty-second of a quarter; the
    /// same music at 4 divisions got a whole sixteenth note, and at 1 division
    /// a whole quarter note, because the expression floors to zero and then
    /// `max(1, …)` promotes it to one tick of whatever size that score uses.
    /// Twenty milliseconds is the same gesture at every division setting, and
    /// it is the same reasoning `RealizedNote.breathShorteningMicroseconds`
    /// already states for the release side.
    public static let legatoOverlapMicroseconds: Int64 = 20_000

    /// …and never more than this fraction of the note's own sounding span, as
    /// a reciprocal: an eighth of it. A slurred thirty-second in a fast figure
    /// overlaps proportionally less, so the gesture scales with the music
    /// rather than swallowing the note it runs into.
    public static let legatoOverlapSpanDivisor: Int64 = 8

    public init() {}

    /// Realizes `score` under `settings`.
    public func realize(
        _ score: CompiledScore,
        settings: RealizationSettings = .standard
    ) -> PerformanceTimeline {
        var realization = Realization(score: score, settings: settings)
        return realization.run()
    }
}

// MARK: - Dynamics

/// The loudness a staff is playing at, over the whole playback timeline.
///
/// Stored as ramps rather than per-note values because that is what the
/// notation means: a hairpin is a continuous instruction, and a note lands
/// wherever it lands inside it. Reading a ramp at a tick is also what makes
/// the crescendo criterion checkable — the values are monotonic by
/// construction, not because the notes happened to come out that way.
struct DynamicCurve: Equatable {
    struct Segment: Equatable {
        let startTicks: Int
        let endTicks: Int
        let startVelocity: Int
        let endVelocity: Int
    }

    let segments: [Segment]

    /// One-off boosts from `sf`, `fp` and friends, by playback tick.
    let accents: [Int: Int]

    /// Velocity in force at `ticks`.
    func velocity(atTicks ticks: Int) -> Int {
        guard let first = segments.first else { return PerformanceRealizer.defaultVelocity }
        if ticks <= first.startTicks { return first.startVelocity }
        guard let last = segments.last else { return first.startVelocity }
        if ticks >= last.endTicks { return last.endVelocity }

        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].startTicks <= ticks { low = middle } else { high = middle - 1 }
        }
        let segment = segments[low]
        let span = segment.endTicks - segment.startTicks
        guard span > 0 else { return segment.startVelocity }

        // Integer interpolation, and deliberately truncating: a crescendo's
        // values then rise without ever stepping back, which is exactly the
        // monotonicity the acceptance criterion asks for.
        let delta = segment.endVelocity - segment.startVelocity
        return segment.startVelocity + delta * (ticks - segment.startTicks) / span
    }

    /// The one-off boost at `ticks`, or 0.
    func accent(atTicks ticks: Int) -> Int { accents[ticks] ?? 0 }
}

// MARK: - One realization

/// The working state of a single `realize` call. Created and discarded per
/// call, so nothing can leak between realizations.
///
/// Split over files by problem: this one builds the staff-wide context (dynamics
/// and pedal), `PerformanceLineRealization.swift` turns one line's notes into
/// events, `PerformanceHumanization.swift` adds the seeded unevenness,
/// `PerformancePhrasing.swift` reads phrases out of the score, and
/// `PerformanceBalance.swift` decides which line leads each passage. They are one
/// type because each needs this one's report collector, seed and tempo map, and
/// separate files because one would be several thousand lines about five
/// different problems.
struct Realization {
    let score: CompiledScore
    let settings: RealizationSettings

    var report = NotationReportCollector()
    let seed: SeededJitter.Seed
    let seedHex: String

    /// Expression events by source measure, so building a staff's track does
    /// not rescan the whole list once per playback measure.
    let expressionBySourceMeasure: [Int: [ScoreExpressionEvent]]

    init(score: CompiledScore, settings: RealizationSettings) {
        self.score = score
        self.settings = settings
        self.seed = SeededJitter.seed(
            pieceID: score.pieceID,
            contentSHA256: score.contentSHA256,
            settings: settings
        )
        self.seedHex = SeededJitter.seedHex(
            pieceID: score.pieceID,
            contentSHA256: score.contentSHA256,
            settings: settings
        )
        self.expressionBySourceMeasure = Dictionary(
            grouping: score.expressionEvents,
            by: \.sourceMeasureIndex
        )
    }

    var ticksPerQuarter: Int { score.ticksPerQuarter }
    var totalTicks: Int { score.totalTicks }

    mutating func run() -> PerformanceTimeline {
        // One curve and one pedal track per staff, shared by every voice on
        // it: a dynamic under the treble staff governs both of a pianist's
        // right-hand voices, and the pedal governs the whole instrument.
        var curves: [StaffKey: DynamicCurve] = [:]
        var pedals: [StaffKey: [PerformancePedalSpan]] = [:]
        for key in staffKeys() {
            let events = staffEvents(key)
            curves[key] = buildCurve(events, at: location(of: key))
            pedals[key] = buildPedalSpans(events, at: location(of: key))
        }

        // Every line's playback stream, built once. Lines are realized
        // independently, but the balance between them is the one reading that
        // has to see them together — which is why this is built here and then
        // handed down as a value rather than reached for from inside a line.
        let streams = score.lines.map { buildStream($0) }
        let balances = passageBalance(streams: streams)

        var lines: [PerformanceLine] = []
        lines.reserveCapacity(score.lines.count)
        for (index, line) in score.lines.enumerated() {
            let key = StaffKey(partID: line.partID, staff: line.staff)
            lines.append(
                realize(
                    line: line,
                    stream: streams[index],
                    curve: curves[key] ?? DynamicCurve(segments: [], accents: [:]),
                    pedalSpans: pedals[key] ?? [],
                    balance: balances[index]
                )
            )
        }

        return PerformanceTimeline(
            pieceID: score.pieceID,
            contentSHA256: score.contentSHA256,
            ticksPerQuarter: ticksPerQuarter,
            settings: settings,
            seed: seedHex,
            totalMicroseconds: score.totalMicroseconds,
            totalTicks: totalTicks,
            lines: lines,
            report: report.finish()
        )
    }

    // MARK: Staff tracks

    struct StaffKey: Hashable, Comparable {
        let partID: String
        let staff: Int

        static func < (lhs: StaffKey, rhs: StaffKey) -> Bool {
            lhs.partID == rhs.partID ? lhs.staff < rhs.staff : lhs.partID < rhs.partID
        }
    }

    /// Every staff that actually carries a line, in a canonical order.
    func staffKeys() -> [StaffKey] {
        var seen: Set<StaffKey> = []
        var ordered: [StaffKey] = []
        for line in score.lines {
            let key = StaffKey(partID: line.partID, staff: line.staff)
            if seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered.sorted()
    }

    func location(of key: StaffKey) -> ScoreLocation {
        let line = score.lines.first { $0.partID == key.partID && $0.staff == key.staff }
        return ScoreLocation(partID: key.partID, partName: line?.partName)
    }

    /// One staff's expression events on the playback timeline, in canonical
    /// order.
    ///
    /// Directions live on source measures, so a repeated section brings its
    /// dynamics and hairpins back every time it is played — which is what a
    /// player does with the printed page in front of them.
    func staffEvents(_ key: StaffKey) -> [(ticks: Int, event: ScoreExpressionEvent)] {
        var out: [(ticks: Int, event: ScoreExpressionEvent)] = []
        for measure in score.playbackMeasures {
            for event in expressionBySourceMeasure[measure.sourceMeasureIndex] ?? []
            where event.governs(partID: key.partID, staff: key.staff) {
                out.append(
                    (measure.startTicks + min(event.startTicks, measure.durationTicks), event)
                )
            }
        }
        out.sort { left, right in
            left.ticks == right.ticks ? left.event < right.event : left.ticks < right.ticks
        }
        return out
    }

    // MARK: Dynamics

    mutating func buildCurve(
        _ events: [(ticks: Int, event: ScoreExpressionEvent)],
        at location: ScoreLocation
    ) -> DynamicCurve {
        var segments: [DynamicCurve.Segment] = []
        var accents: [Int: Int] = [:]
        var current = PerformanceRealizer.defaultVelocity
        var lastTicks = 0
        var openWedge: (type: ScoreWedgeType, ticks: Int, velocity: Int)?

        // A hairpin whose target dynamic sits exactly on its stop is closed by
        // that dynamic; the stop then has nothing left to do and must not be
        // reported as unmatched.
        var closedByDynamicAt: Int?

        func flatten(to ticks: Int) {
            guard ticks > lastTicks else { return }
            segments.append(
                DynamicCurve.Segment(
                    startTicks: lastTicks,
                    endTicks: ticks,
                    startVelocity: current,
                    endVelocity: current
                )
            )
            lastTicks = ticks
        }

        for (index, entry) in events.enumerated() {
            let ticks = entry.ticks
            switch entry.event.kind {
            case .dynamic:
                guard let dynamic = entry.event.dynamic else { continue }
                if dynamic.momentaryBoost > 0 {
                    accents[ticks] = max(accents[ticks] ?? 0, dynamic.momentaryBoost)
                }
                guard let level = dynamic.sustainedLevel else { continue }
                if let wedge = openWedge {
                    segments.append(
                        DynamicCurve.Segment(
                            startTicks: wedge.ticks,
                            endTicks: max(wedge.ticks, ticks),
                            startVelocity: wedge.velocity,
                            endVelocity: level
                        )
                    )
                    openWedge = nil
                    closedByDynamicAt = ticks
                    lastTicks = max(lastTicks, ticks)
                } else {
                    flatten(to: ticks)
                }
                current = level

            case .wedgeStart:
                if let wedge = openWedge {
                    // Conservative rule for overlapping hairpins: the first
                    // one ends where the second begins, keeping whatever it
                    // had reached. Guessing at a combined shape would invent
                    // a reading the score does not state.
                    segments.append(
                        DynamicCurve.Segment(
                            startTicks: wedge.ticks,
                            endTicks: max(wedge.ticks, ticks),
                            startVelocity: wedge.velocity,
                            endVelocity: current
                        )
                    )
                    lastTicks = max(lastTicks, ticks)
                    report.record(
                        .structuralFallback,
                        kind: "overlapping hairpins",
                        at: location,
                        detail: "a hairpin starts before the previous one ends; the first one "
                            + "ends where the second begins"
                    )
                } else {
                    flatten(to: ticks)
                }
                openWedge = (entry.event.wedge ?? .crescendo, ticks, current)

            case .wedgeStop:
                guard let wedge = openWedge else {
                    if closedByDynamicAt != ticks {
                        report.record(
                            .structuralFallback,
                            kind: "hairpin end with no start",
                            at: location,
                            detail: "the loudness before it is held instead"
                        )
                    }
                    continue
                }
                let target = targetVelocity(
                    after: index,
                    ticks: ticks,
                    events: events,
                    wedge: wedge.type,
                    from: wedge.velocity
                )
                segments.append(
                    DynamicCurve.Segment(
                        startTicks: wedge.ticks,
                        endTicks: max(wedge.ticks, ticks),
                        startVelocity: wedge.velocity,
                        endVelocity: target
                    )
                )
                openWedge = nil
                current = target
                lastTicks = max(lastTicks, ticks)

            case .pedalDown, .pedalUp, .pedalChange:
                continue
            }
        }

        if let wedge = openWedge {
            let target = Self.steppedVelocity(from: wedge.velocity, wedge: wedge.type)
            segments.append(
                DynamicCurve.Segment(
                    startTicks: wedge.ticks,
                    endTicks: max(wedge.ticks, totalTicks),
                    startVelocity: wedge.velocity,
                    endVelocity: target
                )
            )
            lastTicks = max(lastTicks, totalTicks)
            current = target
            report.record(
                .structuralFallback,
                kind: "hairpin with no end",
                at: location,
                detail: "it runs to the end of the piece"
            )
        }
        flatten(to: totalTicks)

        if segments.isEmpty {
            segments = [
                DynamicCurve.Segment(
                    startTicks: 0,
                    endTicks: max(1, totalTicks),
                    startVelocity: current,
                    endVelocity: current
                )
            ]
        }
        return DynamicCurve(segments: segments, accents: accents)
    }

    /// Where a hairpin is heading.
    ///
    /// The printed dynamic just after the hairpin is its target when there is
    /// one, because that is how the notation is read. With nothing printed,
    /// one rung along the dynamic ladder is the conservative default — audible
    /// without inventing a big swell the engraver never asked for.
    func targetVelocity(
        after index: Int,
        ticks: Int,
        events: [(ticks: Int, event: ScoreExpressionEvent)],
        wedge: ScoreWedgeType,
        from velocity: Int
    ) -> Int {
        let window = ticks + ticksPerQuarter * PerformanceRealizer.hairpinTargetWindowQuarters
        var scan = index + 1
        while scan < events.count, events[scan].ticks <= window {
            if events[scan].event.kind == .dynamic,
               let level = events[scan].event.dynamic?.sustainedLevel {
                return level
            }
            scan += 1
        }
        return Self.steppedVelocity(from: velocity, wedge: wedge)
    }

    /// One rung louder or softer than `velocity` on the dynamic ladder.
    static func steppedVelocity(from velocity: Int, wedge: ScoreWedgeType) -> Int {
        let ladder = ScoreDynamic.ladder.compactMap(\.sustainedLevel)
        guard !ladder.isEmpty else { return velocity }

        var nearest = 0
        for (index, level) in ladder.enumerated()
        where abs(level - velocity) < abs(ladder[nearest] - velocity) {
            nearest = index
        }
        let stepped = wedge == .crescendo ? nearest + 1 : nearest - 1
        return ladder[min(ladder.count - 1, max(0, stepped))]
    }

    // MARK: Pedal

    mutating func buildPedalSpans(
        _ events: [(ticks: Int, event: ScoreExpressionEvent)],
        at location: ScoreLocation
    ) -> [PerformancePedalSpan] {
        var spans: [(start: Int, end: Int)] = []
        var down: Int?

        for entry in events {
            switch entry.event.kind {
            case .pedalDown:
                if down == nil { down = entry.ticks }

            case .pedalUp:
                if let start = down, entry.ticks > start { spans.append((start, entry.ticks)) }
                down = nil

            case .pedalChange:
                // A lift and an immediate re-press: two spans, no gap the ear
                // can hear but a clean break for the renderer.
                if let start = down, entry.ticks > start { spans.append((start, entry.ticks)) }
                down = entry.ticks

            default:
                continue
            }
        }

        if let start = down, totalTicks > start {
            spans.append((start, totalTicks))
            report.record(
                .structuralFallback,
                kind: "pedal never released",
                at: location,
                detail: "it is held to the end of the piece"
            )
        }

        return spans
            .map {
                PerformancePedalSpan(
                    startMicroseconds: score.tempoMap.microseconds(atPlaybackTicks: $0.start),
                    endMicroseconds: score.tempoMap.microseconds(atPlaybackTicks: $0.end),
                    startTicks: $0.start,
                    endTicks: $0.end
                )
            }
            .sorted()
    }
}
