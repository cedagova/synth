import XCTest
@testable import SynthKit

/// Issue #57 (STG002): staging defaults at preset creation.
/// Issue #71 (STG003): register-aware placement on top of them.
final class PresetStagingTests: XCTestCase {
    /// REQ-001's audible claim at the derivation level: a multi-line piece is
    /// not all centred, and every line leans into the shared room.
    func testAFourLineStageIsSpreadAndInTheRoom() throws {
        let mixers = (0..<4).map {
            PresetStaging.mixer(lineIndex: $0, lineCount: 4, family: .strings)
        }
        XCTAssertEqual(Set(mixers.map(\.pan)).count, 4, "Every seat must be distinct.")
        let first = try XCTUnwrap(mixers.first).pan
        let last = try XCTUnwrap(mixers.last).pan
        XCTAssertEqual(first, -last, accuracy: 1e-9, "The stage is symmetric.")
        XCTAssertTrue(mixers.allSatisfy { $0.roomSend > 0 }, "Staged lines share the room.")
        XCTAssertTrue(mixers.allSatisfy { $0.depth > 0 }, "Staged lines have a place in depth.")
        XCTAssertTrue(
            mixers.allSatisfy { abs($0.pan) <= PresetStaging.maximumSpread + 1e-9 },
            "No seat may leave the stage."
        )
    }

    func testASoloLineSitsCentredAtTheFrontWithRoomOnly() {
        for family in [nil, .strings, .percussion] as [InstrumentCoverage.Family?] {
            let mixer = PresetStaging.mixer(lineIndex: 0, lineCount: 1, family: family)
            XCTAssertEqual(mixer.pan, 0)
            XCTAssertGreaterThan(mixer.roomSend, 0)
            XCTAssertEqual(mixer.depth, 0, "A solo line stages centred with room only.")
        }
    }

    /// The classical stage, coarsely: strings in front of winds, winds in
    /// front of brass, percussion at the back and pulled toward the centre.
    func testFamiliesSitAtTheirStageDepths() {
        func depth(_ family: InstrumentCoverage.Family) -> Double {
            PresetStaging.mixer(lineIndex: 0, lineCount: 8, family: family).depth
        }
        XCTAssertLessThan(depth(.strings), depth(.woodwinds))
        XCTAssertLessThan(depth(.woodwinds), depth(.brass))
        XCTAssertLessThan(depth(.brass), depth(.percussion))

        let stringsSeat = PresetStaging.mixer(lineIndex: 0, lineCount: 8, family: .strings)
        let percussionSeat = PresetStaging.mixer(lineIndex: 0, lineCount: 8, family: .percussion)
        XCTAssertLessThan(
            abs(percussionSeat.pan), abs(stringsSeat.pan),
            "Percussion sits toward the centre, not on an edge seat."
        )
    }

    /// The derivation is a pure function: same inputs, same stage, always.
    func testStagingIsDeterministic() {
        for index in 0..<12 {
            XCTAssertEqual(
                PresetStaging.mixer(lineIndex: index, lineCount: 12, family: .brass),
                PresetStaging.mixer(lineIndex: index, lineCount: 12, family: .brass)
            )
        }
    }

    /// Every staged value passes the preset document's own range validation,
    /// so a fresh preset can always be stored.
    ///
    /// Checked with and without a register reading, because the register lean
    /// is the one thing that adds to a value rather than choosing it, and an
    /// out-of-range depth would be a preset the store refuses to write.
    func testStagedValuesAreAlwaysStorable() throws {
        for count in 1...20 {
            // The widest register reading this ensemble can have: one line at
            // the bottom of the MIDI scale, one at the top, the rest spread
            // between — so every bassness from 0 to 1 is exercised.
            let registers = PresetStaging.StageRegisters(
                (0..<count).map { index in
                    LineRegister(
                        medianMIDINote: count <= 1
                            ? 60
                            : 127 * index / (count - 1),
                        soundingPitchCount: 8
                    )
                }
            )
            for index in 0..<count {
                for family in InstrumentCoverage.Family.allCases {
                    for reading in [nil, registers] as [PresetStaging.StageRegisters?] {
                        let mixer = PresetStaging.mixer(
                            lineIndex: index,
                            lineCount: count,
                            family: family,
                            registers: reading
                        )
                        XCTAssertTrue((0...1).contains(mixer.roomSend))
                        XCTAssertTrue((0...1).contains(mixer.depth))
                        XCTAssertTrue((-1...1).contains(mixer.pan))
                        XCTAssertTrue((0...LineMixerState.maximumVolume).contains(mixer.volume))
                    }
                }
            }
        }
    }

    // MARK: Register-aware placement (STG003, issue #71)

    /// The acceptance claim: in a fresh ensemble whose lowest part is *not* last
    /// in score order, that part is seated right of centre and further back than
    /// the lines above it.
    ///
    /// One family throughout (a string band), deliberately: family depth is a
    /// separate axis this does not override, so holding it constant is what
    /// makes "further back" a statement about register rather than about the
    /// difference between a violin and a trombone.
    func testTheLowestLineIsSeatedRightOfCentreAndFurtherBack() throws {
        let score = try Self.compile(Self.stringBand())
        let inventory = LineInventory(score: score)
        XCTAssertEqual(inventory.entries.count, 4)
        // Score order is Violin I, Contrabass, Viola, Violin II: the bass is
        // second, so its score-order seat is left of centre.
        XCTAssertEqual(inventory.entries[1].partName, "Contrabass")

        let registers = PresetStaging.StageRegisters(inventory: inventory)
        let mixers = (0..<4).map {
            PresetStaging.mixer(
                lineIndex: $0, lineCount: 4, family: .strings, registers: registers
            )
        }

        let unbiased = PresetStaging.mixer(lineIndex: 1, lineCount: 4, family: .strings)
        XCTAssertLessThan(unbiased.pan, 0, "The fixture's bass seat must start left of centre.")

        let bass = mixers[1]
        XCTAssertGreaterThan(bass.pan, 0, "The bass line must be seated right of centre.")
        for (index, treble) in mixers.enumerated() where index != 1 {
            XCTAssertGreaterThan(
                bass.depth, treble.depth,
                "The bass line must sit further back than line \(index)."
            )
        }

        // The top two lines are at or above the register midpoint, so they keep
        // the seat score order alone gave them.
        for index in [0, 3] {
            XCTAssertEqual(
                mixers[index],
                PresetStaging.mixer(lineIndex: index, lineCount: 4, family: .strings),
                "A treble line must keep its score-order seat exactly."
            )
        }
    }

    /// A piece written in one register has no bass line to single out, so it
    /// stages byte-identically to the pre-STG003 derivation.
    func testOneRegisterStagesExactlyLikeTheFamilyOnlyDerivation() throws {
        let score = try Self.compile(Self.violinTrio())
        let inventory = LineInventory(score: score)
        let medians = inventory.entries.compactMap { $0.register?.medianMIDINote }
        XCTAssertEqual(medians.count, 3, "Every line must have a register to summarize.")
        let highest = try XCTUnwrap(medians.max())
        let lowest = try XCTUnwrap(medians.min())
        let spread = highest - lowest
        XCTAssertLessThan(
            Double(spread), PresetStaging.registerDeadbandSemitones,
            "The fixture must actually sit inside one register."
        )

        let registers = PresetStaging.StageRegisters(inventory: inventory)
        for index in 0..<3 {
            XCTAssertEqual(
                PresetStaging.mixer(
                    lineIndex: index, lineCount: 3, family: .strings, registers: registers
                ),
                PresetStaging.mixer(lineIndex: index, lineCount: 3, family: .strings),
                "A single-register piece must stage exactly as it did before STG003."
            )
        }
    }

    /// "Lines with too few pitches get the family-only result."
    func testTooFewSoundingPitchesGetsTheFamilyOnlyResult() throws {
        // The summary itself refuses to answer below the threshold.
        let notes = (0..<8).map { index in
            ScoreNote(
                sourceMeasureIndex: 0,
                startTicks: index * 480,
                durationTicks: 480,
                pitch: ScorePitch(step: "C", alter: 0, octave: 3)
            )
        }
        for count in 0..<LineRegister.minimumSoundingPitches {
            XCTAssertNil(
                LineRegister(summarizing: Array(notes.prefix(count))),
                "\(count) sounding pitches is too few to summarize."
            )
        }
        XCTAssertNotNil(LineRegister(summarizing: Array(notes.prefix(4))))

        // A rest-only line has no register even when it has plenty of events.
        let rests = (0..<16).map { index in
            ScoreNote(
                sourceMeasureIndex: 0, startTicks: index * 480, durationTicks: 480, pitch: nil
            )
        }
        XCTAssertNil(LineRegister(summarizing: rests), "Rests do not sound.")

        // And the derivation falls back to the family for that line, while the
        // lines around it are still biased.
        let registers = PresetStaging.StageRegisters([
            LineRegister(medianMIDINote: 81, soundingPitchCount: 40),
            nil,
            LineRegister(medianMIDINote: 45, soundingPitchCount: 40)
        ])
        XCTAssertEqual(
            PresetStaging.mixer(
                lineIndex: 1, lineCount: 3, family: .percussion, registers: registers
            ),
            PresetStaging.mixer(lineIndex: 1, lineCount: 3, family: .percussion),
            "A line with no register must get exactly the family-only result."
        )
        XCTAssertGreaterThan(
            PresetStaging.mixer(
                lineIndex: 2, lineCount: 3, family: .strings, registers: registers
            ).depth,
            PresetStaging.mixer(lineIndex: 2, lineCount: 3, family: .strings).depth,
            "The lines that do have a register are still placed by it."
        )
    }

    /// An ensemble whose registers are only arguably separate leans a little
    /// rather than jumping to an extreme seat — the definition's stated edge
    /// behavior for an ambiguous register.
    func testAnAmbiguousRegisterSpreadLeansLessThanAClearOne() {
        func bassPan(lowestMedian: Int) -> Double {
            let registers = PresetStaging.StageRegisters([
                LineRegister(medianMIDINote: 72, soundingPitchCount: 40),
                LineRegister(medianMIDINote: lowestMedian, soundingPitchCount: 40)
            ])
            return PresetStaging.mixer(
                lineIndex: 1, lineCount: 2, family: .strings, registers: registers
            ).pan
        }

        let seat = PresetStaging.mixer(lineIndex: 1, lineCount: 2, family: .strings).pan
        XCTAssertEqual(bassPan(lowestMedian: 63), seat, "Inside one register: no bias at all.")
        let ambiguous = bassPan(lowestMedian: 54)   // 18 semitones: half-way up the ramp
        let clear = bassPan(lowestMedian: 42)       // 30 semitones: past the ramp
        XCTAssertLessThan(seat, ambiguous)
        XCTAssertLessThan(ambiguous, clear)
    }

    /// The derivation stays a pure function once register is one of its inputs:
    /// the same score summarizes to the same registers and stages the same
    /// seats, every time.
    func testRegisterAwareStagingIsDeterministic() throws {
        let first = LineInventory(score: try Self.compile(Self.stringBand()))
        let second = LineInventory(score: try Self.compile(Self.stringBand()))
        XCTAssertEqual(
            first.entries.map(\.register), second.entries.map(\.register),
            "The same bytes must summarize to the same registers."
        )

        let registers = PresetStaging.StageRegisters(inventory: first)
        XCTAssertEqual(registers, PresetStaging.StageRegisters(inventory: second))
        for index in 0..<first.entries.count {
            XCTAssertEqual(
                PresetStaging.mixer(
                    lineIndex: index, lineCount: 4, family: .strings, registers: registers
                ),
                PresetStaging.mixer(
                    lineIndex: index,
                    lineCount: 4,
                    family: .strings,
                    registers: PresetStaging.StageRegisters(inventory: second)
                )
            )
        }
    }

    /// A solo piece keeps its existing contract — centred, at the front, room
    /// only — however low it is written.
    func testASoloLowLineStaysCentredAtTheFront() {
        let registers = PresetStaging.StageRegisters([
            LineRegister(medianMIDINote: 36, soundingPitchCount: 60)
        ])
        let mixer = PresetStaging.mixer(
            lineIndex: 0, lineCount: 1, family: .strings, registers: registers
        )
        XCTAssertEqual(mixer.pan, 0)
        XCTAssertEqual(mixer.depth, 0)
    }

    // MARK: Fixtures

    /// A string band in score order Violin I, Contrabass, Viola, Violin II —
    /// one family, four notes a line, and the lowest part deliberately second
    /// rather than last.
    private static func stringBand() -> Data {
        band(
            titled: "String Band",
            parts: [
                ("P1", "Violin I", ["A5", "B5", "C6", "G5"]),
                ("P2", "Contrabass", ["A2", "B2", "C3", "G2"]),
                ("P3", "Viola", ["C4", "D4", "E4", "A3"]),
                ("P4", "Violin II", ["E5", "F5", "G5", "D5"])
            ]
        )
    }

    /// Three violins inside one register: nothing for register to separate.
    private static func violinTrio() -> Data {
        band(
            titled: "Violin Trio",
            parts: [
                ("P1", "Violin I", ["A5", "B5", "C6", "G5"]),
                ("P2", "Violin II", ["E5", "F5", "G5", "A5"]),
                ("P3", "Violin III", ["D5", "E5", "F5", "G5"])
            ]
        )
    }

    private static func band(
        titled title: String, parts: [(id: String, name: String, pitches: [String])]
    ) -> Data {
        ScoreXML.Score(
            workTitle: title,
            composer: "Fixture",
            parts: parts.map { part in
                ScoreXML.Part(id: part.id, name: part.name, measures: [
                    ScoreXML.Measure(number: "1", items:
                        [.attributes(ScoreXML.Attributes(
                            divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                        ))]
                        + part.pitches.map {
                            .note(ScoreXML.Note(pitch: $0, duration: 4, type: "quarter"))
                        }
                    )
                ])
            }
        ).data()
    }

    private static func compile(_ musicXML: Data) throws -> CompiledScore {
        try ScoreCompiler().compile(pieceID: "staging-fixture", musicXML: musicXML)
    }

    /// REQ-004 composition for increment 001, proven through the real engine:
    /// staging values returned to neutral render byte-identically to an
    /// engine that was never staged.
    ///
    /// Staged *with* a register reading since STG003, so the values that pass
    /// through the engine before the owner flattens them are the register-biased
    /// ones — a bypass that only held for the family-only derivation would not
    /// be the bypass this increment has to keep.
    func testNeutralStagingRestoresThePreFeatureRender() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())
        let registers = PresetStaging.StageRegisters([
            LineRegister(medianMIDINote: 79, soundingPitchCount: 40),
            LineRegister(medianMIDINote: 43, soundingPitchCount: 40)
        ])

        XCTAssertNotEqual(
            PresetStaging.mixer(
                lineIndex: 1, lineCount: 2, family: .strings, registers: registers
            ),
            PresetStaging.mixer(lineIndex: 1, lineCount: 2, family: .strings),
            "The fixture must actually exercise the register bias."
        )

        let untouched = try PlaybackEngine.renderTimelineOffline(timeline)
        let stagedThenNeutral = try PlaybackEngine.renderTimelineOffline(timeline) { engine in
            for index in 0..<2 {
                guard let strip = engine.mixer(forLineAt: index) else { continue }
                let staged = PresetStaging.mixer(
                    lineIndex: index, lineCount: 2, family: .strings, registers: registers
                )
                strip.pan = Float(staged.pan)
                strip.roomSend = Float(staged.roomSend)
                strip.depth = Float(staged.depth)
                // The owner drags everything back to the front, dry, centred.
                strip.pan = 0
                strip.roomSend = 0
                strip.depth = 0
            }
        }
        XCTAssertEqual(
            untouched.canonicalData(), stagedThenNeutral.canonicalData(),
            "Neutral must be an honest bypass: staging left residue in the render."
        )
    }
}
