import XCTest
@testable import SynthKit

/// Playability claims about the shipped collection that `ShippedSoundCollectionTests`
/// does not make: those prove the sounds are present, audible, distinct and
/// inside the limiter. These prove they *behave* like instruments a score can
/// be played on.
///
/// Three things a classical score asks of every sound, measured by rendering:
///
/// * **It answers to dynamics.** A *p* and an *f* have to differ in loudness,
///   and — the thing Carlos asked Moog for a touch-sensitive keyboard to get —
///   usually in brightness too. A sound whose velocity does nothing flattens
///   every hairpin PLY002 realises.
/// * **It stops when the note stops.** A release tail that is still audible
///   two seconds after a staccato quaver smears counterpoint; a fugue voice
///   has to get out of the way of the next entry.
/// * **It sits level with the others.** The collection is auditioned by
///   switching a line between sounds, and a sound three times louder than its
///   neighbour is heard as a mixing fault before it is heard as a timbre.
///
/// The numbers are printed as a table for every sound, so a change to one is
/// read as "this got quieter than the rest" and not as a bare threshold miss.
final class ShippedSoundAuditTests: XCTestCase {
    private let sampleRate = 48_000.0
    private var collection: [SoundEntry] { ShippedSoundCollection.standard.sounds }

    private struct Measurement {
        let name: String
        let loudestRMS: Double
        let softLoudRatio: Double
        let softLoudCentroidRatio: Double
        let tailSeconds: Double
        let centroidHertz: Double
    }

    private func measure(_ sound: SoundEntry) -> Measurement {
        let loud = SynthVoiceHarness.renderNote(
            patch: sound.patch, midiNoteNumber: 60, velocity: 120,
            holdSeconds: 1.5, tailSeconds: 4.0, sampleRate: sampleRate
        )
        let soft = SynthVoiceHarness.renderNote(
            patch: sound.patch, midiNoteNumber: 60, velocity: 40,
            holdSeconds: 1.5, sampleRate: sampleRate
        )
        let heldLoud = Array(loud[0..<Int(1.5 * sampleRate)])
        let loudLevel = Self.loudestWindowRMS(heldLoud, seconds: 0.2, sampleRate: sampleRate)
        let softLevel = Self.loudestWindowRMS(soft, seconds: 0.2, sampleRate: sampleRate)

        let loudCentroid = Self.spectralCentroid(
            Array(heldLoud[Int(0.3 * sampleRate)..<Int(1.3 * sampleRate)]), sampleRate: sampleRate
        )
        let softCentroid = Self.spectralCentroid(
            Array(soft[Int(0.3 * sampleRate)..<Int(1.3 * sampleRate)]), sampleRate: sampleRate
        )

        // How long after the release the sound is still above -60 dBFS RMS,
        // relative to its own held level.
        let tail = Array(loud[Int(1.5 * sampleRate)...])
        let floor = loudLevel * 0.001
        var tailSeconds = 0.0
        let window = Int(0.05 * sampleRate)
        var start = 0
        while start + window <= tail.count {
            let rms = AudioRenderFixtures.rms(
                tail, from: Double(start) / sampleRate,
                to: Double(start + window) / sampleRate, sampleRate: sampleRate
            )
            if rms > floor { tailSeconds = Double(start + window) / sampleRate }
            start += window
        }

        return Measurement(
            name: sound.name,
            loudestRMS: loudLevel,
            softLoudRatio: loudLevel > 0 ? softLevel / loudLevel : 1,
            softLoudCentroidRatio: loudCentroid > 0 ? softCentroid / loudCentroid : 1,
            tailSeconds: tailSeconds,
            centroidHertz: loudCentroid
        )
    }

    func testEveryShippedSoundAnswersToDynamicsStopsWhenReleasedAndSitsLevel() throws {
        let measurements = collection.map(measure)

        print(String(format: "%-22@ %9@ %9@ %9@ %8@ %9@",
                     "shipped sound" as NSString, "RMS@120" as NSString, "p/f lvl" as NSString,
                     "p/f brt" as NSString, "tail s" as NSString, "centroid" as NSString))
        for m in measurements {
            print(String(format: "%-22@ %9.4f %9.3f %9.3f %8.2f %9.0f",
                         m.name as NSString, m.loudestRMS, m.softLoudRatio,
                         m.softLoudCentroidRatio, m.tailSeconds, m.centroidHertz))
        }

        let levels = measurements.map(\.loudestRMS).sorted()
        let median = levels[levels.count / 2]
        let spread = levels[levels.count - 1] / levels[0]
        print(String(format: "median RMS@120 %.4f  spread %.2fx", median, spread))
        // Loudest to quietest across the whole collection. Three is a fader
        // move of ten decibels, which is where "switch the sound" stops
        // feeling like a timbre choice and starts feeling like a mix change.
        XCTAssertLessThan(spread, 3.0, "The collection's levels have drifted apart")

        for m in measurements {
            // A *p* at velocity 40 against an *f* at 120. With the default
            // velocity exponent of 1.6 the amplitude ratio alone is 0.17;
            // anything above 0.6 means the sound is barely listening.
            XCTAssertLessThan(m.softLoudRatio, 0.6, "\(m.name) barely answers to velocity")
            XCTAssertGreaterThan(m.softLoudRatio, 0.02, "\(m.name) is inaudible at piano")

            // Stops within four seconds of release for everything, and within
            // two for anything that is not a pad or a bell. A tail is an
            // effect's — a reverb or a delay — and those ring on in a hall,
            // but a fugue voice must not.
            let pad = ["Pads", "Bells"].contains(
                collection.first { $0.name == m.name }?.category.displayName ?? "")
            XCTAssertLessThan(m.tailSeconds, pad ? 4.0 : 2.0,
                              "\(m.name) is still audible \(m.tailSeconds)s after release")

            // Level within a 3× band of the median in either direction: a
            // line switched between two sounds should not need the fader.
            XCTAssertGreaterThan(m.loudestRMS, median / 3, "\(m.name) is much quieter than the rest")
            XCTAssertLessThan(m.loudestRMS, median * 3, "\(m.name) is much louder than the rest")
        }
    }

    // MARK: The Baroque Modular group

    /// The twelve *Switched-On Bach*-style sounds exist, and every one of them
    /// keeps the group's defining convention: velocity reaches the filter, so
    /// a harder note is brighter and not merely louder.
    func testTheBaroqueModularGroupIsPresentAndTouchSensitive() throws {
        let ids = [
            "shipped.modular-harpsichord", "shipped.sinfonia-organ",
            "shipped.brandenburg-violin", "shipped.ladder-mono-lead",
            "shipped.wachet-reed", "shipped.air-flute", "shipped.cantata-trumpet",
            "shipped.continuo-bass", "shipped.modular-cello", "shipped.chorale-vox",
            "shipped.clank-box", "shipped.pizzicato-pulse"
        ]
        for id in ids {
            let sound = try XCTUnwrap(ShippedSoundCollection.standard.sound(withID: id), id)
            XCTAssertTrue(
                sound.patch.modulation.contains {
                    $0.source == .velocity && $0.amount > 0
                        && ($0.destination == .filterCutoff || $0.destination == .oscillator1Shape)
                },
                "\(sound.name) should be touch-sensitive in timbre, not only in level"
            )
        }

        let mono = try XCTUnwrap(ShippedSoundCollection.standard.sound(withID: "shipped.ladder-mono-lead"))
        XCTAssertEqual(mono.patch.maximumVoices, 1, "The mono lead is the album's one-note constraint")
    }

    // MARK: Helpers

    /// Amplitude-weighted mean frequency of the spectrum, up to 8 kHz, from
    /// 64 Goertzel bins. A brightness number, not a precise one: two sounds
    /// whose centroids differ by a factor of two sound different, and that is
    /// the resolution needed here.
    private static func spectralCentroid(_ samples: [Float], sampleRate: Double) -> Double {
        var weighted = 0.0
        var total = 0.0
        for bin in 1...64 {
            let hertz = Double(bin) * 125.0
            let energy = AudioRenderFixtures.energy(samples, atHertz: hertz, sampleRate: sampleRate)
            weighted += hertz * energy
            total += energy
        }
        return total > 0 ? weighted / total : 0
    }

    private static func loudestWindowRMS(
        _ samples: [Float], seconds: Double, sampleRate: Double
    ) -> Double {
        let window = Int(seconds * sampleRate)
        guard samples.count >= window, window > 0 else { return 0 }
        let hop = max(1, window / 4)
        var loudest = 0.0
        var start = 0
        while start + window <= samples.count {
            var sum = 0.0
            for index in start..<(start + window) {
                sum += Double(samples[index]) * Double(samples[index])
            }
            loudest = max(loudest, (sum / Double(window)).squareRoot())
            start += hop
        }
        return loudest
    }
}
