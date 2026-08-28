import Foundation

// MARK: - Events

/// Why an event is in the timeline.
///
/// The engine treats all four the same, but a piano roll, a diagnostic dump,
/// or a reviewer asking "did the trill actually expand?" needs to tell a
/// written note from one this stage invented.
public enum PerformanceEventOrigin: String, Equatable, Sendable, Codable, CaseIterable, Comparable {
    /// A note the score writes, sounding where the score writes it.
    case notated

    /// One note of a realized ornament figure.
    case ornament

    /// A grace note printed before its principal.
    case grace

    public static func < (lhs: PerformanceEventOrigin, rhs: PerformanceEventOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One note the engine has to sound.
///
/// **Integers everywhere, on purpose.** REQ-012 asks for two realizations to
/// be identical and REQ-026 asks an export to equal live playback; both are
/// checked as byte equality of `PerformanceTimeline.canonicalData()`, and no
/// value that can be a signalling NaN or a last-bit rounding difference can
/// carry that claim. Microseconds and MIDI velocity are exact, so the contract
/// is stated in them and the engine converts to samples and gain itself.
public struct PerformanceEvent: Equatable, Sendable, Codable, Comparable {
    /// When the note sounds, from the start of playback. This is the humanized
    /// time: it is what the engine schedules.
    public let onsetMicroseconds: Int64

    /// How long it sounds. Already shaped by articulation, slur and ornament
    /// division, so the engine does not reinterpret anything.
    public let durationMicroseconds: Int64

    /// Standard MIDI note number, middle C = 60.
    public let midiNoteNumber: Int

    /// Loudness, 1…127. This is the single loudness parameter the crescendo
    /// criterion is measured on; the engine maps it to gain.
    public let velocity: Int

    public let origin: PerformanceEventOrigin

    /// The *notated* playback tick this event belongs to, before any
    /// humanization. Score-following and the transport read this, so a
    /// humanized performance still highlights the right note.
    public let onsetTicks: Int

    /// The event's length on the tick grid, after shaping.
    ///
    /// Carried alongside the microsecond length so the timeline can be read
    /// without the compiled score's tempo map beside it — a piano roll wants
    /// notated length, the engine wants time, and neither should have to
    /// reconstruct the other.
    public let durationTicks: Int

    /// Index into `CompiledScore.playbackMeasures`.
    public let playbackMeasureIndex: Int

    /// Index into `CompiledScore.sourceMeasures`.
    public let sourceMeasureIndex: Int

    public init(
        onsetMicroseconds: Int64,
        durationMicroseconds: Int64,
        midiNoteNumber: Int,
        velocity: Int,
        origin: PerformanceEventOrigin,
        onsetTicks: Int,
        durationTicks: Int,
        playbackMeasureIndex: Int,
        sourceMeasureIndex: Int
    ) {
        self.onsetMicroseconds = onsetMicroseconds
        self.durationMicroseconds = durationMicroseconds
        self.midiNoteNumber = midiNoteNumber
        self.velocity = velocity
        self.origin = origin
        self.onsetTicks = onsetTicks
        self.durationTicks = durationTicks
        self.playbackMeasureIndex = playbackMeasureIndex
        self.sourceMeasureIndex = sourceMeasureIndex
    }

    public var endMicroseconds: Int64 { onsetMicroseconds + durationMicroseconds }

    /// The notated tick this event stops sounding at.
    public var endTicks: Int { onsetTicks + durationTicks }

    /// Time order, with every remaining field as a tiebreak so the order is
    /// total. Two events at one instant must not be able to swap places
    /// between runs, which a partial comparator would allow.
    public static func < (lhs: PerformanceEvent, rhs: PerformanceEvent) -> Bool {
        if lhs.onsetMicroseconds != rhs.onsetMicroseconds {
            return lhs.onsetMicroseconds < rhs.onsetMicroseconds
        }
        if lhs.onsetTicks != rhs.onsetTicks { return lhs.onsetTicks < rhs.onsetTicks }
        if lhs.midiNoteNumber != rhs.midiNoteNumber { return lhs.midiNoteNumber < rhs.midiNoteNumber }
        if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
        if lhs.durationMicroseconds != rhs.durationMicroseconds {
            return lhs.durationMicroseconds < rhs.durationMicroseconds
        }
        if lhs.velocity != rhs.velocity { return lhs.velocity < rhs.velocity }
        if lhs.durationTicks != rhs.durationTicks { return lhs.durationTicks < rhs.durationTicks }
        if lhs.playbackMeasureIndex != rhs.playbackMeasureIndex {
            return lhs.playbackMeasureIndex < rhs.playbackMeasureIndex
        }
        return lhs.sourceMeasureIndex < rhs.sourceMeasureIndex
    }
}

/// One stretch with the sustain pedal down.
///
/// A span rather than two events because that is what a renderer needs to ask:
/// "is the pedal down at time t?". `<pedal type="change">` becomes two
/// adjacent spans, which is exactly what the notation means — a lift and an
/// immediate re-press.
public struct PerformancePedalSpan: Equatable, Sendable, Codable, Comparable {
    public let startMicroseconds: Int64
    public let endMicroseconds: Int64
    public let startTicks: Int
    public let endTicks: Int

    public init(
        startMicroseconds: Int64,
        endMicroseconds: Int64,
        startTicks: Int,
        endTicks: Int
    ) {
        self.startMicroseconds = startMicroseconds
        self.endMicroseconds = endMicroseconds
        self.startTicks = startTicks
        self.endTicks = endTicks
    }

    public func contains(microseconds: Int64) -> Bool {
        microseconds >= startMicroseconds && microseconds < endMicroseconds
    }

    public static func < (lhs: PerformancePedalSpan, rhs: PerformancePedalSpan) -> Bool {
        if lhs.startMicroseconds != rhs.startMicroseconds {
            return lhs.startMicroseconds < rhs.startMicroseconds
        }
        if lhs.endMicroseconds != rhs.endMicroseconds {
            return lhs.endMicroseconds < rhs.endMicroseconds
        }
        if lhs.startTicks != rhs.startTicks { return lhs.startTicks < rhs.startTicks }
        return lhs.endTicks < rhs.endTicks
    }
}

// MARK: - Lines

/// One line's finished performance.
public struct PerformanceLine: Equatable, Sendable, Codable {
    /// The same identifier the compiled score gave the line, so a preset
    /// assignment made in increment 004 lands on the right stream.
    public let id: ScoreLineID

    /// The line's default display name, copied so a renderer does not have to
    /// keep the compiled score alive to label a stream.
    public let name: String

    /// Notes in time order.
    public let events: [PerformanceEvent]

    /// Sustain-pedal spans in force for this line, in time order.
    public let pedalSpans: [PerformancePedalSpan]

    public init(
        id: ScoreLineID,
        name: String,
        events: [PerformanceEvent],
        pedalSpans: [PerformancePedalSpan]
    ) {
        self.id = id
        self.name = name
        self.events = events
        self.pedalSpans = pedalSpans
    }

    /// Every event sounding at `microseconds`.
    public func events(atMicroseconds microseconds: Int64) -> [PerformanceEvent] {
        events.filter { $0.onsetMicroseconds <= microseconds && microseconds < $0.endMicroseconds }
    }
}

// MARK: - Timeline

/// The performance event timeline: **the contract this leaf owns.**
///
/// Three consumers depend on this exact shape, and each depends on a different
/// property of it:
///
/// - the audio engine (#15) schedules `PerformanceEvent`s and reads
///   `pedalSpans`; it needs the times to be absolute and integral;
/// - the transport and humanization controls (#16) re-realize with different
///   `RealizationSettings` and expect only the interpretation to move, never
///   the line identities; and
/// - the offline export (increment 006) renders the same value the engine
///   played, which is why `canonicalData()` exists at all — export equality
///   (REQ-026) is checked as byte equality here rather than by comparing
///   audio.
///
/// The whole value is a pure function of `(CompiledScore, RealizationSettings)`.
/// Build it twice from the same pair, in any order, on any machine, and the
/// bytes match.
public struct PerformanceTimeline: Equatable, Sendable, Codable {
    /// Library identity of the piece this realizes.
    public let pieceID: String

    /// SHA-256 of the MusicXML the compiled score came from. Pins the timeline
    /// to its source the same way `CompiledScore` does.
    public let contentSHA256: String

    /// Tick resolution, matching the compiled score.
    public let ticksPerQuarter: Int

    /// The settings this was realized under.
    public let settings: RealizationSettings

    /// SHA-256 of the exact configuration the humanization noise is keyed by.
    /// Two timelines with the same digest were interpreted the same way.
    public let seed: String

    /// Length of the piece in microseconds, from the compiled tempo map. Note
    /// that a final note may ring past it.
    public let totalMicroseconds: Int64

    /// Length of the piece in playback ticks.
    public let totalTicks: Int

    /// One entry per compiled line, in the compiled score's order.
    public let lines: [PerformanceLine]

    /// What this stage could not realize, on top of what compilation already
    /// reported. Compilation reports notation it cannot even read; this
    /// reports notation it read and then could not sound.
    public let report: NotationReport

    public init(
        pieceID: String,
        contentSHA256: String,
        ticksPerQuarter: Int,
        settings: RealizationSettings,
        seed: String,
        totalMicroseconds: Int64,
        totalTicks: Int,
        lines: [PerformanceLine],
        report: NotationReport
    ) {
        self.pieceID = pieceID
        self.contentSHA256 = contentSHA256
        self.ticksPerQuarter = ticksPerQuarter
        self.settings = settings
        self.seed = seed
        self.totalMicroseconds = totalMicroseconds
        self.totalTicks = totalTicks
        self.lines = lines
        self.report = report
    }

    /// Every event across every line, in time order.
    public var eventCount: Int { lines.reduce(0) { $0 + $1.events.count } }

    /// The line with this identifier, or nil.
    public func line(withID id: ScoreLineID) -> PerformanceLine? {
        lines.first { $0.id == id }
    }

    /// The canonical byte form of this timeline.
    ///
    /// Sorted keys, no floating-point anywhere in the value, and a total order
    /// on every list. Two realizations of one configuration produce identical
    /// bytes, which is how REQ-012 is checked rather than asserted.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
