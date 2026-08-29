import Foundation

/// One line whose voice could not be built, so the line is producing silence
/// nobody asked for.
public struct SilentLineReport: Sendable, Equatable {
    public let lineID: ScoreLineID

    /// What the line was supposed to be playing, for the sentence the owner
    /// reads.
    public let soundName: String

    public init(lineID: ScoreLineID, soundName: String) {
        self.lineID = lineID
        self.soundName = soundName
    }

    /// The flag this becomes on the line.
    public var advice: LineInstrumentAdvice {
        .silentVoice(instrumentName: soundName, unbuiltVoiceCount: 1)
    }
}

/// Whether the program the engine is about to play is actually going to make
/// the sound it says it will.
///
/// **This closes the loop INS002 deliberately left open.** When
/// `sample_voice_create` cannot allocate, the line gets a stateless vtable that
/// renders silence and the failure is recorded — INS002 chose that over quietly
/// substituting a synth patch, because an unasked-for substitute is exactly the
/// end state issue #24 gates behind an explicit acknowledgment. But a line that
/// is silently *silent* is the same violation reached from the other side, so
/// somebody has to read the record and say so. This is that somebody.
///
/// Read from the built program on the control thread, immediately after it is
/// built: by then every voice has been through `makeVoice`, so every failure is
/// already recorded. Nothing here polls and nothing here is on the audio thread.
public enum LineRenderHealth {
    /// Every line of `program` whose voice could not be built, named from
    /// `lines`.
    ///
    /// Exact per line rather than inferred from a per-instrument count: two
    /// violin lines share one loaded instrument, so a count would flag both when
    /// only one failed. `RenderProgram` records the identities themselves, which
    /// is the only way this can be right.
    public static func silentLines(
        in program: RenderProgram, resolvedAs lines: [ResolvedLine]
    ) -> [SilentLineReport] {
        guard !program.unbuiltVoiceLineIDs.isEmpty else { return [] }
        let namesByLine = Dictionary(
            lines.map { ($0.lineID, $0.source.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        // Program order, so two runs over the same program report identically.
        return program.unbuiltVoiceLineIDs.map { lineID in
            SilentLineReport(
                lineID: lineID,
                soundName: namesByLine[lineID] ?? "This line's sound"
            )
        }
    }
}

extension PresetPerformance {
    /// This performance with every line the program could not build a voice for
    /// flagged.
    ///
    /// A copy rather than a mutation, so the flag arrives with the rest of the
    /// line's state and a view cannot see a half-updated performance.
    public func flaggingUnbuiltVoices(in program: RenderProgram) -> PresetPerformance {
        let reports = LineRenderHealth.silentLines(in: program, resolvedAs: lines)
        guard !reports.isEmpty else { return self }
        let byLine = Dictionary(
            reports.map { ($0.lineID, $0.advice) }, uniquingKeysWith: { first, _ in first }
        )
        return PresetPerformance(
            preset: preset,
            lines: lines.map { line in
                guard let advice = byLine[line.lineID] else { return line }
                return line.adding(advice: advice)
            }
        )
    }
}
