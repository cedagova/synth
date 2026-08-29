import Foundation

/// One line whose voice could not be built, so the line is producing silence.
public struct SilentLineReport: Sendable, Equatable {
    public let lineID: ScoreLineID

    /// What the line was supposed to be playing, for the sentence the owner
    /// reads.
    public let soundName: String

    /// How many voices the provider failed to build. More than one means the
    /// same sound is silent on several lines.
    public let unbuiltVoiceCount: Int

    public init(lineID: ScoreLineID, soundName: String, unbuiltVoiceCount: Int) {
        self.lineID = lineID
        self.soundName = soundName
        self.unbuiltVoiceCount = unbuiltVoiceCount
    }
}

/// Whether the program the engine is about to play is actually going to make
/// the sound it says it will.
///
/// **This closes the loop INS002 deliberately left open.** When
/// `sample_voice_create` cannot allocate, the line gets a stateless vtable that
/// renders silence and the fact is recorded on the instrument — INS002 chose
/// that over quietly substituting a synth patch, because an unasked-for
/// substitute is exactly the end state issue #24 gates behind an explicit
/// acknowledgment. But a line that is silently *silent* is the same violation
/// reached from the other side, so somebody has to read the count and say so.
/// This is that somebody.
///
/// Read immediately after the program is built, on the control thread: by the
/// time `PlaybackEngine.setVoices` has returned, every voice the program needs
/// has been through `makeVoice`, so every failure has already been recorded.
/// Nothing here polls and nothing here is on the audio thread.
public enum LineRenderHealth {
    /// Every line whose provider could not build its voice.
    ///
    /// Generic over the provider rather than special-cased to the sampler, so a
    /// later engine that can also fail to build a voice is covered by the same
    /// check the moment it reports a count — and so this is testable with a
    /// stub instead of by exhausting the machine's memory.
    public static func silentLines(
        in providers: [ScoreLineID: any LineVoiceProvider]
    ) -> [SilentLineReport] {
        providers
            .compactMap { lineID, provider -> SilentLineReport? in
                let unbuilt = provider.unbuiltVoiceCount
                guard unbuilt > 0 else { return nil }
                return SilentLineReport(
                    lineID: lineID,
                    soundName: provider.displayName,
                    unbuiltVoiceCount: unbuilt
                )
            }
            // Sorted so two runs over the same program report in the same
            // order; a dictionary's own order is not stable across launches.
            .sorted { $0.lineID.rawValue < $1.lineID.rawValue }
    }
}
