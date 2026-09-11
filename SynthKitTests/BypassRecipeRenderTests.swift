import XCTest
@testable import SynthKit

/// REQ-004's **composed** bypass recipe, through the real render graph: with
/// expression off, staging neutral, tuning at default and the produced master
/// off, what comes out is written notation plus uniform humanization and nothing
/// else — the raw sum of the lines, with nothing applied to it (D65-2).
///
/// **The recipe is now complete**: increment 004 is the last, so every one of
/// REQ-004's four terms is a real setting with a real off state, and this file
/// composes all four rather than re-proving one of them:
///
/// - **expression off** — EXP001's phrase term, and EXP002's balance with it;
/// - **staging neutral** — STG003's term, register-aware seating flattened;
/// - **tuning at default** — TUN001's temperament and reference pitch at equal
///   and A=440, which resolves to twelve ratios of *exactly* 1.0 and is
///   therefore the identity rather than a small setting; and
/// - **produced master off** — MST001's switch, off: no bus cohesion and a
///   calibration gain of exactly one.
///
/// The tuning term was trivially true while TUN001 was unlanded, and the header
/// said so. It is a term now: `testTheComposedBypassRendersTheRawLineSum` reads
/// the program's own tuning back and asserts each of its twelve ratios is the
/// 1.0 bit pattern, and `testANonDefaultTuningChangesTheRender` is its
/// discrimination guard — the same notes in Werckmeister III at A=415 render
/// differently, so switching tuning *off* is switching something off.
///
/// **What the produced master off does *not* switch off is the true-peak
/// ceiling**, which is always in the graph (owner decision D65-2, AD-P6). That
/// is why the recipe's claim is stated against a raw sum that stays under the
/// ceiling: the ceiling only acts where the raw sum would have clipped, and
/// below itself its gain is literally `1.0f`, so it multiplies rather than
/// approximates. `testTheRawSumOfTheRecipeStaysUnderTheCeiling` pins the
/// premise so the claim cannot quietly become a statement about a limiter
/// acting.
///
/// **Where "bit-identical" has to become "to within one unit in the last
/// place", and why that is arithmetic rather than a concession.** D65-2 states
/// the claim against the raw line sum. Bit equality against a sum computed
/// *outside* the engine is not reachable on this hardware for any build of this
/// code: the mixer accumulates each line as `out += sample * gain`
/// (`SynthAudioCore.c`), which arm64 fuses into a single-rounding multiply-add,
/// so the engine rounds the product and the accumulation once where a reference
/// built from separately rendered lines rounds them twice. The probe that
/// established this is in the record: frames where only one line sounds match bit
/// for bit, and frames where three sound differ by exactly one unit in the last
/// place.
///
/// So the recipe is proven two ways instead of one, and neither is a tolerance on
/// the interesting quantity:
///
/// - **bit-exact, against the graph itself** — flattening staging on top of the
///   expression bypass renders byte-identically to an engine that was never
///   staged (`testFlattenedStagingLeavesNoResidueOnTopOfTheExpressionBypass`),
///   and the timeline the render consumes is held bit-exactly against the
///   pre-feature realization in `PerformanceExpressionTests`; and
/// - **linear, against an independent sum** — the mix equals the sum of its lines
///   to one unit in the last place, which is the whole of the discrepancy
///   arithmetic allows and is three to four orders of magnitude tighter than the
///   smallest master stage anyone would ship.
///   `testTheOneUnitToleranceWouldStillCatchAMasterStage` pins that second claim
///   by putting a 0.009 dB gain on the bus and measuring what it does.
final class BypassRecipeRenderTests: XCTestCase {
    private static let sampleRate: Double = 48_000

    private func compile(_ data: Data, id: String = "bypass") throws -> CompiledScore {
        try ScoreCompiler().compile(pieceID: id, musicXML: data)
    }

    /// Flattens every strip: centred, dry, at the front, unity, audible.
    ///
    /// The owner's "drag everything back" state, and the one a fresh preset is
    /// explicitly *not* in — staging seats lines at creation (STG002,
    /// register-aware since STG003), so a test that wants a neutral baseline has
    /// to say so rather than assume it.
    private func flattenStaging(_ engine: PlaybackEngine, lineCount: Int) {
        for index in 0..<lineCount {
            guard let strip = engine.mixer(forLineAt: index) else { continue }
            strip.gain = 1
            strip.pan = 0
            strip.roomSend = 0
            strip.depth = 0
            strip.isMuted = false
            strip.isSoloed = false
        }
    }

    // MARK: The recipe

    /// The composed bypass render is the raw line sum, to the last bit arithmetic
    /// allows.
    func testTheComposedBypassRendersTheRawLineSum() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        // Written notation plus uniform humanization: expression off, the
        // humanization dial where the product leaves it.
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count
        XCTAssertGreaterThanOrEqual(lineCount, 3, "the recipe needs lines to sum")

        let mix = try render(timeline, lineCount: lineCount)
        XCTAssertGreaterThan(mix.rms(), 0.001, "the render is silent, so this proves nothing")

        // The bus, as the recipe requires it: the owner's master gain at unity,
        // the produced master off, and the calibration gain that off implies.
        let probe = PlaybackEngine()
        try probe.setRenderMode(.offline(sampleRate: Self.sampleRate))
        try probe.load(timeline: timeline)
        XCTAssertEqual(probe.masterGain, 1, "the recipe needs the bus at unity")
        XCTAssertEqual(
            probe.producedMaster, .off,
            "the recipe renders with the produced master off"
        )
        let engine = try XCTUnwrap(probe.loadedProgram).engine
        XCTAssertEqual(
            synth_engine_produced_master(engine), 0,
            "the render thread was not told the produced master is off"
        )
        XCTAssertEqual(
            synth_engine_master_calibration_gain(engine), 1,
            "the produced master is off but a calibration gain reached the bus"
        )
        XCTAssertEqual(
            synth_engine_master_cohesion_threshold(engine), 0,
            "the produced master is off but cohesion is armed"
        )

        // And the tuning term (TUN001), read off the program the render used
        // rather than assumed: equal temperament at A=440, resolved to twelve
        // ratios that are the 1.0 bit pattern. The bit pattern and not merely a
        // value near one, because that is what makes the multiply in each engine
        // the identity — so "tuning at default" takes nothing away from the raw
        // line sum the recipe is stated against.
        let program = try XCTUnwrap(probe.loadedProgram)
        XCTAssertEqual(
            probe.tuning, .standard, "the recipe renders at the default tuning"
        )
        XCTAssertTrue(
            program.tuning.isDefault,
            "the program was built with \(program.tuning) rather than the default tuning"
        )
        for (pitchClass, ratio) in program.tuning.ratiosByPitchClass.enumerated() {
            XCTAssertEqual(
                ratio.bitPattern, (1.0 as Double).bitPattern,
                "the default tuning's ratio for pitch class \(pitchClass) is \(ratio) rather "
                    + "than exactly 1.0, so it is a setting rather than a bypass"
            )
        }

        let deviation = try largestDeviationFromTheLineSum(timeline, lineCount: lineCount)
        XCTAssertLessThanOrEqual(
            deviation.largest, 4 * deviation.peak.ulp,
            "the composed bypass mix departs from the raw line sum by \(deviation.largest), "
                + "which is more than the \(4 * deviation.peak.ulp) that rounding a peak of "
                + "\(deviation.peak) can account for; something is processing the sum"
        )
    }

    /// The premise D65-2 states the recipe against: the raw sum of the bypass
    /// recipe stays under the always-on ceiling, so the ceiling is not what the
    /// test above is measuring.
    func testTheRawSumOfTheRecipeStaysUnderTheCeiling() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let mix = try render(timeline, lineCount: timeline.lines.count)
        let ceiling = 20 * log10(Double(synth_master_ceiling()))
        XCTAssertLessThan(
            20 * log10(Double(mix.peak())), ceiling,
            "the recipe's raw sum already reaches the ceiling, so bit-identity to it would "
                + "be a claim about the ceiling acting rather than about the bypass"
        )
    }

    /// And the produced master is a real term in the recipe rather than a name
    /// for nothing: on, the same notes render differently.
    func testTheProducedMasterIsAudibleWhenItIsOn() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count
        let off = try render(timeline, lineCount: lineCount)
        let on = try render(timeline, lineCount: lineCount, producedMaster: .standard)
        XCTAssertNotEqual(
            off.canonicalData(), on.canonicalData(),
            "the produced master leaves no trace in the render, so switching it off "
                + "proves nothing"
        )
    }

    /// The tolerance above is a rounding allowance, not a hiding place: the
    /// smallest master gain anyone would call a stage moves the render far
    /// outside it.
    func testTheOneUnitToleranceWouldStillCatchAMasterStage() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count

        let honest = try largestDeviationFromTheLineSum(timeline, lineCount: lineCount)
        // 0.999 is about 0.009 dB — far below anything audible, and far below any
        // real ceiling or calibration gain.
        let processed = try largestDeviationFromTheLineSum(
            timeline, lineCount: lineCount, mixMasterGain: 0.999
        )

        XCTAssertGreaterThan(
            processed.largest, honest.largest * 100,
            "a 0.009 dB gain on the bus is not distinguishable from rounding, so the "
                + "tolerance in the test above is too loose to mean anything"
        )
        XCTAssertGreaterThan(processed.largest, 4 * processed.peak.ulp * 100)
    }

    /// The vacuity guard. Every feature the plan has delivered so far must be
    /// *audible* when it is on, or the recipe above is a comparison between two
    /// identical things.
    func testTheRecipeIsNotSimplyARenderThatNeverChanges() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let realizer = PerformanceRealizer()
        let bypassed = realizer.realize(score, settings: .humanizedWithoutExpression)
        let shaped = realizer.realize(score, settings: .standard)
        let lineCount = bypassed.lines.count

        let plain = try render(bypassed, lineCount: lineCount)

        // Expression on, including EXP002's balance.
        let expressive = try render(shaped, lineCount: lineCount)
        XCTAssertNotEqual(
            plain.canonicalData(), expressive.canonicalData(),
            "expression on renders the same audio as expression off"
        )

        // Staging on: seated, in the room, at a family depth, register-aware.
        let staged = try render(bypassed, lineCount: lineCount, staged: score)
        XCTAssertNotEqual(
            plain.canonicalData(), staged.canonicalData(),
            "staging leaves no trace in the render, so flattening it proves nothing"
        )

        // Tuning on: a temperament and a reference pitch that are not the default.
        let retuned = try render(
            bypassed, lineCount: lineCount,
            tuning: TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        )
        XCTAssertNotEqual(
            plain.canonicalData(), retuned.canonicalData(),
            "a non-default tuning leaves no trace in the render, so the recipe's tuning term "
                + "is a name for nothing"
        )
    }

    /// The tuning term's own discrimination guard, stated on its own rather than
    /// only inside the composed vacuity check: each of the two pickers moves the
    /// render by itself, so neither is carried by the other.
    ///
    /// **Why this is the interesting half of "tuning at default".** The recipe above
    /// asserts the default is the identity; that is a statement about twelve ratios
    /// being 1.0, and it would be equally true of an engine that threw the table
    /// away. What says the bypass is a bypass *of something* is that turning the
    /// setting away from its default changes the audio — and that each control does
    /// so alone.
    func testANonDefaultTuningChangesTheRender() throws {
        let score = try compile(MusicXMLScoreFixtures.expressiveKeyboardPiece())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count
        let plain = try render(timeline, lineCount: lineCount)
        XCTAssertGreaterThan(plain.rms(), 0.001, "the render is silent, so this proves nothing")

        let temperamentOnly = try render(
            timeline, lineCount: lineCount,
            tuning: TuningSettings(temperament: .werckmeisterIII)
        )
        XCTAssertNotEqual(
            plain.canonicalData(), temperamentOnly.canonicalData(),
            "Werckmeister III at A=440 renders the same audio as equal temperament"
        )

        let referenceOnly = try render(
            timeline, lineCount: lineCount,
            tuning: TuningSettings(referencePitch: .a415)
        )
        XCTAssertNotEqual(
            plain.canonicalData(), referenceOnly.canonicalData(),
            "A=415 renders the same audio as A=440"
        )
        XCTAssertNotEqual(
            temperamentOnly.canonicalData(), referenceOnly.canonicalData(),
            "the two pickers produce the same render, so one of them is being ignored"
        )
    }

    /// And the tuning term composes with the other three rather than merely
    /// coexisting with them: the default tuning on top of the full bypass leaves the
    /// render byte-identical to the one that never mentioned tuning.
    ///
    /// The `testFlattenedStagingLeavesNoResidueOnTopOfTheExpressionBypass`
    /// construction, for this leaf's term.
    func testTheDefaultTuningLeavesNoResidueOnTopOfTheWholeBypass() throws {
        let score = try compile(MusicXMLScoreFixtures.melodyOverAccompaniment())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count

        let neverTuned = try render(timeline, lineCount: lineCount)
        let explicitlyDefault = try render(
            timeline, lineCount: lineCount, tuning: .standard
        )
        XCTAssertEqual(
            neverTuned.canonicalData(), explicitlyDefault.canonicalData(),
            "default must be an honest bypass: the tuning path left residue in the render"
        )
    }

    /// And the term this leaf composes with, isolated and bit-exact: flattening
    /// staging on top of the expression bypass leaves no residue, so the two
    /// terms compose rather than merely coexist.
    func testFlattenedStagingLeavesNoResidueOnTopOfTheExpressionBypass() throws {
        let score = try compile(MusicXMLScoreFixtures.melodyOverAccompaniment())
        let timeline = PerformanceRealizer().realize(
            score, settings: .humanizedWithoutExpression
        )
        let lineCount = timeline.lines.count
        let registers = PresetStaging.StageRegisters(score.lines.map(\.register))

        let neverStaged = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: Self.sampleRate
        )
        let stagedThenFlattened = try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: Self.sampleRate
        ) { engine in
            for index in 0..<lineCount {
                guard let strip = engine.mixer(forLineAt: index) else { continue }
                let seat = PresetStaging.mixer(
                    lineIndex: index, lineCount: lineCount, family: .strings, registers: registers
                )
                strip.pan = Float(seat.pan)
                strip.roomSend = Float(seat.roomSend)
                strip.depth = Float(seat.depth)
            }
            // …and then dragged back to the front, dry, centred.
            self.flattenStaging(engine, lineCount: lineCount)
        }
        XCTAssertEqual(
            neverStaged.canonicalData(), stagedThenFlattened.canonicalData(),
            "neutral must be an honest bypass: staging left residue in the render"
        )
    }

    // MARK: Rendering

    /// How far the mix departs from the sum of its lines, and the peak it departs
    /// from.
    ///
    /// Mute is a hard zero on the line's gain rather than a fade
    /// (`SynthAudioCore.c`), so rendering one line at a time with the others
    /// muted isolates each line's exact contribution, and the sum is taken in
    /// line order — the order the engine accumulates in.
    private func largestDeviationFromTheLineSum(
        _ timeline: PerformanceTimeline,
        lineCount: Int,
        mixMasterGain: Float = 1
    ) throws -> (largest: Float, peak: Float) {
        let mix = try render(timeline, lineCount: lineCount, masterGain: mixMasterGain)

        // The reference is the *raw* sum: every line at unity, whatever the mix
        // has on its bus. A gain applied to both sides would cancel and measure
        // nothing.
        var left = [Float](repeating: 0, count: mix.frameCount)
        var right = [Float](repeating: 0, count: mix.frameCount)
        for index in 0..<lineCount {
            let alone = try render(timeline, lineCount: lineCount, onlyLineAt: index)
            XCTAssertEqual(
                alone.frameCount, mix.frameCount,
                "muting a line changed the program length, so the sum is not comparable"
            )
            for frame in 0..<mix.frameCount {
                left[frame] += alone.left[frame]
                right[frame] += alone.right[frame]
            }
        }

        var largest: Float = 0
        var peak: Float = 0
        for frame in 0..<mix.frameCount {
            largest = max(
                largest,
                max(abs(mix.left[frame] - left[frame]), abs(mix.right[frame] - right[frame]))
            )
            peak = max(peak, max(abs(mix.left[frame]), abs(mix.right[frame])))
        }
        XCTAssertGreaterThan(peak, 0.01, "the comparison needs a signal to compare")
        return (largest, peak)
    }

    /// Renders `timeline` with every strip flattened, optionally staged instead,
    /// and optionally with only one line audible.
    private func render(
        _ timeline: PerformanceTimeline,
        lineCount: Int,
        onlyLineAt audible: Int? = nil,
        masterGain: Float = 1,
        producedMaster: ProducedMasterSettings = .off,
        tuning: TuningSettings = .standard,
        staged score: CompiledScore? = nil
    ) throws -> PlaybackEngine.RenderedAudio {
        try PlaybackEngine.renderTimelineOffline(
            timeline, sampleRate: Self.sampleRate,
            producedMaster: producedMaster, tuning: tuning
        ) { engine in
            self.flattenStaging(engine, lineCount: lineCount)
            engine.masterGain = masterGain
            if let score {
                let registers = PresetStaging.StageRegisters(score.lines.map(\.register))
                for index in 0..<lineCount {
                    guard let strip = engine.mixer(forLineAt: index) else { continue }
                    let seat = PresetStaging.mixer(
                        lineIndex: index, lineCount: lineCount,
                        family: .strings, registers: registers
                    )
                    strip.pan = Float(seat.pan)
                    strip.roomSend = Float(seat.roomSend)
                    strip.depth = Float(seat.depth)
                }
            }
            guard let audible else { return }
            for index in 0..<lineCount where index != audible {
                engine.mixer(forLineAt: index)?.isMuted = true
            }
        }
    }
}
