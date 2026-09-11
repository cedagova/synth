import Foundation

/// How high or low one line actually sounds, summarized from the compiled
/// score (STG003).
///
/// **One number, from the notes themselves.** A part called "Contrabass" is a
/// hint; what it plays is the fact. The summary is the median of the line's
/// sounding pitches in MIDI note numbers — the median rather than the mean
/// because a cello line with one high harmonic in it is still a cello line,
/// and a single outlier must not move where the line sits on the stage.
///
/// **Derived from the score, never from audio** (AD-P7). That is what keeps
/// preset creation deterministic and reconcile-safe: the same bytes compile to
/// the same score, the same score summarizes to the same register, and the
/// same register stages the same seat. Nothing here reads a rendered sample.
///
/// **Absent rather than guessed.** A line with only a handful of notated
/// pitches — a cymbal crash, a single sustained drone, an empty staff — has no
/// register worth acting on, so `init?` answers nil and the staging derivation
/// falls back to the instrument family alone.
public struct LineRegister: Equatable, Sendable {
    /// The median sounding pitch as a MIDI note number (middle C = 60).
    public let medianMIDINote: Int

    /// How many sounding pitches the median was taken over. Kept because the
    /// confidence of the summary is part of the summary: two notes and two
    /// hundred are not the same claim, and a later refinement may want to
    /// weight by it without recompiling the score.
    public let soundingPitchCount: Int

    /// Fewer sounding pitches than this and the line has no register.
    ///
    /// Four, because three notes is a gesture and the median of it is an
    /// accident of which note happened to be in the middle. This is the
    /// "too few pitches" boundary the acceptance names.
    public static let minimumSoundingPitches = 4

    public init(medianMIDINote: Int, soundingPitchCount: Int) {
        self.medianMIDINote = medianMIDINote
        self.soundingPitchCount = soundingPitchCount
    }

    /// Summarizes the sounding pitches of `notes`, or nil when there are too
    /// few to mean anything.
    ///
    /// Rests contribute nothing, and so does a pitch the model cannot place on
    /// the MIDI scale. Chord members and tie continuations *do* count: they are
    /// pitches the line sounds, and a line that spends half its bars holding a
    /// low tied note is low.
    ///
    /// Deterministic and order-independent: a median over a sorted copy of the
    /// same multiset is the same number however the notes arrived. Even counts
    /// take the lower of the two middle values, so the answer is always one
    /// notated pitch rather than a quarter-tone between two.
    public init?(summarizing notes: [ScoreNote]) {
        let pitches = notes.compactMap { $0.pitch?.midiNoteNumber }.sorted()
        guard pitches.count >= Self.minimumSoundingPitches else { return nil }
        self.init(
            medianMIDINote: pitches[(pitches.count - 1) / 2],
            soundingPitchCount: pitches.count
        )
    }
}

extension ScoreLine {
    /// This line's register summary, or nil when it has too few sounding
    /// pitches (see `LineRegister`).
    ///
    /// Computed rather than stored: `CompiledScore` is the model of the bytes,
    /// and a value derivable from `notes` must not be able to disagree with
    /// them. Preset creation asks for it once per line.
    public var register: LineRegister? { LineRegister(summarizing: notes) }
}
