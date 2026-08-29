import Foundation
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// A `PerformanceTimeline` converted into the flat, preallocated form the
/// render thread can walk without allocating.
///
/// One of these owns a C `SynthRenderEngine` and every voice hanging off it.
/// Building one is a control-thread operation; once built it is only ever read
/// by the render thread, plus the scalar mixer and transport setters, which are
/// safe from either side.
///
/// A program is bound to one sample rate, because event positions are stored in
/// frames. Changing rate — a device switch, or entering offline rendering —
/// builds a new program rather than patching this one, which is what keeps the
/// live and offline paths literally the same code.
public final class RenderProgram: @unchecked Sendable {
    /// The C engine. Opaque: everything goes through the accessors.
    let engine: OpaquePointer

    public let sampleRate: Double
    public let lineCount: Int
    public let totalFrames: Int64

    /// Line identity in render order, so a caller can address a mixer strip by
    /// the same `ScoreLineID` the compiled score used.
    public let lineIDs: [ScoreLineID]
    public let lineNames: [String]

    private let voices: [LineVoiceInstance]
    private var isDestroyed = false

    /// Lines whose sound meant to build a voice and could not, so they render
    /// silence nobody asked for.
    ///
    /// **Empty in every normal run, and the program has to be able to say so
    /// when it is not.** A sampler's voice is one small allocation, so this only
    /// moves under real memory exhaustion — but when it does, the owner assigned
    /// a cello and is hearing nothing. INS002 deliberately chose silence over
    /// quietly substituting a synth patch there, because an unasked-for
    /// substitute is the end state issue #24 gates; recording which lines it
    /// happened to is what lets INS003 flag them instead of leaving the owner to
    /// discover it by listening.
    ///
    /// Deliberately *not* the same as "this line renders silence": a line whose
    /// instrument is not downloaded is quiet on purpose and carries its own
    /// sentence already.
    public let unbuiltVoiceLineIDs: [ScoreLineID]

    /// How long this program's voices may ring after the last scheduled note
    /// ends, taken from the sound itself.
    ///
    /// A synth patch can ask for a twenty-second release into a long reverb,
    /// and a fixed figure would cut it off — so `LineVoiceProvider` declares
    /// its own tail and this is the longest any line asked for. Capped so a
    /// single extreme patch cannot make every render minutes longer than the
    /// music.
    public static let maximumReleaseTailSeconds: Double = 30.0
    public let releaseTailSeconds: Double

    /// Largest buffer the graph may ask for in one render call. AVAudioEngine
    /// uses far less than this live; manual rendering is free to use all of it.
    public static let maximumFrameCount: Int32 = 4096

    public enum BuildError: Error, CustomStringConvertible {
        case engineAllocationFailed
        case lineAllocationFailed(lineIndex: Int)

        public var description: String {
            switch self {
            case .engineAllocationFailed:
                return "Could not allocate the render engine."
            case .lineAllocationFailed(let index):
                return "Could not allocate render storage for line \(index)."
            }
        }
    }

    /// Convert `microseconds` on the timeline into a frame position.
    ///
    /// Deterministic for a given rate, and the single place the conversion
    /// happens, so the offline and live paths cannot disagree about where a
    /// note starts.
    public static func frame(forMicroseconds microseconds: Int64, sampleRate: Double) -> Int64 {
        Int64((Double(microseconds) * sampleRate / 1_000_000.0).rounded())
    }

    public static func microseconds(forFrame frame: Int64, sampleRate: Double) -> Int64 {
        Int64((Double(frame) * 1_000_000.0 / sampleRate).rounded())
    }

    /// Every line through one sound. The signature increments 002 and 003 used.
    public convenience init(
        timeline: PerformanceTimeline,
        sampleRate: Double,
        voiceProvider: LineVoiceProvider = SynthPatchVoiceProvider()
    ) throws {
        try self.init(
            timeline: timeline, sampleRate: sampleRate, voices: .uniform(voiceProvider)
        )
    }

    /// Each line through the sound `voices` names for it (REQ-006).
    public init(
        timeline: PerformanceTimeline,
        sampleRate: Double,
        voices: LineVoiceAssignment
    ) throws {
        self.sampleRate = sampleRate
        self.lineCount = timeline.lines.count
        self.lineIDs = timeline.lines.map(\.id)
        self.lineNames = timeline.lines.map(\.name)

        guard let engine = synth_engine_create(
            Int32(timeline.lines.count),
            Self.maximumFrameCount,
            sampleRate
        ) else {
            throw BuildError.engineAllocationFailed
        }
        self.engine = engine

        var builtVoices: [LineVoiceInstance] = []
        builtVoices.reserveCapacity(timeline.lines.count)

        var unbuilt: [ScoreLineID] = []
        var lastFrame: Int64 = 0
        /// The longest tail any line's own sound asked for. With per-line
        /// assignment this is a maximum over the lines rather than one
        /// provider's figure, so a single long-release sound on one line is not
        /// truncated by a short one on another.
        var longestTailSeconds: Double = 0

        for (lineIndex, line) in timeline.lines.enumerated() {
            guard synth_engine_reserve_line(
                engine,
                Int32(lineIndex),
                Int32(line.events.count),
                Int32(line.pedalSpans.count)
            ) != 0 else {
                for voice in builtVoices { voice.release() }
                synth_engine_destroy(engine)
                throw BuildError.lineAllocationFailed(lineIndex: lineIndex)
            }

            for (eventIndex, event) in line.events.enumerated() {
                // ────────────────────────────────────────────────────────────
                // Schedule the MICROSECOND fields, never the tick fields.
                //
                // `onsetTicks` is the notated position — deliberately left
                // unmoved by humanization so the transport can highlight the
                // right note (#16). `onsetMicroseconds` is where the note
                // actually sounds. Re-deriving time from ticks through the
                // tempo map would silently discard every humanized offset and
                // no test that only checked note pitches would notice, so
                // `OfflineRenderTests.testHumanizedOnsetsAreRenderedNotTempoMapOnsets`
                // renders both settings and fails if these two ever converge.
                // ────────────────────────────────────────────────────────────
                let onset = Self.frame(forMicroseconds: event.onsetMicroseconds, sampleRate: sampleRate)
                let end = Self.frame(forMicroseconds: event.endMicroseconds, sampleRate: sampleRate)
                synth_engine_set_event(
                    engine,
                    Int32(lineIndex),
                    Int32(eventIndex),
                    onset,
                    end,
                    Int32(event.midiNoteNumber),
                    Int32(event.velocity)
                )
                if end > lastFrame { lastFrame = end }
            }

            for (spanIndex, span) in line.pedalSpans.enumerated() {
                let start = Self.frame(forMicroseconds: span.startMicroseconds, sampleRate: sampleRate)
                let end = Self.frame(forMicroseconds: span.endMicroseconds, sampleRate: sampleRate)
                synth_engine_set_pedal_span(engine, Int32(lineIndex), Int32(spanIndex), start, end)
                if end > lastFrame { lastFrame = end }
            }

            let lineProvider = voices(line.id)
            longestTailSeconds = max(longestTailSeconds, lineProvider.releaseTailSeconds)

            let voice = lineProvider.makeVoice(sampleRate: sampleRate)
            var vtable = voice.vtable
            synth_engine_set_line_voice(engine, Int32(lineIndex), &vtable)
            builtVoices.append(voice)
            if voice.didFailToBuild { unbuilt.append(line.id) }
        }
        self.unbuiltVoiceLineIDs = unbuilt

        // The timeline's own total can fall short of the last sounding note —
        // a final chord rings past the last bar line — so take whichever is
        // later and then add room for the release tail.
        let timelineEnd = Self.frame(forMicroseconds: timeline.totalMicroseconds, sampleRate: sampleRate)
        self.releaseTailSeconds = min(
            max(longestTailSeconds, 0), Self.maximumReleaseTailSeconds)
        let tail = Int64((self.releaseTailSeconds * sampleRate).rounded())
        self.totalFrames = max(timelineEnd, lastFrame) + tail
        synth_engine_set_total_frames(engine, self.totalFrames)

        self.voices = builtVoices
    }

    deinit {
        guard !isDestroyed else { return }
        isDestroyed = true
        synth_engine_destroy(engine)
        for voice in voices { voice.release() }
    }

    public var totalDuration: Duration {
        .microseconds(Self.microseconds(forFrame: totalFrames, sampleRate: sampleRate))
    }

    /// Index of the line with this identifier, or nil.
    public func index(of id: ScoreLineID) -> Int? {
        lineIDs.firstIndex(of: id)
    }
}
