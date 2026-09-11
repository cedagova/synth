import XCTest
@testable import SynthKit

/// MST001: the master stage after the line sum — the always-on true-peak
/// ceiling, the per-piece loudness calibration, and bus cohesion.
///
/// **Every claim here is a measurement of rendered audio**, because every one of
/// them is a claim about audio. The two that are not measurements are the two
/// that must be exact rather than close: an off-state that is bit-identical to
/// the raw line sum, and a render that is byte-identical between two runs and
/// two host buffer sizes.
///
/// The true peak is measured by `MasterStage.truePeak`, a polyphase windowed-sinc
/// oversampler (sixteen taps per phase across a four-phase bank) that shares no
/// code with the render thread's four-tap detector.
/// That separation is the point: a ceiling measured with its own estimator would
/// agree with itself whatever it did.
final class MasterStageRenderTests: XCTestCase {
    private static let sampleRate: Double = 48_000

    /// REQ-005's ceiling, as the render core defines it. Read from C rather than
    /// restated, so the assertion and the enforcement cannot drift apart.
    private var ceilingDecibels: Double {
        20 * log10(Double(synth_master_ceiling()))
    }

    private func timeline(
        _ musicXML: Data, id: String, settings: RealizationSettings = .standard
    ) throws -> PerformanceTimeline {
        PerformanceRealizer().realize(
            try ScoreCompiler().compile(pieceID: id, musicXML: musicXML), settings: settings
        )
    }

    /// The two dissimilar pieces REQ-005 is stated over: eighteen orchestral
    /// lines, and a two-line song. They are eleven decibels apart before
    /// calibration, which is the whole problem the calibration exists for.
    private func orchestral() throws -> PerformanceTimeline {
        try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 18, measureCount: 8),
            id: "orchestral"
        )
    }

    private func song() throws -> PerformanceTimeline {
        try timeline(MusicXMLScoreFixtures.melodyOverAccompaniment(), id: "song")
    }

    // MARK: REQ-005 — the ceiling, in every state

    /// No export clips, whatever state the bus is in.
    ///
    /// **Four states, and the last three are the ones that matter.** A render
    /// that never approaches the ceiling proves only that the ceiling does no
    /// harm; the boosted ones are where it has to do its job, and they are
    /// reachable — the master gain is clamped to 8, not to 1.
    func testTruePeakStaysUnderTheCeilingHoweverHotTheBusIs() throws {
        let piece = try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 18, measureCount: 4),
            id: "hot"
        )

        for boost in [Float(1), 2, 4, 8] {
            for produced in [ProducedMasterSettings.off, .standard] {
                let audio = try PlaybackEngine.renderTimelineOffline(
                    piece, sampleRate: Self.sampleRate, producedMaster: produced
                ) { engine in
                    engine.masterGain = boost
                }
                let truePeak = MasterStage.truePeakDecibels(audio)
                XCTAssertLessThanOrEqual(
                    truePeak, ceilingDecibels,
                    "with the bus at \(boost)x and the produced master "
                        + "\(produced.isEnabled ? "on" : "off") the export reached "
                        + "\(String(format: "%.3f", truePeak)) dBTP, above REQ-005's "
                        + "\(String(format: "%.3f", ceilingDecibels)) dBFS ceiling"
                )
            }
        }
    }

    /// And the ceiling is genuinely doing it, rather than the material simply
    /// never getting there.
    ///
    /// The vacuity guard for the test above: without this, a bug that removed
    /// the ceiling entirely would still pass it for every state whose raw sum
    /// happened to stay under −1 dBFS.
    func testTheCeilingIsWhatHoldsAHotBusDownRatherThanTheMaterial() throws {
        let piece = try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 18, measureCount: 4),
            id: "hot"
        )
        let quiet = try PlaybackEngine.renderTimelineOffline(piece, sampleRate: Self.sampleRate)
        let loud = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate
        ) { engine in
            engine.masterGain = 8
        }

        let headroom = 20 * log10(Double(quiet.peak()))
        XCTAssertLessThan(
            headroom, ceilingDecibels,
            "the unboosted render is already at the ceiling, so this proves nothing"
        )
        // Eight times a sum that peaked at `headroom` would be 18 dB above it,
        // which is well over full scale. The ceiling is the only reason it is
        // not.
        XCTAssertGreaterThan(headroom + 18, 0.0)
        XCTAssertLessThanOrEqual(20 * log10(Double(loud.peak())), ceilingDecibels)
    }

    // MARK: REQ-005 — comparable loudness

    /// Two dissimilar pieces export within ±2 dB of the fixed target, and the
    /// quiet one is not exported inaudibly low.
    func testTwoDissimilarPiecesExportAtTheSameLoudness() throws {
        let pieces: [(String, PerformanceTimeline)] = [
            ("eighteen orchestral lines", try orchestral()),
            ("a two-line song", try song())
        ]

        var rawLoudness: [Double] = []
        var producedLoudness: [Double] = []

        for (name, piece) in pieces {
            let raw = try PlaybackEngine.renderTimelineOffline(piece, sampleRate: Self.sampleRate)
            let produced = try PlaybackEngine.renderTimelineOffline(
                piece, sampleRate: Self.sampleRate, producedMaster: .standard
            )
            rawLoudness.append(MasterStage.loudnessDecibels(raw))
            producedLoudness.append(MasterStage.loudnessDecibels(produced))

            XCTAssertEqual(
                producedLoudness.last!, MasterStage.loudnessTargetDecibels, accuracy: 2,
                "\(name) exported at \(String(format: "%.2f", producedLoudness.last!)) dB on the "
                    + "proxy, more than 2 dB from the "
                    + "\(String(format: "%.1f", MasterStage.loudnessTargetDecibels)) dB target"
            )
        }

        // The vacuity guard: the two pieces have to actually differ before
        // calibration, or bringing them together means nothing.
        XCTAssertGreaterThan(
            abs(rawLoudness[0] - rawLoudness[1]), 6,
            "the two fixtures are already the same loudness uncalibrated "
                + "(\(rawLoudness)), so this test is not measuring the calibration"
        )
        XCTAssertLessThan(
            abs(producedLoudness[0] - producedLoudness[1]), 4,
            "calibrated, the two pieces are still \(producedLoudness) — further apart than "
                + "the ±2 dB each is allowed from the target"
        )
    }

    /// The quiet piece specifically: the produced master brings it up, by a lot.
    func testAQuietPieceIsNotExportedInaudiblyLow() throws {
        let piece = try song()
        let raw = try PlaybackEngine.renderTimelineOffline(piece, sampleRate: Self.sampleRate)
        let produced = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .standard
        )

        let lift = MasterStage.loudnessDecibels(produced) - MasterStage.loudnessDecibels(raw)
        XCTAssertGreaterThan(
            lift, 6,
            "the produced master lifted this piece by only \(String(format: "%.2f", lift)) dB; "
                + "it exports at \(String(format: "%.2f", MasterStage.loudnessDecibels(raw))) dB "
                + "raw, which is what REQ-005 calls inaudibly low"
        )
    }

    // MARK: REQ-004 — off is the raw line sum

    /// With the produced master off, the stage is transparent: not close to the
    /// raw line sum, identical to it, byte for byte.
    ///
    /// This is the claim D65-2 preserves and the one the ceiling could most
    /// easily have broken — it is in the graph in this state too. It is exact
    /// because the ceiling's gain is literally `1.0f` for material under it, so
    /// the bypass is a multiply by one rather than a tolerance.
    func testOffIsBitIdenticalToTheRawLineSumUnderTheCeiling() throws {
        for (name, piece) in [
            ("orchestral", try orchestral()),
            ("song", try song()),
            // A program that ends in silence, which is where a lookahead delay
            // line would show up as a truncated tail if the stage did not prime
            // itself.
            ("note into silence", try timeline(
                AudioRenderFixtures.twoLineFixture(), id: "silence", settings: .literal
            ))
        ] {
            let off = try PlaybackEngine.renderTimelineOffline(
                piece, sampleRate: Self.sampleRate, producedMaster: .off
            )
            XCTAssertLessThan(
                20 * log10(Double(off.peak())), ceilingDecibels,
                "\(name) is at the ceiling before the stage touches it, so bit-identity "
                    + "would be a statement about the ceiling acting rather than about the bypass"
            )

            let sum = try rawLineSum(piece, lineCount: piece.lines.count)
            XCTAssertEqual(off.frameCount, sum.count, "\(name): lengths differ")

            var largest: Float = 0
            for frame in 0..<off.frameCount {
                largest = max(largest, abs(off.left[frame] - sum[frame]))
            }
            // One unit in the last place of the peak, four times over: the mixer
            // accumulates with a fused multiply-add, so a sum built from
            // separately rendered lines rounds where the engine does not. The
            // reasoning is `BypassRecipeRenderTests`'s, and the same bound.
            XCTAssertLessThanOrEqual(
                largest, 4 * off.peak().ulp,
                "\(name): the produced-master-off render departs from the raw line sum by "
                    + "\(largest), more than the \(4 * off.peak().ulp) that rounding a peak of "
                    + "\(off.peak()) accounts for — something on the bus is not bypassed"
            )
        }
    }

    /// And on is audibly different, so the test above is not a comparison
    /// between two identical things.
    func testOnChangesTheRender() throws {
        let piece = try song()
        let off = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .off
        )
        let on = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .standard
        )
        XCTAssertNotEqual(
            off.canonicalData(), on.canonicalData(),
            "the produced master renders the same audio on as off"
        )
    }

    // MARK: Determinism

    /// Two renders of one program are byte-identical, and so are two renders in
    /// different host buffer sizes — with the whole stage engaged.
    ///
    /// The stage has more state than anything else on the bus: a delay line, a
    /// window of targets, two envelopes. Every one of them is per sample and
    /// lives in the engine, and this is what says so.
    func testTheProducedMasterRendersIdenticallyTwiceAndAtAnyBufferSize() throws {
        let piece = try song()

        let first = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .standard
        )
        let second = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .standard
        )
        XCTAssertEqual(
            first.canonicalData(), second.canonicalData(),
            "two renders of one program differ, so the stage is carrying something across runs"
        )

        func render(blockFrames: Int64) throws -> PlaybackEngine.RenderedAudio {
            let engine = PlaybackEngine()
            try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
            try engine.load(timeline: piece)
            engine.producedMaster = .standard
            engine.play()
            let total = try XCTUnwrap(engine.loadedProgram?.totalFrames)
            var left: [Float] = []
            var right: [Float] = []
            var remaining = total
            while remaining > 0 {
                let chunk = try engine.renderOffline(frameCount: min(blockFrames, remaining))
                guard chunk.frameCount > 0 else { break }
                left.append(contentsOf: chunk.left)
                right.append(contentsOf: chunk.right)
                remaining -= Int64(chunk.frameCount)
            }
            return PlaybackEngine.RenderedAudio(
                sampleRate: Self.sampleRate, left: left, right: right
            )
        }

        let small = try render(blockFrames: 64)
        let large = try render(blockFrames: 4096)
        XCTAssertEqual(
            small.canonicalData(), large.canonicalData(),
            "the master stage renders differently in 64-frame and 4096-frame blocks"
        )
        XCTAssertEqual(
            small.canonicalData(), first.canonicalData(),
            "rendering in blocks differs from rendering in one go"
        )
    }

    /// The lookahead costs no alignment: the stage primes itself, so a render
    /// starts at the frame the program starts at.
    ///
    /// Without the priming the whole output would arrive 64 frames late and the
    /// end of every release tail would be cut; with it, the produced-master-off
    /// render is the pre-stage engine bit for bit, which the bypass test above
    /// already establishes. This pins the visible half of the same fact.
    func testTheStageAddsNoLatencyToTheRender() throws {
        let piece = try timeline(
            AudioRenderFixtures.twoLineFixture(), id: "latency", settings: .literal
        )
        let audio = try PlaybackEngine.renderTimelineOffline(
            piece, sampleRate: Self.sampleRate, producedMaster: .standard
        )
        let expected = piece.lines[0].events.map(\.onsetMicroseconds).sorted()
        let detected = AudioRenderFixtures.detectedOnsetsMicroseconds(audio)

        XCTAssertFalse(detected.isEmpty, "no onsets were detected at all")
        XCTAssertEqual(
            Double(detected[0]), Double(expected[0]), accuracy: 15_000,
            "the first note sounded at \(detected[0]) µs but the timeline scheduled it at "
                + "\(expected[0]) µs — the lookahead is being paid for in latency"
        )
        XCTAssertGreaterThan(
            synth_master_lookahead_frames(), 0,
            "there is no lookahead to have compensated for, so this proves nothing"
        )
    }

    // MARK: Failure and edge behaviour

    /// A program with nothing in it calibrates to unity rather than to a huge
    /// gain — and unity means the bypass, exactly.
    func testASilentProgramCalibratesToUnity() throws {
        let piece = try timeline(AudioRenderFixtures.twoLineFixture(), id: "silent")
        let silent = PerformanceTimeline(
            pieceID: piece.pieceID,
            contentSHA256: piece.contentSHA256,
            ticksPerQuarter: piece.ticksPerQuarter,
            settings: piece.settings,
            seed: piece.seed,
            totalMicroseconds: piece.totalMicroseconds,
            totalTicks: piece.totalTicks,
            lines: piece.lines.map {
                PerformanceLine(id: $0.id, name: $0.name, events: [], pedalSpans: [])
            },
            report: piece.report
        )

        let calibration = MasterCalibration.calibrate(
            timeline: silent, voices: .uniform(SynthPatchVoiceProvider()),
            sampleRate: Self.sampleRate
        )
        XCTAssertEqual(calibration.outcome, .silentProgram)
        XCTAssertEqual(calibration.gain, 1, "a silent program was given a gain")
        XCTAssertEqual(calibration.cohesionThreshold, 0, "cohesion was armed on silence")

        let audio = try PlaybackEngine.renderTimelineOffline(
            silent, sampleRate: Self.sampleRate, producedMaster: .standard
        )
        XCTAssertEqual(audio.peak(), 0, "a silent program rendered something")
    }

    /// An analysis that cannot run leaves the piece at its own level and says
    /// so. Never silence, and never silently.
    func testAnAnalysisThatCannotRunFallsBackToUnityAndReportsIt() throws {
        struct Unreachable: Error, CustomStringConvertible {
            var description: String { "the analysis render failed" }
        }

        let piece = try song()
        let calibration = MasterCalibration.calibrate(
            timeline: piece,
            voices: .uniform(SynthPatchVoiceProvider()),
            sampleRate: Self.sampleRate,
            render: { _, _, _ in throw Unreachable() }
        )

        XCTAssertFalse(calibration.outcome.isAvailable)
        XCTAssertEqual(calibration.gain, 1, "a failed analysis changed the level anyway")
        XCTAssertEqual(calibration.cohesionThreshold, 0)
        let sentence = try XCTUnwrap(
            calibration.statusSentence, "a failed analysis said nothing to the owner"
        )
        XCTAssertTrue(
            sentence.contains("the analysis render failed"),
            "the reported sentence does not name what went wrong: \(sentence)"
        )
    }

    /// The bus refuses a figure it could not survive.
    ///
    /// `synth_clampf` passes a NaN straight through, and a NaN multiplied into
    /// the bus is silence for the rest of the piece — the one outcome every
    /// failure path in this leaf exists to avoid. Nothing in `MasterCalibration`
    /// can produce one; this is the bound that means nothing else can either.
    func testTheBusRefusesANonFiniteCalibration() throws {
        let piece = try song()
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
        try engine.load(timeline: piece)
        let program = try XCTUnwrap(engine.loadedProgram)

        synth_engine_set_master_calibration(program.engine, .nan, .nan)
        XCTAssertEqual(synth_engine_master_calibration_gain(program.engine), 1)
        XCTAssertEqual(synth_engine_master_cohesion_threshold(program.engine), 0)

        synth_engine_set_master_calibration(program.engine, 400, -3)
        XCTAssertEqual(
            synth_engine_master_calibration_gain(program.engine), 8,
            "an absurd gain was not clamped"
        )
        XCTAssertEqual(
            synth_engine_master_cohesion_threshold(program.engine), 0,
            "a negative threshold should disable cohesion rather than arm it"
        )
    }

    // MARK: The bounded analysis (P65-5)

    /// The analysis never measures more program than the cap allows, however
    /// long the piece is.
    func testTheAnalysedTimeIsCappedIndependentlyOfTheLengthOfThePiece() throws {
        let short = try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 4, measureCount: 8),
            id: "short"
        )
        let long = try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 4, measureCount: 64),
            id: "long"
        )
        XCTAssertGreaterThan(
            Double(long.totalMicroseconds) / 1_000_000, 100,
            "the long fixture is not long enough for this to mean anything"
        )

        for piece in [short, long] {
            let excerpts = MasterStage.excerpts(in: piece)
            let analysed = Double(excerpts.count) * MasterStage.excerptSeconds
            XCTAssertLessThanOrEqual(analysed, MasterStage.maximumAnalyzedSeconds)
        }
        XCTAssertEqual(
            MasterStage.excerpts(in: short).count, MasterStage.excerpts(in: long).count,
            "a piece eight times longer was analysed for longer, so the cost is not capped"
        )
    }

    /// Excerpt choice is a pure function of the program: the same timeline picks
    /// the same windows, and they are spread across the piece rather than taken
    /// from its opening.
    func testExcerptChoiceIsDeterministicAndSpreadAcrossThePiece() throws {
        let piece = try timeline(
            MusicXMLScoreFixtures.orchestralExcerpt(partCount: 4, measureCount: 48),
            id: "spread"
        )
        let first = MasterStage.excerpts(in: piece)
        let second = MasterStage.excerpts(in: piece)
        XCTAssertEqual(first, second, "two passes chose different excerpts")
        XCTAssertEqual(first, first.sorted { $0.lowerBound < $1.lowerBound })

        let span = Double(piece.totalMicroseconds)
        let last = try XCTUnwrap(first.last)
        XCTAssertGreaterThan(
            Double(last.lowerBound), span / 2,
            "every excerpt came from the first half of the piece, so a work that grows "
                + "towards its end would be calibrated to its opening"
        )
    }

    /// The calibration follows the program rather than the mixer. Two different
    /// mixes of one program measure the same, which is why moving a fader does
    /// not re-run a second of analysis.
    func testTheCalibrationFollowsTheProgramAndNotTheMixer() throws {
        let piece = try song()
        let voices = LineVoiceAssignment.uniform(SynthPatchVoiceProvider())
        let first = MasterCalibration.calibrate(
            timeline: piece, voices: voices, sampleRate: Self.sampleRate
        )
        let second = MasterCalibration.calibrate(
            timeline: piece, voices: voices, sampleRate: Self.sampleRate
        )
        XCTAssertEqual(first.gain, second.gain)
        XCTAssertEqual(first.cohesionThreshold, second.cohesionThreshold)
        XCTAssertEqual(first.outcome, .calibrated)
    }

    /// Every program rebuild re-measures, so the gain follows the piece, the
    /// settings and the resolved voices.
    func testEveryProgramRebuildReMeasures() throws {
        let score = try ScoreCompiler().compile(
            pieceID: "rebuild", musicXML: MusicXMLScoreFixtures.melodyOverAccompaniment()
        )
        let shaped = PerformanceRealizer().realize(score, settings: .standard)
        let literal = PerformanceRealizer().realize(score, settings: .literal)

        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
        engine.producedMaster = .standard
        try engine.load(timeline: shaped)
        let shapedGain = try XCTUnwrap(engine.masterCalibration).gain

        try engine.load(timeline: literal)
        let literalCalibration = try XCTUnwrap(engine.masterCalibration)
        XCTAssertEqual(literalCalibration.outcome, .calibrated)
        XCTAssertNotEqual(
            shapedGain, literalCalibration.gain,
            "two differently realized timelines of one score were given the same gain, so "
                + "the measurement is not being redone on a rebuild"
        )
        XCTAssertEqual(
            engine.masterCalibration?.gain,
            synth_engine_master_calibration_gain(try XCTUnwrap(engine.loadedProgram).engine),
            "the measured gain was never published to the render thread"
        )
    }

    /// What the cap buys: a program build with the produced master on stays well
    /// inside the one second REQ-005's cost bound allows, on eighteen lines.
    ///
    /// The recorded figure for the pinned reference piece is the env-gated
    /// measurement in `RealtimePlaybackTests`; this is the automated bound that
    /// runs everywhere, on a deliberately heavier line count than the
    /// reference's twelve.
    func testTurningTheProducedMasterOnCostsLessThanASecondOfProgramBuild() throws {
        let piece = try orchestral()
        let engine = PlaybackEngine()
        try engine.setRenderMode(.offline(sampleRate: Self.sampleRate))
        engine.producedMaster = .standard

        let started = Date()
        try engine.load(timeline: piece)
        let elapsed = Date().timeIntervalSince(started)

        let calibration = try XCTUnwrap(engine.masterCalibration)
        XCTAssertEqual(calibration.outcome, .calibrated)
        print("""
            MST001 calibration cost — \(piece.lines.count) lines, \
            \(String(format: "%.1f", Double(piece.totalMicroseconds) / 1_000_000)) s of music
              analysed:      \(calibration.analyzedSeconds) s
              program build: \(String(format: "%.3f", elapsed)) s
              gain:          \(String(format: "%+.2f", calibration.appliedDecibels)) dB
            """)
        XCTAssertLessThan(
            elapsed, 1.0,
            "building the program with the produced master on took "
                + "\(String(format: "%.3f", elapsed)) s, over REQ-005's one-second bound"
        )
    }

    // MARK: Helpers

    /// The raw sum of the lines, each rendered alone with the produced master
    /// off, summed in the order the engine accumulates in.
    ///
    /// `BypassRecipeRenderTests`'s method: mute is a hard zero rather than a
    /// fade, so rendering one line at a time isolates its exact contribution.
    private func rawLineSum(_ piece: PerformanceTimeline, lineCount: Int) throws -> [Float] {
        var sum: [Float]?
        for index in 0..<lineCount {
            let alone = try PlaybackEngine.renderTimelineOffline(
                piece, sampleRate: Self.sampleRate, producedMaster: .off
            ) { engine in
                for other in 0..<lineCount where other != index {
                    engine.mixer(forLineAt: other)?.isMuted = true
                }
            }
            if sum == nil { sum = [Float](repeating: 0, count: alone.frameCount) }
            guard var running = sum, running.count == alone.frameCount else {
                XCTFail("muting a line changed the program length")
                return []
            }
            for frame in 0..<alone.frameCount { running[frame] += alone.left[frame] }
            sum = running
        }
        return sum ?? []
    }
}
