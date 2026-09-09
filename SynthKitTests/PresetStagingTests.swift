import XCTest
@testable import SynthKit

/// Issue #57 (STG002): staging defaults at preset creation.
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

    func testASoloLineSitsCentred() {
        let mixer = PresetStaging.mixer(lineIndex: 0, lineCount: 1, family: nil)
        XCTAssertEqual(mixer.pan, 0)
        XCTAssertGreaterThan(mixer.roomSend, 0)
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
    func testStagedValuesAreAlwaysStorable() throws {
        for count in 1...20 {
            for index in 0..<count {
                for family in InstrumentCoverage.Family.allCases {
                    let mixer = PresetStaging.mixer(
                        lineIndex: index, lineCount: count, family: family
                    )
                    XCTAssertTrue((0...1).contains(mixer.roomSend))
                    XCTAssertTrue((0...1).contains(mixer.depth))
                    XCTAssertTrue((-1...1).contains(mixer.pan))
                    XCTAssertTrue((0...LineMixerState.maximumVolume).contains(mixer.volume))
                }
            }
        }
    }

    /// REQ-004 composition for increment 001, proven through the real engine:
    /// staging values returned to neutral render byte-identically to an
    /// engine that was never staged.
    func testNeutralStagingRestoresThePreFeatureRender() throws {
        let timeline = try AudioRenderFixtures.timeline(AudioRenderFixtures.twoLineFixture())

        let untouched = try PlaybackEngine.renderTimelineOffline(timeline)
        let stagedThenNeutral = try PlaybackEngine.renderTimelineOffline(timeline) { engine in
            for index in 0..<2 {
                guard let strip = engine.mixer(forLineAt: index) else { continue }
                let staged = PresetStaging.mixer(lineIndex: index, lineCount: 2, family: .strings)
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
