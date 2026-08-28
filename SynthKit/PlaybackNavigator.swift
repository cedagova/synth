import Foundation

/// A resolved measure-range loop over the playback timeline (REQ-009).
///
/// Resolved once, when the owner sets it, rather than re-derived on every
/// transport tick: the bounds are absolute microseconds, so the hot path is one
/// integer comparison and the loop cannot drift if the piece is re-realized
/// under different humanization.
public struct LoopRange: Equatable, Sendable {
    /// First playback measure inside the loop.
    public let startPlaybackMeasureIndex: Int

    /// Last playback measure inside the loop, inclusive.
    public let endPlaybackMeasureIndex: Int

    /// Where the loop restarts, in microseconds from the start of playback.
    public let startMicroseconds: Int64

    /// Where the loop wraps, exclusive.
    public let endMicroseconds: Int64

    /// Printed number of the first measure, for display.
    public let startMeasureNumber: String

    /// Printed number of the last measure, for display.
    public let endMeasureNumber: String

    public init(
        startPlaybackMeasureIndex: Int,
        endPlaybackMeasureIndex: Int,
        startMicroseconds: Int64,
        endMicroseconds: Int64,
        startMeasureNumber: String,
        endMeasureNumber: String
    ) {
        self.startPlaybackMeasureIndex = startPlaybackMeasureIndex
        self.endPlaybackMeasureIndex = endPlaybackMeasureIndex
        self.startMicroseconds = startMicroseconds
        self.endMicroseconds = endMicroseconds
        self.startMeasureNumber = startMeasureNumber
        self.endMeasureNumber = endMeasureNumber
    }

    /// How many playback measures the loop covers.
    public var measureCount: Int { endPlaybackMeasureIndex - startPlaybackMeasureIndex + 1 }

    public var durationMicroseconds: Int64 { max(0, endMicroseconds - startMicroseconds) }

    /// Where the transport should jump when the playhead reaches `position`,
    /// or nil when it is still inside the loop.
    ///
    /// A playhead *before* the loop is deliberately left alone: seeking
    /// backwards out of a loop and letting the music run into it is how a
    /// player uses one, and yanking the playhead forward would make the loop
    /// impossible to approach.
    public func wrapTarget(forPosition position: Int64) -> Int64? {
        position >= endMicroseconds ? startMicroseconds : nil
    }

    /// True when `position` is inside the looped span.
    public func contains(_ position: Int64) -> Bool {
        position >= startMicroseconds && position < endMicroseconds
    }

    /// "measures 5–8", or "measure 5" for a one-measure loop.
    public var displayText: String {
        startMeasureNumber == endMeasureNumber
            ? "measure \(startMeasureNumber)"
            : "measures \(startMeasureNumber)–\(endMeasureNumber)"
    }
}

/// Turns what the owner can say about a position — a printed measure number, a
/// beat, an elapsed time — into the microsecond the transport seeks to, and
/// back again (REQ-009).
///
/// **A pure value over one `CompiledScore`.** The transport screen is the only
/// positional orientation the product has, because no score is drawn (D2), so
/// every one of these mappings is load-bearing and every one is unit-tested
/// here rather than inside a SwiftUI `body`.
///
/// Two things about it are easy to get subtly wrong, and both are handled once:
///
/// 1. **Printed numbers are not indices.** Real scores reuse and skip printed
///    numbers, and a repeated measure is played several times, so `12` names a
///    set of playback measures rather than one. Every lookup therefore takes a
///    starting point and finds the first playback measure at or after it.
/// 2. **Tick↔time is lossy in one direction.** `TempoMap.microseconds(at:)`
///    rounds to nearest and `playbackTicks(atMicroseconds:)` truncates, so the
///    microsecond of a measure's first tick can map back to the last tick of
///    the measure before it. Seeking to measure 12 would then display measure
///    11. `microseconds(atPlaybackMeasureIndex:beat:)` nudges forward until the
///    value round-trips, so what the owner asked for is what the readout says.
public struct PlaybackNavigator: Sendable {
    public let score: CompiledScore

    public init(score: CompiledScore) {
        self.score = score
    }

    // MARK: Bounds

    public var playbackMeasureCount: Int { score.playbackMeasures.count }

    public var totalMicroseconds: Int64 { score.totalMicroseconds }

    /// True when the score expanded to nothing playable.
    public var isEmpty: Bool { score.playbackMeasures.isEmpty }

    /// Printed number of the first playback measure, for a seek field's
    /// placeholder.
    public var firstMeasureNumber: String? {
        guard let first = score.playbackMeasures.first else { return nil }
        return score.sourceMeasures[first.sourceMeasureIndex].number
    }

    /// Printed number of the last playback measure.
    public var lastMeasureNumber: String? {
        guard let last = score.playbackMeasures.last else { return nil }
        return score.sourceMeasures[last.sourceMeasureIndex].number
    }

    // MARK: Reading a position

    public func position(atMicroseconds microseconds: Int64) -> ScorePosition? {
        score.position(atMicroseconds: microseconds)
    }

    // MARK: Finding a measure

    /// The first playback measure at or after `index` whose printed number is
    /// `number`, or nil when the rest of the piece never prints it.
    ///
    /// Matching is on the trimmed printed string, so `12` finds `12` and not
    /// `12a`; that is the same identity the report and the position readout
    /// use, so the three can never disagree about which measure is which.
    public func playbackMeasureIndex(
        forMeasureNumber number: String,
        atOrAfter index: Int = 0
    ) -> Int? {
        let wanted = number.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let start = max(0, index)
        guard start < score.playbackMeasures.count else { return nil }
        for measure in score.playbackMeasures[start...] {
            if score.sourceMeasures[measure.sourceMeasureIndex].number == wanted {
                return measure.index
            }
        }
        return nil
    }

    /// Length of one notated beat in the measure at `index`, in ticks.
    public func beatTicks(atPlaybackMeasureIndex index: Int) -> Int {
        guard score.playbackMeasures.indices.contains(index) else { return score.ticksPerQuarter }
        let source = score.sourceMeasures[score.playbackMeasures[index].sourceMeasureIndex]
        return source.timeSignature?.beatTicks(ticksPerQuarter: score.ticksPerQuarter)
            ?? score.ticksPerQuarter
    }

    // MARK: Measure and beat to time

    /// Where playback measure `index` at `beat` begins, in microseconds.
    ///
    /// `beat` is 1-based and may be fractional, matching `ScorePosition.beat`.
    /// A beat past the end of the measure is clamped inside it rather than
    /// spilling into the next one: "measure 5, beat 9" in 4/4 is a typo, and
    /// silently landing in measure 6 would be the wrong kind of helpful.
    public func microseconds(atPlaybackMeasureIndex index: Int, beat: Double = 1) -> Int64? {
        guard score.playbackMeasures.indices.contains(index) else { return nil }
        let measure = score.playbackMeasures[index]
        let ticksIntoMeasure = Self.tickOffset(
            forBeat: beat,
            beatTicks: beatTicks(atPlaybackMeasureIndex: index),
            measureDurationTicks: measure.durationTicks
        )
        return microsecondsThatRoundTrip(toPlaybackTicks: measure.startTicks + ticksIntoMeasure)
    }

    /// Where the first playback occurrence of printed measure `number` at
    /// `beat` begins.
    public func microseconds(
        forMeasureNumber number: String,
        beat: Double = 1,
        atOrAfter index: Int = 0
    ) -> Int64? {
        guard let measureIndex = playbackMeasureIndex(forMeasureNumber: number, atOrAfter: index)
        else { return nil }
        return microseconds(atPlaybackMeasureIndex: measureIndex, beat: beat)
    }

    /// Where playback measure `index` ends, in microseconds. This is the first
    /// microsecond of the next measure, so it is an exclusive bound.
    public func endMicroseconds(ofPlaybackMeasureIndex index: Int) -> Int64? {
        guard score.playbackMeasures.indices.contains(index) else { return nil }
        return score.tempoMap.microseconds(atPlaybackTicks: score.playbackMeasures[index].endTicks)
    }

    // MARK: Loops

    /// Resolves a loop over the printed measures `from`…`to`.
    ///
    /// The end measure is looked for at or after the start measure, so a loop
    /// across a repeat picks the *same* pass the owner is listening to rather
    /// than an earlier printing of the same number.
    ///
    /// Returns nil when either number is not printed in the remaining piece, or
    /// when the resolved end sits before the resolved start.
    public func loopRange(fromMeasureNumber from: String, toMeasureNumber to: String) -> LoopRange? {
        guard let startIndex = playbackMeasureIndex(forMeasureNumber: from),
              let endIndex = playbackMeasureIndex(forMeasureNumber: to, atOrAfter: startIndex),
              let startMicroseconds = microseconds(atPlaybackMeasureIndex: startIndex),
              let endMicroseconds = endMicroseconds(ofPlaybackMeasureIndex: endIndex),
              endMicroseconds > startMicroseconds
        else { return nil }

        return LoopRange(
            startPlaybackMeasureIndex: startIndex,
            endPlaybackMeasureIndex: endIndex,
            startMicroseconds: startMicroseconds,
            endMicroseconds: endMicroseconds,
            startMeasureNumber: score.sourceMeasures[
                score.playbackMeasures[startIndex].sourceMeasureIndex
            ].number,
            endMeasureNumber: score.sourceMeasures[
                score.playbackMeasures[endIndex].sourceMeasureIndex
            ].number
        )
    }

    // MARK: Helpers

    /// Ticks from the start of a measure for a 1-based, possibly fractional
    /// beat, clamped inside the measure.
    static func tickOffset(forBeat beat: Double, beatTicks: Int, measureDurationTicks: Int) -> Int {
        guard beat.isFinite else { return 0 }
        let raw = (beat - 1) * Double(max(1, beatTicks))
        guard raw.isFinite else { return 0 }
        let rounded = Int(raw.rounded())
        let last = max(0, measureDurationTicks - 1)
        return min(max(0, rounded), last)
    }

    /// The smallest microsecond value that the tempo map maps back to at least
    /// `ticks`.
    ///
    /// `TempoMap` rounds one way and truncates the other, so the exact time of
    /// a tick can read back as the tick before it. The correction is at most a
    /// couple of microseconds; the bound below is a safety net, not a search.
    private func microsecondsThatRoundTrip(toPlaybackTicks ticks: Int) -> Int64 {
        let target = max(0, min(ticks, score.tempoMap.totalTicks))
        var microseconds = score.tempoMap.microseconds(atPlaybackTicks: target)
        var attempts = 0
        while attempts < 8,
              microseconds < score.tempoMap.totalMicroseconds,
              score.tempoMap.playbackTicks(atMicroseconds: microseconds) < target {
            microseconds += 1
            attempts += 1
        }
        return microseconds
    }
}
