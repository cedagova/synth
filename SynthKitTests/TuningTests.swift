import XCTest
@testable import SynthKit
#if canImport(SynthAudioCore)
import SynthAudioCore
#endif

/// The tuning model: the published tables, the anchor, the ratios they resolve
/// to, and what a stored document can and cannot make of them (TUN001, REQ-006).
///
/// **What is measured here and what is measured next door.** This file is about
/// numbers that can be checked against a book and against arithmetic — that
/// Werckmeister III's degrees are Werckmeister's, that the default is exactly the
/// identity, that an unknown name degrades the way REQ-006 says. Whether the
/// *audio* actually comes out at those frequencies is a different claim and it is
/// made in `TuningRenderTests`, from rendered samples, through both engines.
final class TuningTests: XCTestCase {

    // MARK: The published tables

    /// Werckmeister III's twelve degrees are the ones Werckmeister published.
    ///
    /// Asserted as absolute cents above the temperament's own C, which is the
    /// form the literature states and the form a reader can check: 0, 90.225,
    /// 192.18, 294.135, 390.225, 498.045, 588.27, 696.09, 792.18, 888.27, 996.09,
    /// 1092.18. The stored table holds the *deviation* from twelve-equal because
    /// that is what a ratio is built from, so this test adds the equal degree back
    /// and compares against the published figure — which is what makes the stored
    /// constants verifiable rather than merely plausible.
    func testWerckmeisterIIIHasItsPublishedDegrees() {
        let published: [Double] = [
            0, 90.225, 192.180, 294.135, 390.225, 498.045,
            588.270, 696.090, 792.180, 888.270, 996.090, 1092.180
        ]
        let offsets = Temperament.werckmeisterIII.offsetsInCentsAboveEqual
        XCTAssertEqual(offsets.count, 12)

        for pitchClass in 0..<12 {
            let degree = Double(pitchClass) * 100 + offsets[pitchClass]
            XCTAssertEqual(
                degree, published[pitchClass], accuracy: 0.001,
                "Werckmeister III's degree \(pitchClass) is \(degree) cents above its C; "
                    + "the published figure is \(published[pitchClass])"
            )
        }
    }

    /// The one structural fact that makes it a *well* temperament rather than a
    /// mean-tone one: every fifth is playable, and the four that carry the comma
    /// are the four Werckmeister names.
    ///
    /// A pure fifth is 701.955 cents. Werckmeister III narrows C–G, G–D, D–A and
    /// B–F♯ by a quarter of the Pythagorean comma (5.865 cents) each and leaves
    /// the other eight pure. Asserting that rather than only the degrees is what
    /// distinguishes this table from a transcription error that happens to sum
    /// correctly.
    func testWerckmeisterIIINarrowsExactlyTheFourFifthsItNames() {
        let offsets = Temperament.werckmeisterIII.offsetsInCentsAboveEqual
        let quarterComma = 23.460 / 4

        /// The fifth from `from` up to `from + 7`, in cents.
        ///
        /// Seven equal semitones is 700 cents whether or not the upper note wraps
        /// into the next octave — wrapping subtracts twelve semitones and adds the
        /// octave back — so the interval is 700 plus the two deviations.
        func fifth(from pitchClass: Int) -> Double {
            700 + offsets[(pitchClass + 7) % 12] - offsets[pitchClass]
        }

        // C = 0, G = 7, D = 2, A = 9, B = 11.
        let narrowed = [0, 7, 2, 11]
        for pitchClass in 0..<12 {
            let expected = narrowed.contains(pitchClass) ? 701.955 - quarterComma : 701.955
            XCTAssertEqual(
                fifth(from: pitchClass), expected, accuracy: 0.01,
                "The fifth above pitch class \(pitchClass) is \(fifth(from: pitchClass)) cents; "
                    + "Werckmeister III makes it \(expected)"
            )
        }
    }

    /// Equal temperament is twelve zeroes, which is the only honest table for it.
    func testEqualTemperamentIsTwelveZeroes() {
        XCTAssertEqual(Temperament.equal.offsetsInCentsAboveEqual, Array(repeating: 0, count: 12))
    }

    // MARK: The anchor

    /// A is where the reference pitch says it is, in **every** temperament.
    ///
    /// The whole of the anchoring decision in one assertion. A temperament is
    /// published against its own root, and Werckmeister's root is C; applied
    /// literally, selecting it would move A 11.73 cents off the reference pitch
    /// and the row labelled "A=440" would be telling the owner something untrue.
    /// So the table is shifted by its own A entry, and A4 comes out at exactly the
    /// reference frequency whichever temperament is chosen.
    func testAIsAtTheReferencePitchInEveryTemperament() {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                XCTAssertEqual(
                    tuning.frequency(ofMIDINote: 69), reference.hertz, accuracy: 1e-9,
                    "\(temperament) at \(reference) puts A4 at "
                        + "\(tuning.frequency(ofMIDINote: 69)) Hz rather than \(reference.hertz)"
                )
                // And every A, not only A4: the table is indexed by pitch class.
                XCTAssertEqual(
                    tuning.frequency(ofMIDINote: 57), reference.hertz / 2, accuracy: 1e-9
                )
                XCTAssertEqual(
                    tuning.frequency(ofMIDINote: 81), reference.hertz * 2, accuracy: 1e-9
                )
            }
        }
    }

    /// Anchoring changes no interval: the distance between any two pitch classes
    /// is exactly what the published table says it is.
    ///
    /// This is what makes the anchor a statement about pitch level rather than
    /// about the temperament — the musical character is untouched, and claiming
    /// "Werckmeister III" stays true.
    func testAnchoringPreservesEveryIntervalOfThePublishedTable() {
        let published = Temperament.werckmeisterIII.offsetsInCentsAboveEqual
        let applied = TuningSettings(temperament: .werckmeisterIII).offsetsInCentsFromEqual

        for lower in 0..<12 {
            for upper in 0..<12 {
                XCTAssertEqual(
                    applied[upper] - applied[lower],
                    published[upper] - published[lower],
                    accuracy: 1e-9,
                    "Anchoring changed the interval from pitch class \(lower) to \(upper)"
                )
            }
        }
    }

    /// The reference pitch is a pure transposition: every pitch class moves by the
    /// same 101.3 cents, and nothing about the temperament's shape changes.
    func testTheReferencePitchTransposesEverythingEqually() {
        let at440 = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a440)
        let at415 = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        let expected = 1200 * log2(415.0 / 440.0)

        XCTAssertEqual(expected, -101.27, accuracy: 0.01, "415 is about a semitone below 440")
        for note in 48...84 {
            let moved = 1200 * log2(at415.frequency(ofMIDINote: note)
                / at440.frequency(ofMIDINote: note))
            XCTAssertEqual(moved, expected, accuracy: 1e-6)
        }
    }

    // MARK: The default is the identity

    /// Every ratio of the default tuning is **exactly** 1.0 — the bit pattern, not
    /// a value close to it.
    ///
    /// REQ-006 asks for the default to render bit-identically to what the app did
    /// before this existed, and the two engines reach that by multiplying by this
    /// number. A multiply by exactly 1.0 is the identity in IEEE-754; a multiply by
    /// 1.0000000000000002 is not. So the claim is this assertion plus one line of C
    /// in each engine, rather than a tolerance anywhere.
    func testTheDefaultTuningIsExactlyTheIdentity() {
        let ratios = TuningSettings.standard.ratiosByPitchClass
        XCTAssertEqual(ratios.count, 12)
        for (pitchClass, ratio) in ratios.enumerated() {
            XCTAssertEqual(
                ratio.bitPattern, (1.0 as Double).bitPattern,
                "The default ratio for pitch class \(pitchClass) is \(ratio), not exactly 1.0"
            )
        }
        XCTAssertTrue(TuningSettings.standard.isDefault)
        XCTAssertEqual(TuningSettings.standard.temperament, .equal)
        XCTAssertEqual(TuningSettings.standard.referencePitch, .a440)
    }

    /// And the table the render core is handed is exactly the identity too, so
    /// nothing between the model and the engine rounds it.
    func testTheDefaultRenderTableIsExactlyTheIdentity() {
        var table = TuningSettings.standard.renderTable
        withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
            let entries = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: Double.self)
            for pitchClass in 0..<12 {
                XCTAssertEqual(
                    entries[pitchClass].bitPattern, (1.0 as Double).bitPattern,
                    "Render-table entry \(pitchClass) is \(entries[pitchClass]), not exactly 1.0"
                )
            }
        }
    }

    /// Any non-default tuning moves something, or the two pickers would be
    /// decoration.
    func testEveryNonDefaultTuningMovesSomething() {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                guard !tuning.isDefault else { continue }
                XCTAssertTrue(
                    tuning.ratiosByPitchClass.contains { $0 != 1.0 },
                    "\(temperament) at \(reference) is not the default and yet changes nothing"
                )
            }
        }
    }

    /// The render table carries exactly the ratios the model computed, entry for
    /// entry — so a measured frequency can be compared against
    /// `frequency(ofMIDINote:)` rather than against a second derivation.
    func testTheRenderTableCarriesTheModelsOwnRatios() {
        let tuning = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a415)
        var table = tuning.renderTable
        let expected = tuning.ratiosByPitchClass
        withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
            let entries = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: Double.self)
            for pitchClass in 0..<12 {
                XCTAssertEqual(entries[pitchClass], expected[pitchClass], accuracy: 1e-15)
            }
        }
    }

    // MARK: The C bound

    /// The sanitiser is the last line between a hand-edited document and a silent
    /// note: a NaN, a zero and an interval no setting can reach all become 1.0.
    func testTheSanitiserRefusesAnythingThatCouldSilenceANote() {
        var table = SynthTuningTable()
        synth_tuning_table_default(&table)
        withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
            let entries = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: Double.self)
            entries[0] = Double.nan
            entries[1] = 0
            entries[2] = -1
            entries[3] = 8           // three octaves up: not a temperament
            entries[4] = Double.infinity
            entries[5] = 0.9431      // A=415's own ratio: legal, must survive
        }
        synth_tuning_table_sanitize(&table)

        withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
            let entries = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: Double.self)
            for pitchClass in 0...4 {
                XCTAssertEqual(
                    entries[pitchClass], 1.0,
                    "Entry \(pitchClass) survived the sanitiser as \(entries[pitchClass])"
                )
            }
            XCTAssertEqual(
                entries[5], 0.9431, accuracy: 1e-12,
                "The sanitiser rejected a ratio the product itself produces"
            )
        }
    }

    /// And every ratio the product can actually ask for survives it, which is the
    /// other half of a bound being right.
    func testEveryRatioTheProductCanAskForSurvivesTheSanitiser() {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let tuning = TuningSettings(temperament: temperament, referencePitch: reference)
                var table = tuning.renderTable
                let before = tuning.ratiosByPitchClass
                synth_tuning_table_sanitize(&table)
                withUnsafeMutablePointer(to: &table.ratioByPitchClass) { tuple in
                    let entries = UnsafeMutableRawPointer(tuple)
                        .assumingMemoryBound(to: Double.self)
                    for pitchClass in 0..<12 {
                        XCTAssertEqual(
                            entries[pitchClass], before[pitchClass], accuracy: 1e-15,
                            "\(temperament) at \(reference) had pitch class \(pitchClass) "
                                + "clamped by the sanitiser"
                        )
                    }
                }
            }
        }
    }

    // MARK: Storage

    /// A tuning survives a round trip through the stored form.
    func testATuningRoundTripsThroughItsStoredForm() throws {
        for temperament in Temperament.allCases {
            for reference in ReferencePitch.allCases {
                let original = TuningSettings(temperament: temperament, referencePitch: reference)
                let data = try JSONEncoder().encode(original)
                let read = try JSONDecoder().decode(TuningSettings.self, from: data)
                XCTAssertEqual(read, original)
            }
        }
    }

    /// REQ-006's failure clause: a temperament name this build does not know reads
    /// as equal temperament, says so, and does not fail the document.
    func testAnUnknownStoredTemperamentReadsAsEqualAndSaysSo() throws {
        let stored = Data(#"{"temperament":"vallotti","referencePitch":"a415"}"#.utf8)
        let read = try JSONDecoder().decode(TuningSettings.self, from: stored)

        XCTAssertEqual(read.temperament, .equal, "An unknown temperament must play as equal")
        XCTAssertEqual(
            read.referencePitch, .a415,
            "The reference pitch is a separate field and was readable; it must not be discarded"
        )
        XCTAssertEqual(read.unrecognizedTemperament, "vallotti")
        XCTAssertTrue(read.ratiosByPitchClass.allSatisfy { $0 == 415.0 / 440.0 })

        let sentence = try XCTUnwrap(read.failureSentence, "The owner has to be told")
        XCTAssertTrue(sentence.contains("vallotti"), "The sentence must name what was asked for")
        XCTAssertTrue(sentence.contains("equal temperament"), "…and what is being played instead")
    }

    /// And it is not destroyed by being read: an older build that opens a newer
    /// preset writes the name back rather than replacing the owner's choice with
    /// "equal".
    ///
    /// This matters because the preset auto-saves on every performance change. A
    /// dropped name would survive exactly until the owner next moved any slider.
    func testAnUnknownStoredTemperamentIsWrittenBackRatherThanOverwritten() throws {
        let stored = Data(#"{"temperament":"vallotti","referencePitch":"a440"}"#.utf8)
        let read = try JSONDecoder().decode(TuningSettings.self, from: stored)
        let written = try JSONEncoder().encode(read)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: written) as? [String: Any]
        )
        XCTAssertEqual(object["temperament"] as? String, "vallotti")
    }

    /// Choosing a temperament clears the unreadable name, because that is the one
    /// moment replacing it is what the owner asked for.
    func testChoosingATemperamentClearsAnUnreadableStoredName() {
        let replaced = TuningSettings(temperament: .werckmeisterIII, referencePitch: .a440)
        XCTAssertNil(replaced.unrecognizedTemperament)
        XCTAssertNil(replaced.failureSentence)
    }

    /// A known tuning has nothing to report, so the status bar says nothing
    /// unusual about it.
    func testAKnownTuningHasNothingToReport() {
        for temperament in Temperament.allCases {
            XCTAssertNil(TuningSettings(temperament: temperament).failureSentence)
        }
    }

    /// An unknown *reference pitch* falls back the same way, without its own
    /// report: the field carries no musical name, and the record is corrupt in a
    /// way the temperament field has already spoken about.
    func testAnUnknownStoredReferencePitchFallsBackToConcertPitch() throws {
        let stored = Data(#"{"temperament":"equal","referencePitch":"a392"}"#.utf8)
        let read = try JSONDecoder().decode(TuningSettings.self, from: stored)
        XCTAssertEqual(read.referencePitch, .a440)
        XCTAssertTrue(read.isDefault)
    }

    /// A record with neither field — which is what a document written before this
    /// existed looks like once it reaches this type — is the default.
    func testAnEmptyStoredRecordIsTheDefault() throws {
        let read = try JSONDecoder().decode(TuningSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(read, .standard)
    }
}
