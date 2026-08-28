import Foundation

/// Which sound each line renders with.
///
/// **The piece of PLY003's interface that per-line assignment needed.** Until
/// increment 004 every line of a program shared one `LineVoiceProvider`,
/// because there was nothing in the product that could say otherwise: increment
/// 002 had one built-in voice and increment 003 had one sound under edit.
/// REQ-006 gives each line its own sound, so the program has to be able to ask
/// per line — and this is that question, expressed so the old callers still
/// read as before.
///
/// A function of `ScoreLineID` rather than a positional array on purpose. Line
/// order is the compiled score's, and an array would silently mis-assign every
/// line if the two ever disagreed; an identity cannot be off by one.
public struct LineVoiceAssignment: Sendable {
    /// The sound for one line. Total: a line the assignment does not know still
    /// gets a provider, because a silent line is never the right answer.
    public let provider: @Sendable (ScoreLineID) -> LineVoiceProvider

    public init(_ provider: @escaping @Sendable (ScoreLineID) -> LineVoiceProvider) {
        self.provider = provider
    }

    /// Every line through one sound — what the engine did before this existed.
    public static func uniform(_ provider: LineVoiceProvider) -> LineVoiceAssignment {
        LineVoiceAssignment { _ in provider }
    }

    /// A lookup with a fallback for lines it does not name.
    public init(
        providersByLine: [ScoreLineID: any LineVoiceProvider],
        fallback: LineVoiceProvider = SynthPatchVoiceProvider()
    ) {
        self.init { lineID in providersByLine[lineID] ?? fallback }
    }

    public func callAsFunction(_ lineID: ScoreLineID) -> LineVoiceProvider {
        provider(lineID)
    }
}
