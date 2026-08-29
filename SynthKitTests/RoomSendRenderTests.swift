import XCTest
@testable import SynthKit

/// D7's per-line room send, measured in the mix rather than asserted on a
/// struct.
///
/// Three claims, and the third is the one that keeps REQ-013 honest:
///
/// 1. A send above zero puts the line into a shared hall — audible as sound
///    continuing after the note has finished.
/// 2. The hall is *shared*: two lines sent into it are in the same acoustic,
///    and a line the owner silenced is silent in it too.
/// 3. **A mix with every send at zero is bit-identical to one rendered before
///    the room existed.** The bus is skipped entirely while nothing is sent to
///    it, so a piece that does not use the room costs exactly what it did.
final class RoomSendRenderTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Two lines that each play one short note and then stop, followed by
    /// three empty bars.
    ///
    /// The silence is the measurement. A dry mix is exactly zero there; a hall
    /// is still ringing. The mixer suite's own fixture plays continuously and
    /// would leave nowhere to look.
    private static func oneNoteThenSilence() -> Data {
        func part(id: String, name: String, pitch: String) -> ScoreXML.Part {
            var measures = [
                ScoreXML.Measure(
                    number: "1",
                    items: [
                        .attributes(
                            ScoreXML.Attributes(
                                divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)]
                            )
                        ),
                        .note(ScoreXML.Note(pitch: pitch, duration: 4, type: "quarter")),
                        .note(ScoreXML.Note(pitch: nil, duration: 12, type: "half"))
                    ]
                )
            ]
            for bar in 2...4 {
                measures.append(
                    ScoreXML.Measure(
                        number: String(bar),
                        items: [.note(ScoreXML.Note(pitch: nil, duration: 16, type: "whole"))]
                    )
                )
            }
            return ScoreXML.Part(id: id, name: name, measures: measures)
        }
        return ScoreXML.Score(
            workTitle: "One Note Then Silence",
            composer: "Fixture",
            parts: [
                part(id: "P1", name: "Upper", pitch: "A4"),
                part(id: "P2", name: "Lower", pitch: "A3")
            ]
        ).data()
    }

    private func timeline() throws -> PerformanceTimeline {
        let timeline = try AudioRenderFixtures.timeline(Self.oneNoteThenSilence())
        XCTAssertEqual(timeline.lines.count, 2, "The room fixture must have exactly two lines")
        return timeline
    }

    private func render(
        _ configure: @escaping (PlaybackEngine) -> Void
    ) throws -> PlaybackEngine.RenderedAudio {
        try PlaybackEngine.renderTimelineOffline(
            try timeline(),
            sampleRate: sampleRate,
            voices: .uniform(SynthPatchVoiceProvider()),
            configure: configure
        )
    }

    /// Where the dry mix has finished: the first frame after the note and its
    /// own release are inaudible.
    ///
    /// Derived from the rendered audio rather than assumed from the tempo, so
    /// the window this suite measures in is the silence itself whatever the
    /// realizer does with the fixture.
    private lazy var tailStart: Int = {
        guard let dry = try? render({ _ in }) else { return 0 }
        let threshold: Float = 1e-4
        let last = dry.left.indices.last { abs(dry.left[$0]) > threshold || abs(dry.right[$0]) > threshold }
        return (last ?? 0) + 1
    }()

    /// Energy over the second after the dry mix has finished, where a hall is
    /// still ringing and a dry mix is exactly silent.
    private func tailEnergy(_ audio: PlaybackEngine.RenderedAudio) -> Double {
        let start = min(tailStart, audio.left.count)
        let end = min(start + Int(sampleRate), audio.left.count)
        guard start < end else { return 0 }
        return Double(
            SampledVoiceHarness.meanAbsolute(audio.left[start..<end])
                + SampledVoiceHarness.meanAbsolute(audio.right[start..<end])
        )
    }

    // MARK: The bus costs nothing until it is used

    func testAMixWithNoRoomSendIsExactlyWhatItWasBeforeTheRoomExisted() throws {
        let dry = try render { _ in }
        let alsoDry = try render { engine in
            guard let program = engine.loadedProgram else { return }
            for index in program.lineIDs.indices {
                engine.mixer(forLineAt: index)?.roomSend = 0
            }
        }

        XCTAssertEqual(
            dry.left, alsoDry.left,
            "Setting every send to zero must be the same as never touching them"
        )
        XCTAssertEqual(dry.right, alsoDry.right)
        XCTAssertLessThan(
            tailEnergy(dry), 1e-4,
            "With nothing sent to the room, the space after the notes is silent"
        )
    }

    // MARK: A send puts the line in a hall

    func testASendPutsAudibleSoundAfterTheNoteHasFinished() throws {
        let dry = try render { _ in }
        let wet = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 1
        }

        XCTAssertGreaterThan(
            tailEnergy(wet), 1e-4,
            "A full send must leave the hall ringing after the note stops"
        )
        XCTAssertGreaterThan(tailEnergy(wet), tailEnergy(dry) + 1e-5)

        // The note itself is still there: a send adds, it does not replace.
        let onset = Array(wet.left[0..<Int(0.15 * sampleRate)])
        XCTAssertGreaterThan(Double(SampledVoiceHarness.peak(onset)), 0.01)
    }

    func testMoreSendMeansMoreRoom() throws {
        let little = try render { engine in engine.mixer(forLineAt: 0)?.roomSend = 0.25 }
        let plenty = try render { engine in engine.mixer(forLineAt: 0)?.roomSend = 1 }

        XCTAssertGreaterThan(
            tailEnergy(plenty), tailEnergy(little) * 1.5,
            "The send has to be a control rather than a switch"
        )
    }

    // MARK: One hall, shared, and post-fader

    func testTwoLinesSentToTheRoomAreInTheSameHall() throws {
        let one = try render { engine in engine.mixer(forLineAt: 0)?.roomSend = 1 }
        let both = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 1
            engine.mixer(forLineAt: 1)?.roomSend = 1
        }

        XCTAssertGreaterThan(
            tailEnergy(both), tailEnergy(one),
            "A second line sending into the room must be heard in it"
        )
    }

    /// Post-fader and post-mute: silencing a line silences its reverb too.
    ///
    /// The alternative — a pre-fader send — leaves a muted line audible as its
    /// own reverb, which is the answer that surprises somebody reaching for the
    /// mute button to make a line stop.
    func testMutingALineTakesItsReverbWithIt() throws {
        let heard = try render { engine in engine.mixer(forLineAt: 0)?.roomSend = 1 }
        let muted = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 1
            engine.mixer(forLineAt: 0)?.isMuted = true
        }

        XCTAssertGreaterThan(tailEnergy(heard), 1e-4)
        XCTAssertLessThan(
            tailEnergy(muted), 1e-6,
            "A muted line must be silent in the room as well as in the mix"
        )
    }

    func testAFaderPullsItsOwnReverbDownWithIt() throws {
        let unity = try render { engine in engine.mixer(forLineAt: 0)?.roomSend = 1 }
        let quiet = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 1
            engine.mixer(forLineAt: 0)?.gain = 0.25
        }

        XCTAssertLessThan(
            tailEnergy(quiet), tailEnergy(unity) * 0.5,
            "The send is post-fader, so a quieter line is quieter in the hall"
        )
    }

    // MARK: Determinism

    func testTwoRendersOfTheSameRoomAreIdentical() throws {
        let first = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 0.7
            engine.mixer(forLineAt: 1)?.roomSend = 0.3
        }
        let second = try render { engine in
            engine.mixer(forLineAt: 0)?.roomSend = 0.7
            engine.mixer(forLineAt: 1)?.roomSend = 0.3
        }

        XCTAssertEqual(first.left, second.left)
        XCTAssertEqual(first.right, second.right)
    }

    // MARK: The preset carries it

    func testTheRoomSendSurvivesAPresetRoundTripAndReachesTheEngine() throws {
        let content = PresetContent(lines: [
            PresetLine(
                lineID: ScoreLineID(partID: "P1", staff: 1, voice: "1"),
                assignment: .library(kind: .synth, soundID: "builtin.default"),
                mixer: LineMixerState(
                    volume: 1, pan: 0, isMuted: false, isSoloed: false, roomSend: 0.6
                )
            )
        ])

        let data = try PresetDocument.data(from: content)
        let read = try PresetDocument.content(from: data)
        XCTAssertEqual(read.lines.first?.mixer.roomSend, 0.6)

        // And a send outside the engine's range is refused rather than clamped
        // behind the owner's back.
        var wrong = content
        wrong.lines[0].mixer.roomSend = 4
        XCTAssertThrowsError(try PresetDocument.data(from: wrong)) { error in
            guard case PresetDocumentError.valueOutOfRange(let name, _, _, let max) = error else {
                return XCTFail("Expected valueOutOfRange, got \(error)")
            }
            XCTAssertEqual(name, "roomSend")
            XCTAssertEqual(max, 1)
        }
    }
}
