import Foundation
import XCTest
@testable import SynthKit

/// Shared helpers for the audio suites: building timelines, rendering them, and
/// reading the result back as numbers.
///
/// Analysis lives here rather than inside a test because every acceptance claim
/// about audio in this leaf is a measurement. A test that says "the line is
/// muted" and asserts a boolean has proved nothing about what came out of the
/// engine; these functions are what let each one assert an energy, an onset
/// time, or a digest instead.
enum AudioRenderFixtures {
    static let compiler = ScoreCompiler()
    static let realizer = PerformanceRealizer()

    static func timeline(
        _ musicXML: Data,
        settings: RealizationSettings = .literal,
        pieceID: String = "audio-fixture"
    ) throws -> PerformanceTimeline {
        realizer.realize(try compiler.compile(pieceID: pieceID, musicXML: musicXML), settings: settings)
    }

    /// A short two-line score with the lines an octave and a half apart, so a
    /// per-line mixer change is visible in the rendered spectrum.
    ///
    /// Deliberately tiny: the mixer criteria are about arithmetic on a mix, and
    /// a 4-second fixture makes a failure readable where a symphony would not.
    static func twoLineFixture() -> Data {
        ScoreXML.Score(
            workTitle: "Two Lines",
            composer: "Fixture",
            parts: [
                ScoreXML.Part(
                    id: "P1",
                    name: "Upper",
                    measures: (0..<2).map { measureIndex in
                        ScoreXML.Measure(
                            number: String(measureIndex + 1),
                            items: (measureIndex == 0
                                ? [ScoreXML.Item.attributes(
                                    ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4), clefs: [("G", 2)])
                                  ),
                                  ScoreXML.Item.direction(
                                    ScoreXML.Direction(words: "Andante", sound: ["tempo": "120"])
                                  )]
                                : [])
                                + (0..<4).map { _ in
                                    ScoreXML.Item.note(
                                        ScoreXML.Note(pitch: "A5", duration: 4, type: "quarter")
                                    )
                                }
                        )
                    }
                ),
                ScoreXML.Part(
                    id: "P2",
                    name: "Lower",
                    measures: (0..<2).map { measureIndex in
                        ScoreXML.Measure(
                            number: String(measureIndex + 1),
                            items: (measureIndex == 0
                                ? [ScoreXML.Item.attributes(
                                    ScoreXML.Attributes(divisions: 4, fifths: 0, time: (4, 4), clefs: [("F", 4)])
                                  )]
                                : [])
                                + (0..<4).map { _ in
                                    ScoreXML.Item.note(
                                        ScoreXML.Note(pitch: "A2", duration: 4, type: "quarter")
                                    )
                                }
                        )
                    }
                )
            ]
        ).data()
    }

    // MARK: Analysis

    /// Note onsets in the rendered audio, in microseconds.
    ///
    /// Detected as peaks in the rise of a short-window RMS envelope — the
    /// standard energy-flux approach — rather than as threshold crossings.
    /// That distinction is not fussiness: the built-in voice has a 220 ms
    /// release, so at any normal tempo a note is still ringing when the next
    /// one starts and the signal never returns below a fixed threshold between
    /// them. A crossing detector silently misses every onset after the first,
    /// which is precisely the kind of failure that would make this suite agree
    /// with a broken engine.
    static func detectedOnsetsMicroseconds(
        _ audio: PlaybackEngine.RenderedAudio,
        risingThreshold: Double = 0.004,
        minimumSeparationMicroseconds: Int64 = 60_000
    ) -> [Int64] {
        let samples = audio.left
        guard samples.count > 1024 else { return [] }

        let hop = 128
        let window = 256
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / hop)

        var start = 0
        while start + window <= samples.count {
            var total = 0.0
            for index in start..<(start + window) {
                total += Double(samples[index]) * Double(samples[index])
            }
            envelope.append((total / Double(window)).squareRoot())
            start += hop
        }
        guard envelope.count > 3 else { return [] }

        // Positive difference only: a note starting is a rise in energy, a note
        // ending is not an event this needs to see.
        var flux = [Double](repeating: 0, count: envelope.count)
        for index in 1..<envelope.count {
            flux[index] = max(0, envelope[index] - envelope[index - 1])
        }

        var onsets: [Int64] = []
        var lastOnset: Int64?

        for index in 1..<(flux.count - 1) {
            guard flux[index] > risingThreshold else { continue }
            // Local maximum, so one attack yields one onset rather than a run.
            guard flux[index] >= flux[index - 1], flux[index] >= flux[index + 1] else { continue }

            // Report where the rise began, not where it peaked: the peak sits
            // partway up the voice's attack.
            var frame = index
            while frame > 0 && flux[frame - 1] > risingThreshold * 0.25 { frame -= 1 }

            let microseconds = Int64(Double(frame * hop) * 1_000_000.0 / audio.sampleRate)
            let farEnoughFromPrevious =
                lastOnset.map { microseconds - $0 >= minimumSeparationMicroseconds } ?? true
            if farEnoughFromPrevious {
                onsets.append(microseconds)
                lastOnset = microseconds
            }
        }
        return onsets
    }

    /// Energy of `audio` in a narrow band around `frequency`, by direct
    /// correlation with a complex sinusoid.
    ///
    /// A single-bin Goertzel-style probe rather than a full FFT: every question
    /// here is "how much of this one pitch is present?", and answering exactly
    /// that keeps the assertion legible.
    static func energy(
        _ samples: [Float],
        atHertz frequency: Double,
        sampleRate: Double
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        let step = 2 * Double.pi * frequency / sampleRate
        for (index, sample) in samples.enumerated() {
            let phase = step * Double(index)
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(ratio) }

    /// Concert pitch of a MIDI note number.
    static func frequency(ofMIDINote note: Int) -> Double {
        440 * pow(2, (Double(note) - 69) / 12)
    }

    /// True when no output device exists, so a device-dependent test can skip
    /// with a reason rather than fail.
    ///
    /// CI runs headless: real-time playback there would be asserting against
    /// hardware that is not present, which is exactly the kind of test that
    /// looks green for the wrong reason.
    static var hasOutputDevice: Bool {
        !AudioOutputDeviceCatalog.outputDevices().isEmpty
    }
}
