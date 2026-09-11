import Foundation

/// The one owner-facing control over the master stage (D65-1, D65-2 option A).
///
/// One switch, covering bus cohesion and loudness calibration together. The
/// true-peak ceiling is deliberately *not* behind it: an export that clips is a
/// defect rather than a matter of taste, so the ceiling is always in the graph
/// and has no control at all (AD-P6). That split is the whole of D65-2 — REQ-004
/// keeps its literal bypass for everything but the ceiling, and the ceiling only
/// acts when the raw sum would have clipped anyway.
///
/// A separate type from `ExpressionSettings` rather than another field on it,
/// for the reason those two are separate: they are different kinds of thing.
/// Expression shapes the realized timeline; this shapes the summed audio and
/// leaves the timeline untouched, which is why changing it needs no
/// re-realization.
public struct ProducedMasterSettings: Equatable, Hashable, Sendable, Codable {
    /// On by default, per owner decision D65-3 — for a fresh preset and for a
    /// stored preset written before the field existed.
    public let isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// What playback uses when the owner has not chosen: on (D65-3).
    public static let standard = ProducedMasterSettings(isEnabled: true)

    /// Cohesion and calibration off — REQ-004's bypass state for this term.
    /// The ceiling remains, and remains bit-transparent below itself.
    public static let off = ProducedMasterSettings(isEnabled: false)
}

/// What the bounded analysis pass measured about one program, and the two
/// figures the render thread needs because of it.
///
/// **Why a measurement at all.** Two pieces in this library can differ by more
/// than 10 dB for reasons that have nothing to do with how loud either was
/// meant to be: how many lines the score has, what the instruments' own levels
/// are, how dense the writing is. REQ-005 asks that they export at comparable
/// loudness, and the only honest way to know how loud a program is, is to render
/// some of it and measure.
///
/// **Why it is a per-program constant rather than a process.** AD-P5: the gain
/// is computed once at program build and then never moves, so the same inputs
/// keep producing the same audio and an export cannot drift from live playback.
/// Nothing here adapts while the piece is playing.
public struct MasterCalibration: Equatable, Sendable {
    /// Why the calibration is what it is. Two of the three cases are unity, and
    /// both of them are a deliberate answer rather than a failure to produce
    /// one: a silent program has no loudness to match, and an analysis that
    /// could not run must leave the piece at the level it already had. Neither
    /// may ever produce silence.
    public enum Outcome: Equatable, Sendable {
        /// Measured, and the gain brings the program to the fixed target.
        case calibrated
        /// Nothing to measure: no notes, or an excerpt set that rendered below
        /// the silence floor. Unity gain, cohesion off.
        case silentProgram
        /// The analysis render itself failed. Unity gain, cohesion off, and the
        /// reason is reported so the owner is told rather than left with a
        /// piece that is quietly uncalibrated.
        case unavailable(reason: String)

        public var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }
    }

    /// Linear gain applied to the summed bus when the produced master is on.
    public let gain: Float

    /// Where "loud for this piece" sits, in linear amplitude, so cohesion has
    /// something piece-relative to work against. Zero disables cohesion.
    public let cohesionThreshold: Float

    /// The windowed-RMS loudness proxy the analysis measured, linear.
    public let measuredLoudness: Float

    /// How much program time was actually rendered and measured. Bounded by
    /// `MasterStage.maximumAnalyzedSeconds` (P65-5), so this never grows with
    /// the length of the piece.
    public let analyzedSeconds: Double

    public let outcome: Outcome

    public init(
        gain: Float,
        cohesionThreshold: Float,
        measuredLoudness: Float,
        analyzedSeconds: Double,
        outcome: Outcome
    ) {
        self.gain = gain
        self.cohesionThreshold = cohesionThreshold
        self.measuredLoudness = measuredLoudness
        self.analyzedSeconds = analyzedSeconds
        self.outcome = outcome
    }

    /// The no-calibration answer: the program's own level, cohesion off.
    public static func unity(_ outcome: Outcome, analyzedSeconds: Double = 0) -> MasterCalibration {
        MasterCalibration(
            gain: 1,
            cohesionThreshold: 0,
            measuredLoudness: 0,
            analyzedSeconds: analyzedSeconds,
            outcome: outcome
        )
    }

    /// How far this program sits from the target, in decibels. Zero when
    /// calibration did not apply.
    public var appliedDecibels: Double {
        gain > 0 ? 20 * log10(Double(gain)) : 0
    }

    /// What to tell the owner when the measurement could not be made. `nil`
    /// when there is nothing to say.
    public var statusSentence: String? {
        guard case .unavailable(let reason) = outcome else { return nil }
        return "The produced master could not measure this piece, so its level is "
            + "unchanged: \(reason)"
    }
}

/// The master stage's analysis policy, in one place.
///
/// The DSP's own taste constants — the ceiling, its lookahead, cohesion's ratio
/// and timing — live in `SynthAudioCoreInternal.h` beside the code that applies
/// them, the `SYNTH_DEPTH_*` precedent. What is here is the other half: how much
/// of a program is measured, how, and what it is measured against. Nothing in
/// this enum is owner-visible.
public enum MasterStage {
    /// The fixed loudness target, as the same windowed-RMS proxy the analysis
    /// measures, in linear amplitude.
    ///
    /// −20 dBFS on the proxy. Chosen so a full orchestral tutti still has room
    /// for its own crest factor under the −1 dBFS ceiling: a calibrated mix
    /// peaks some way below the ceiling rather than sitting on it, so the
    /// ceiling stays the exception it is meant to be rather than a compressor
    /// nobody asked for.
    public static let loudnessTarget: Float = 0.1

    /// Upper bound on program time the analysis may render (P65-5).
    ///
    /// This is the whole of the calibration cost bound. The recorded REQ-007
    /// guardrail run is 203.5 s of twelve lines; rendering that before the first
    /// Play would be indefensible, and rendering *any* fixed fraction of it
    /// would still grow with the piece. A fixed cap does not.
    public static let maximumAnalyzedSeconds: Double = 6

    /// One excerpt's length. Short, so that the cap buys six of them: a piece
    /// whose dynamics move — which is every piece worth calibrating — is
    /// represented far better by six seconds taken from six places than by six
    /// seconds taken from two.
    public static let excerptSeconds: Double = 1

    /// Room left after each excerpt so its release tail decays instead of
    /// landing on the next excerpt's first note. Rendered, deliberately not
    /// measured: it is there to keep the excerpts independent, and a decay is
    /// not programme material.
    public static let excerptTailSeconds: Double = 0.5

    /// Loudness window and hop. The 400 ms window is the one the broadcast
    /// loudness standards use, and it is the right order of magnitude for the
    /// same reason here: shorter reads individual notes, longer smears a tutti
    /// into the bar before it.
    public static let windowSeconds: Double = 0.4
    public static let windowHopSeconds: Double = 0.1

    /// Absolute gate: windows quieter than this are not programme material.
    public static let absoluteGateDecibels: Double = -70

    /// Relative gate, below the ungated mean. Keeps the rests and decays of a
    /// quiet passage from dragging the measured loudness below what the piece
    /// actually sounds like.
    public static let relativeGateDecibels: Double = -10

    /// Bounds on the gain, so a nearly-silent excerpt set cannot be amplified
    /// into noise and a very hot one cannot be pushed into the ceiling.
    public static let minimumGain: Float = 0.125
    public static let maximumGain: Float = 4

    /// Below this measured loudness the program counts as silent and calibrates
    /// to unity rather than to a huge gain.
    public static let silenceFloor: Float = 1e-4

    /// How far above the piece's own measured loudness cohesion starts to act,
    /// as a linear ratio. ≈ +8 dB: above the body of the music, so cohesion
    /// answers to tuttis and transients and leaves everything else alone.
    public static let cohesionHeadroom: Float = 2.5
}

// MARK: - Measuring a program

extension MasterCalibration {
    /// Measure one program and derive its calibration.
    ///
    /// **A pure function of the program, not of the mix.** The inputs are the
    /// realized timeline, the resolved voices and the rate — exactly the three
    /// things a `RenderProgram` is built from — so the gain follows the piece,
    /// the preset's settings and every line's resolved sound, including a
    /// substitute being replaced by its downloaded library (which already
    /// rebuilds the program). It deliberately does *not* read the mixer: a
    /// calibration that followed the faders would re-run this analysis on every
    /// fader nudge, and what the owner does with a strip is theirs rather than
    /// something to compensate for.
    ///
    /// Renders through `PlaybackEngine.renderTimelineOffline` — the one render
    /// path, with the produced master off so this cannot recurse into itself.
    /// - Parameter render: how an excerpt set becomes audio. Defaults to the one
    ///   render path. It is a parameter only so that the failure branch below is
    ///   reachable from a test: "an analysis that cannot run leaves the piece at
    ///   unity and says so" is a promise about what happens when rendering
    ///   throws, and a promise no test can reach is not one.
    public static func calibrate(
        timeline: PerformanceTimeline,
        voices: LineVoiceAssignment,
        sampleRate: Double,
        render: (PerformanceTimeline, Double, LineVoiceAssignment) throws
            -> PlaybackEngine.RenderedAudio = { timeline, rate, voices in
                try PlaybackEngine.renderTimelineOffline(
                    timeline, sampleRate: rate, voices: voices
                )
            }
    ) -> MasterCalibration {
        let excerpts = MasterStage.excerpts(in: timeline)
        guard !excerpts.isEmpty else { return .unity(.silentProgram) }

        let analyzed = Double(excerpts.count) * MasterStage.excerptSeconds
        let analysisTimeline = MasterStage.analysisTimeline(timeline, excerpts: excerpts)

        let audio: PlaybackEngine.RenderedAudio
        do {
            audio = try render(analysisTimeline, sampleRate, voices)
        } catch {
            return .unity(.unavailable(reason: String(describing: error)), analyzedSeconds: 0)
        }

        // Measure the excerpts, not the decay room between them.
        let slotFrames = Int((MasterStage.excerptSeconds + MasterStage.excerptTailSeconds)
            * sampleRate)
        let excerptFrames = Int(MasterStage.excerptSeconds * sampleRate)
        let regions = (0..<excerpts.count).map { index in
            (index * slotFrames)..<(index * slotFrames + excerptFrames)
        }

        let loudness = MasterStage.loudness(audio, regions: regions)
        guard loudness >= MasterStage.silenceFloor else {
            return .unity(.silentProgram, analyzedSeconds: analyzed)
        }

        let wanted = MasterStage.loudnessTarget / loudness
        let gain = min(MasterStage.maximumGain, max(MasterStage.minimumGain, wanted))
        return MasterCalibration(
            gain: gain,
            cohesionThreshold: loudness * MasterStage.cohesionHeadroom,
            measuredLoudness: loudness,
            analyzedSeconds: analyzed,
            outcome: .calibrated
        )
    }
}

extension MasterStage {
    /// Which stretches of the program to measure, as microsecond ranges.
    ///
    /// **The densest window of each part of the piece, deterministically.** A
    /// bounded analysis has to choose, and two biases have to be avoided at
    /// once. Measuring whatever comes first would calibrate a piece that opens
    /// quietly to its introduction and then let its tutti meet the ceiling;
    /// measuring only the single densest passage in the whole work would
    /// calibrate a long piece to one bar of it. So the program is cut into as
    /// many segments as there is budget for excerpts, and each contributes its
    /// own densest window — a sample spread across the piece, each part of it
    /// represented by the passage that decides how loud that part is.
    ///
    /// Note onsets per window is the proxy for "how much is going on", and it is
    /// read off the realized timeline rather than off any audio, so the choice is
    /// a pure function of the program. Every tie breaks on position, so two runs
    /// cannot pick different windows.
    static func excerpts(in timeline: PerformanceTimeline) -> [Range<Int64>] {
        let slot = Int64(excerptSeconds * 1_000_000)
        var span = timeline.totalMicroseconds
        for line in timeline.lines {
            for event in line.events where event.endMicroseconds > span {
                span = event.endMicroseconds
            }
        }
        guard span > 0, slot > 0 else { return [] }

        let windowCount = max(1, Int((span + slot - 1) / slot))
        var density = [Int](repeating: 0, count: windowCount)
        for line in timeline.lines {
            for event in line.events {
                let index = Int(event.onsetMicroseconds / slot)
                if index >= 0, index < density.count { density[index] += 1 }
            }
        }
        guard density.contains(where: { $0 > 0 }) else { return [] }

        let wanted = max(1, Int(maximumAnalyzedSeconds / excerptSeconds))
        var chosen: Set<Int> = []

        // The densest window of each segment, earliest of any tie.
        for segment in 0..<wanted {
            let first = segment * windowCount / wanted
            let last = min(windowCount, (segment + 1) * windowCount / wanted)
            guard first < last else { continue }
            var best: Int?
            for index in first..<last where density[index] > 0 {
                if let current = best {
                    if density[index] > density[current] { best = index }
                } else {
                    best = index
                }
            }
            if let best { chosen.insert(best) }
        }

        // A piece shorter than the budget, or one with empty segments, leaves
        // room: fill it with the densest windows not already taken.
        if chosen.count < wanted {
            let remaining = (0..<windowCount)
                .filter { density[$0] > 0 && !chosen.contains($0) }
                .sorted { left, right in
                    density[left] != density[right]
                        ? density[left] > density[right]
                        : left < right
                }
            for index in remaining.prefix(wanted - chosen.count) { chosen.insert(index) }
        }

        return chosen.sorted().map { index in
            let start = Int64(index) * slot
            return start..<(start + slot)
        }
    }

    /// The chosen excerpts laid end to end as one short timeline.
    ///
    /// **An analysis value, never played and never exported.** Concatenating is
    /// what keeps the cost bounded by the cap rather than by the piece: one
    /// offline render of a few seconds, through the real graph and the real
    /// voices, instead of a seek and a settle per excerpt. Each excerpt keeps
    /// its own notes at their own relative positions, is cut at its end so it
    /// cannot ring into the next one, and is followed by
    /// `excerptTailSeconds` of room for its release — which the loudness gate
    /// then discards.
    static func analysisTimeline(
        _ timeline: PerformanceTimeline,
        excerpts: [Range<Int64>]
    ) -> PerformanceTimeline {
        let slot = Int64((excerptSeconds + excerptTailSeconds) * 1_000_000)

        var lines: [PerformanceLine] = []
        lines.reserveCapacity(timeline.lines.count)
        for line in timeline.lines {
            var events: [PerformanceEvent] = []
            var spans: [PerformancePedalSpan] = []
            for (index, excerpt) in excerpts.enumerated() {
                let shift = Int64(index) * slot - excerpt.lowerBound
                // **Every note sounding during the excerpt, not only the ones
                // that start in it.** A held bass or a long melody note that
                // began a bar earlier is part of how loud this passage is, and
                // dropping it was measurably wrong: on a fixture with sustained
                // writing it read 2.5 dB quieter than the piece. Such a note
                // joins the excerpt at its start instead, which restarts its
                // attack — a small over-read that is the right side to err on
                // for a gain that must not let a tutti reach the ceiling.
                //
                // Cut at the end of the *slot*, not of the excerpt: a note rings
                // on through the tail that follows it, the way it would in the
                // piece, but it may not reach the next excerpt's first bar.
                let slotEnd = excerpt.lowerBound + slot
                for event in line.events
                where event.endMicroseconds > excerpt.lowerBound
                    && event.onsetMicroseconds < excerpt.upperBound {
                    let onset = max(event.onsetMicroseconds, excerpt.lowerBound)
                    let end = min(event.endMicroseconds, slotEnd)
                    events.append(
                        PerformanceEvent(
                            onsetMicroseconds: onset + shift,
                            durationMicroseconds: max(1, end - onset),
                            midiNoteNumber: event.midiNoteNumber,
                            velocity: event.velocity,
                            origin: event.origin,
                            onsetTicks: event.onsetTicks,
                            durationTicks: event.durationTicks,
                            playbackMeasureIndex: event.playbackMeasureIndex,
                            sourceMeasureIndex: event.sourceMeasureIndex
                        )
                    )
                }
                for span in line.pedalSpans {
                    let start = max(span.startMicroseconds, excerpt.lowerBound)
                    let end = min(span.endMicroseconds, excerpt.upperBound)
                    guard end > start else { continue }
                    spans.append(
                        PerformancePedalSpan(
                            startMicroseconds: start + shift,
                            endMicroseconds: end + shift,
                            startTicks: span.startTicks,
                            endTicks: span.endTicks
                        )
                    )
                }
            }
            lines.append(
                PerformanceLine(
                    id: line.id, name: line.name, events: events, pedalSpans: spans
                )
            )
        }

        return PerformanceTimeline(
            pieceID: timeline.pieceID,
            contentSHA256: timeline.contentSHA256,
            ticksPerQuarter: timeline.ticksPerQuarter,
            settings: timeline.settings,
            seed: timeline.seed,
            totalMicroseconds: Int64(excerpts.count) * slot,
            totalTicks: timeline.totalTicks,
            lines: lines,
            report: timeline.report
        )
    }

    /// The windowed-RMS integrated loudness proxy, in linear amplitude.
    ///
    /// Not an LUFS meter and not pretending to be one: there is no K-weighting
    /// filter here, because the claim REQ-005 makes is that two pieces from this
    /// library land within ±2 dB of one target *on this proxy*, and a shared
    /// measure is all that requires. The two gates are what make it a measure of
    /// the music rather than of the rests — the standards' own structure, for
    /// the same reason they have it.
    /// - Parameter regions: frame ranges to measure, or nil for the whole
    ///   render. The analysis pass passes its excerpts, so the silence it leaves
    ///   between them for release tails is rendered but never measured.
    static func loudness(
        _ audio: PlaybackEngine.RenderedAudio,
        regions: [Range<Int>]? = nil
    ) -> Float {
        let window = Int(windowSeconds * audio.sampleRate)
        let hop = max(1, Int(windowHopSeconds * audio.sampleRate))
        guard window > 0, audio.frameCount >= window else { return 0 }

        let spans = regions ?? [0..<audio.frameCount]
        var powers: [Double] = []
        powers.reserveCapacity(audio.frameCount / hop + 1)
        for span in spans {
            let first = max(0, span.lowerBound)
            let limit = min(audio.frameCount, span.upperBound)
            var start = first
            while start + window <= limit {
                var total = 0.0
                for index in start..<(start + window) {
                    let left = Double(audio.left[index])
                    let right = Double(audio.right[index])
                    total += (left * left + right * right) / 2
                }
                powers.append(total / Double(window))
                start += hop
            }
        }
        guard !powers.isEmpty else { return 0 }

        let absoluteGate = pow(10, absoluteGateDecibels / 10)
        let above = powers.filter { $0 > absoluteGate }
        guard !above.isEmpty else { return 0 }

        let mean = above.reduce(0, +) / Double(above.count)
        let relativeGate = mean * pow(10, relativeGateDecibels / 10)
        let kept = above.filter { $0 > relativeGate }
        let gated = kept.isEmpty ? above : kept

        return Float((gated.reduce(0, +) / Double(gated.count)).squareRoot())
    }

    /// Peak of `samples` after four-times oversampling — the inter-sample peak
    /// the ceiling is specified against, and the measure REQ-005's assertions
    /// use.
    ///
    /// Shares no code with the render thread's detector on purpose: a ceiling
    /// measured with its own estimator would agree with itself whatever it did.
    /// This is the textbook version — a 64-tap windowed-sinc interpolator, a
    /// different filter of a different length — so the two have to agree about
    /// the signal rather than about the method.
    public static func truePeak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let oversample = 4
        let halfTaps = 8
        let taps = halfTaps * 2

        // One polyphase bank, built once: sinc at each quarter-sample offset,
        // Blackman-windowed.
        var bank = [[Double]](repeating: [Double](repeating: 0, count: taps), count: oversample)
        for phase in 0..<oversample {
            let fraction = Double(phase) / Double(oversample)
            var sum = 0.0
            for tap in 0..<taps {
                let position = Double(tap - halfTaps + 1) - fraction
                let sinc = abs(position) < 1e-9
                    ? 1.0
                    : sin(Double.pi * position) / (Double.pi * position)
                let windowPosition = Double(tap) / Double(taps - 1)
                let blackman = 0.42
                    - 0.5 * cos(2 * Double.pi * windowPosition)
                    + 0.08 * cos(4 * Double.pi * windowPosition)
                bank[phase][tap] = sinc * blackman
                sum += sinc * blackman
            }
            // Unity DC gain, so the measurement cannot invent or lose level.
            if sum != 0 {
                for tap in 0..<taps { bank[phase][tap] /= sum }
            }
        }

        // Only interpolate where the peak could plausibly be. Reconstruction
        // overshoot above the surrounding samples is a fraction of a decibel for
        // anything with a spectrum; a 12 dB band below the sample peak is two
        // orders of magnitude of margin on that, and it turns an O(n · 64)
        // measurement of a whole export into one of its loudest moments.
        var samplePeak: Float = 0
        for sample in samples where abs(sample) > samplePeak { samplePeak = abs(sample) }
        guard samplePeak > 0 else { return 0 }
        let candidateFloor = samplePeak * 0.251_188_6  // −12 dB

        var peak = 0.0
        for index in 0..<samples.count {
            let low = max(0, index - 1)
            let high = min(samples.count - 1, index + 1)
            var local: Float = 0
            for neighbour in low...high where abs(samples[neighbour]) > local {
                local = abs(samples[neighbour])
            }
            guard local >= candidateFloor else { continue }

            for phase in 0..<oversample {
                var value = 0.0
                for tap in 0..<taps {
                    let source = index + tap - halfTaps + 1
                    guard source >= 0, source < samples.count else { continue }
                    value += bank[phase][tap] * Double(samples[source])
                }
                if abs(value) > peak { peak = abs(value) }
            }
        }
        return Float(max(peak, Double(samplePeak)))
    }

    /// The true peak of both channels together, in decibels relative to full
    /// scale. `-.infinity` for silence.
    public static func truePeakDecibels(_ audio: PlaybackEngine.RenderedAudio) -> Double {
        let peak = max(truePeak(audio.left), truePeak(audio.right))
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    /// The loudness proxy in decibels, for a readable assertion message.
    public static func loudnessDecibels(_ audio: PlaybackEngine.RenderedAudio) -> Double {
        let value = loudness(audio)
        return value > 0 ? 20 * log10(Double(value)) : -.infinity
    }

    /// The fixed target, in decibels on the proxy.
    public static var loudnessTargetDecibels: Double {
        20 * log10(Double(loudnessTarget))
    }
}
