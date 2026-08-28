import Foundation

/// Ticks-to-time over the playback timeline.
///
/// Tempo is stored the way MIDI stores it — **microseconds per quarter note,
/// as an integer** — rather than as beats per minute in a `Double`. Two
/// reasons, and both are load-bearing:
///
/// 1. the determinism criterion is byte equality of the compiled model, and no
///    floating-point value can be compared that way with a straight face; and
/// 2. the audio engine (PLY003) and the offline export (increment 006) must
///    produce the same sample positions, which integer arithmetic gives for
///    free.
///
/// A fermata is not a special case at playback time: it is a segment whose
/// tempo is slower by `TempoMap.fermataStretch`. Everything downstream sees
/// one uniform list of segments.
public struct TempoMap: Equatable, Sendable, Codable {
    /// One stretch of the timeline at a constant tempo.
    public struct Segment: Equatable, Sendable, Codable {
        /// Absolute playback tick where this tempo takes effect.
        public let startTicks: Int

        /// Microseconds per quarter note. 500000 is ♩=120.
        public let microsecondsPerQuarter: Int

        /// Absolute time, in microseconds, at `startTicks`.
        public let startMicroseconds: Int64

        public init(startTicks: Int, microsecondsPerQuarter: Int, startMicroseconds: Int64) {
            self.startTicks = startTicks
            self.microsecondsPerQuarter = microsecondsPerQuarter
            self.startMicroseconds = startMicroseconds
        }
    }

    /// Tick resolution, matching `CompiledScore.ticksPerQuarter`.
    public let ticksPerQuarter: Int

    /// Segments in tick order. Always non-empty and always starting at tick 0.
    public let segments: [Segment]

    /// Length of the playback timeline in ticks.
    public let totalTicks: Int

    /// Length of the playback timeline in microseconds.
    public let totalMicroseconds: Int64

    public init(
        ticksPerQuarter: Int,
        segments: [Segment],
        totalTicks: Int,
        totalMicroseconds: Int64
    ) {
        self.ticksPerQuarter = ticksPerQuarter
        self.segments = segments
        self.totalTicks = totalTicks
        self.totalMicroseconds = totalMicroseconds
    }

    /// Tempo used when a score declares none. MusicXML files very often omit
    /// tempo entirely; ♩=120 is the universal notation-software default.
    public static let defaultMicrosecondsPerQuarter = 500_000

    /// How much a fermata slows its span: 3/2, i.e. the held value lasts half
    /// again as long. A fixed ratio, not a taste setting — expressive shaping
    /// belongs to PLY002, and this leaf only has to make the hold audible and
    /// reproducible.
    public static let fermataStretchNumerator = 3
    public static let fermataStretchDenominator = 2

    /// Converts a BPM figure (`sound/@tempo`, always per quarter note) into
    /// microseconds per quarter, rounded to the nearest microsecond.
    ///
    /// Returns nil for a value that cannot make musical sense.
    public static func microsecondsPerQuarter(beatsPerMinute: Double) -> Int? {
        guard beatsPerMinute.isFinite, beatsPerMinute > 0 else { return nil }
        let value = (60_000_000.0 / beatsPerMinute).rounded()
        guard value >= 1, value <= Double(Int.max / 2) else { return nil }
        return Int(value)
    }

    /// Absolute time at `ticks`.
    public func microseconds(atPlaybackTicks ticks: Int) -> Int64 {
        let clamped = max(0, min(ticks, totalTicks))
        let segment = segments[segmentIndex(atTicks: clamped)]
        return segment.startMicroseconds
            + Self.elapsed(
                ticks: clamped - segment.startTicks,
                microsecondsPerQuarter: segment.microsecondsPerQuarter,
                ticksPerQuarter: ticksPerQuarter
            )
    }

    /// The playback tick sounding at `microseconds`.
    public func playbackTicks(atMicroseconds microseconds: Int64) -> Int {
        let clamped = max(0, min(microseconds, totalMicroseconds))

        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].startMicroseconds <= clamped {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let segment = segments[low]
        let delta = clamped - segment.startMicroseconds
        let ticks = delta * Int64(ticksPerQuarter) / Int64(segment.microsecondsPerQuarter)
        return min(totalTicks, segment.startTicks + Int(ticks))
    }

    /// Tempo in force at `ticks`, in microseconds per quarter.
    public func microsecondsPerQuarter(atPlaybackTicks ticks: Int) -> Int {
        segments[segmentIndex(atTicks: max(0, min(ticks, totalTicks)))].microsecondsPerQuarter
    }

    private func segmentIndex(atTicks ticks: Int) -> Int {
        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].startTicks <= ticks {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Elapsed microseconds over `ticks` at a constant tempo, rounded to
    /// nearest so a long piece does not drift downward segment by segment.
    static func elapsed(ticks: Int, microsecondsPerQuarter: Int, ticksPerQuarter: Int) -> Int64 {
        guard ticks > 0, ticksPerQuarter > 0 else { return 0 }
        let numerator = Int64(ticks) * Int64(microsecondsPerQuarter) + Int64(ticksPerQuarter) / 2
        return numerator / Int64(ticksPerQuarter)
    }
}

/// Builds a `TempoMap` from tempo changes and fermata holds on the playback
/// timeline.
struct TempoMapBuilder {
    /// A tempo change at an absolute playback tick.
    struct Change: Equatable {
        let startTicks: Int
        let microsecondsPerQuarter: Int
    }

    /// A held span on the playback timeline.
    struct Hold: Equatable {
        let startTicks: Int
        let endTicks: Int
    }

    let ticksPerQuarter: Int
    let totalTicks: Int

    /// Assembles the map.
    ///
    /// Order matters: tempo boundaries first, then the fermata spans are cut
    /// into those segments and slowed. Doing it the other way round would let
    /// a tempo change inside a held note quietly cancel the hold.
    func build(changes: [Change], holds: [Hold]) -> TempoMap {
        // Sorted on both fields, not just the tick. Two parts can carry the
        // same tempo mark at the same moment with different values, and the
        // last write below wins — so an unstable sort on the tick alone would
        // let the winner vary between runs and break byte determinism.
        var boundaries: [Int: Int] = [0: TempoMap.defaultMicrosecondsPerQuarter]
        let ordered = changes.sorted {
            ($0.startTicks, $0.microsecondsPerQuarter) < ($1.startTicks, $1.microsecondsPerQuarter)
        }
        for change in ordered {
            let tick = max(0, min(change.startTicks, totalTicks))
            boundaries[tick] = change.microsecondsPerQuarter
        }

        // (start, end, tempo) spans covering [0, totalTicks).
        var spans: [(start: Int, end: Int, mpq: Int)] = []
        let starts = boundaries.keys.sorted()
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : totalTicks
            guard end > start else { continue }
            spans.append((start, end, boundaries[start] ?? TempoMap.defaultMicrosecondsPerQuarter))
        }
        if spans.isEmpty {
            spans = [(0, max(0, totalTicks), TempoMap.defaultMicrosecondsPerQuarter)]
        }

        for hold in Self.merged(holds: holds, totalTicks: totalTicks) {
            spans = Self.stretch(spans, over: hold)
        }

        // Fuse neighbours at the same tempo *before* timing them, so one
        // segment is always exactly one span. Otherwise the running total and
        // `microseconds(atPlaybackTicks:)` would round differently and the
        // map would disagree with itself by a microsecond at the seams.
        var fused: [(start: Int, end: Int, mpq: Int)] = []
        for span in spans {
            if let last = fused.last, last.mpq == span.mpq, last.end == span.start {
                fused[fused.count - 1] = (last.start, span.end, last.mpq)
            } else {
                fused.append(span)
            }
        }

        var segments: [TempoMap.Segment] = []
        var elapsed: Int64 = 0
        for span in fused {
            segments.append(
                TempoMap.Segment(
                    startTicks: span.start,
                    microsecondsPerQuarter: span.mpq,
                    startMicroseconds: elapsed
                )
            )
            elapsed += TempoMap.elapsed(
                ticks: span.end - span.start,
                microsecondsPerQuarter: span.mpq,
                ticksPerQuarter: ticksPerQuarter
            )
        }
        if segments.isEmpty {
            segments = [
                TempoMap.Segment(
                    startTicks: 0,
                    microsecondsPerQuarter: TempoMap.defaultMicrosecondsPerQuarter,
                    startMicroseconds: 0
                )
            ]
        }

        return TempoMap(
            ticksPerQuarter: ticksPerQuarter,
            segments: segments,
            totalTicks: max(0, totalTicks),
            totalMicroseconds: elapsed
        )
    }

    /// Overlapping holds become one hold: two voices with a fermata on the
    /// same chord must not slow the music twice.
    static func merged(holds: [Hold], totalTicks: Int) -> [Hold] {
        let clamped = holds
            .map { Hold(startTicks: max(0, $0.startTicks), endTicks: min($0.endTicks, totalTicks)) }
            .filter { $0.endTicks > $0.startTicks }
            .sorted { ($0.startTicks, $0.endTicks) < ($1.startTicks, $1.endTicks) }

        var merged: [Hold] = []
        for hold in clamped {
            if let last = merged.last, hold.startTicks <= last.endTicks {
                merged[merged.count - 1] = Hold(
                    startTicks: last.startTicks,
                    endTicks: max(last.endTicks, hold.endTicks)
                )
            } else {
                merged.append(hold)
            }
        }
        return merged
    }

    /// Cuts `spans` at the hold's edges and slows the parts inside it.
    static func stretch(
        _ spans: [(start: Int, end: Int, mpq: Int)],
        over hold: Hold
    ) -> [(start: Int, end: Int, mpq: Int)] {
        var out: [(start: Int, end: Int, mpq: Int)] = []
        for span in spans {
            let overlapStart = max(span.start, hold.startTicks)
            let overlapEnd = min(span.end, hold.endTicks)
            guard overlapStart < overlapEnd else {
                out.append(span)
                continue
            }
            if span.start < overlapStart {
                out.append((span.start, overlapStart, span.mpq))
            }
            let slowed = span.mpq * TempoMap.fermataStretchNumerator
                / TempoMap.fermataStretchDenominator
            out.append((overlapStart, overlapEnd, max(1, slowed)))
            if overlapEnd < span.end {
                out.append((overlapEnd, span.end, span.mpq))
            }
        }
        return out
    }
}
