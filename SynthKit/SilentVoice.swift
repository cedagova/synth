import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// The sound a line makes when it has an instrument to play and no way to play
/// it.
///
/// **Silence is the answer, and it is a decision rather than a fallback.**
/// Issue #24 requires a line assigned a not-downloaded instrument to be flagged
/// and substituted only with the owner's explicit acknowledgment. Quietly
/// handing it a synth patch would be the pleasanter failure and the wrong one:
/// the owner would hear a piece that sounds finished and is not what they
/// configured. So the line goes quiet, `LineInstrumentAdvice` says exactly why
/// in the line list, and the owner can either download the library or press the
/// button that turns this into a named substitute.
///
/// It carries the *intended* sound's name, so everything downstream — the mixer
/// strip, VoiceOver, an export's line list — says "Cello section" rather than
/// "silence". What is missing is audible content, not identity.
public struct SilentVoiceProvider: LineVoiceProvider {
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    /// Nothing to ring out.
    public var releaseTailSeconds: Double { 0 }

    public func makeVoice(sampleRate: Double) -> LineVoiceInstance {
        var vtable = SynthLineVoice()
        sample_voice_fill_silence(&vtable)
        // Stateless: the C side installs six callbacks that hold no pointer, so
        // there is nothing to free and no lifetime to manage.
        return LineVoiceInstance(vtable: vtable, release: {})
    }
}
