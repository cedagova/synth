import XCTest
@testable import SynthKit

/// Issue #17: "A patch document round-trips: serialize → load → byte-identical
/// parameters" and "malformed or future-versioned patch documents fail to load
/// with a clear error, never crash or emit unbounded audio."
///
/// The identical-*audio* half of the round trip is in
/// `SynthEngineIntegrationTests`; this file is about the document itself.
final class SynthPatchDocumentTests: XCTestCase {
    /// A patch with every section switched on and no value left at its
    /// default, so a round trip that dropped or defaulted a field would show.
    private func fullyPopulatedPatch() -> SynthPatch {
        SynthPatch(
            identifier: "test.everything",
            name: "Everything",
            oscillators: [
                .init(type: .analog, analogShape: .pulse, wavetableBank: .metallic,
                      level: 0.81, detuneSemitones: -7, detuneCents: 13.5,
                      shapeAmount: 0.32, frequencyModulationRatio: 2.5,
                      retriggersPhase: false, startPhase: 0.25),
                .init(type: .wavetable, analogShape: .square, wavetableBank: .formant,
                      level: 0.44, detuneSemitones: 12, detuneCents: -6,
                      shapeAmount: 0.77, frequencyModulationRatio: 0.5,
                      retriggersPhase: true, startPhase: 0.5),
                .init(type: .frequencyModulation, analogShape: .triangle, wavetableBank: .hollow,
                      level: 0.19, detuneSemitones: 19.01955, detuneCents: 42,
                      shapeAmount: 0.61, frequencyModulationRatio: 7.25,
                      retriggersPhase: false, startPhase: 0.125)
            ],
            noiseLevel: 0.17,
            filter: .init(isEnabled: true, type: .bandpass, poles: 4,
                          cutoffHertz: 1234.5, resonance: 0.66, keyTracking: 0.4),
            amplitudeEnvelope: .init(attackSeconds: 0.031, decaySeconds: 0.47,
                                     sustainLevel: 0.53, releaseSeconds: 1.75, curve: 0.8),
            modulationEnvelope: .init(attackSeconds: 0.0021, decaySeconds: 2.5,
                                      sustainLevel: 0.11, releaseSeconds: 0.9, curve: 0.35),
            lfos: [
                .init(shape: .sampleAndHold, rateHertz: 7.25, startPhase: 0.3,
                      retriggersPerNote: true),
                .init(shape: .triangle, rateHertz: 0.35, startPhase: 0.75,
                      retriggersPerNote: false)
            ],
            modulation: [
                .init(source: .lfo1, destination: .filterCutoff, amount: 0.62),
                .init(source: .modulationEnvelope, destination: .oscillator2Shape, amount: -0.4),
                .init(source: .velocity, destination: .amplitude, amount: 0.25),
                .init(source: .keyTrack, destination: .oscillator1Pitch, amount: -0.05),
                .init(source: .noteRandom, destination: .oscillator3Level, amount: 0.33),
                .init(source: .lfo2, destination: .filterResonance, amount: 0.18),
                .init(source: .amplitudeEnvelope, destination: .oscillator3Pitch, amount: 0.07),
                .init()
            ],
            equalizer: .init(isEnabled: true, lowGainDecibels: -8.5, lowHertz: 145,
                             midGainDecibels: 4.25, midHertz: 2300, midQ: 2.75,
                             highGainDecibels: -3.75, highHertz: 9500),
            chorus: .init(isEnabled: true, rateHertz: 1.35, depthMilliseconds: 8.5,
                          centreMilliseconds: 17.5, mix: 0.62, feedback: 0.42),
            delay: .init(isEnabled: true, timeSeconds: 0.375, feedback: 0.71,
                         mix: 0.44, dampening: 0.83),
            reverb: .init(isEnabled: true, roomSize: 0.91, dampening: 0.22,
                          mix: 0.37, preDelaySeconds: 0.045),
            maximumVoices: 12,
            outputLevel: 0.63,
            velocitySensitivity: 2.35,
            seed: 0xFEDC_BA98_7654_3210
        )
    }

    // MARK: Round trip

    /// **The round-trip criterion.** Every parameter comes back exactly as it
    /// went in.
    ///
    /// `Equatable` on the whole struct rather than a field-by-field walk,
    /// because a field-by-field test only checks the fields someone remembered
    /// to list, and a new parameter added later would silently escape it.
    func testEveryParameterSurvivesASerialiseAndLoad() throws {
        let original = fullyPopulatedPatch()
        let loaded = try SynthPatchDocument.patch(from: SynthPatchDocument.data(from: original))
        XCTAssertEqual(loaded, original)
    }

    /// Writing a patch, reading it, and writing it again produces the same
    /// bytes.
    ///
    /// This is what makes a stored patch stable: without it, opening and
    /// saving a sound nobody touched would still show as a change to the
    /// library, and a preset would not have a fixed identity.
    func testRewritingALoadedPatchProducesIdenticalBytes() throws {
        let first = try SynthPatchDocument.data(from: fullyPopulatedPatch())
        let second = try SynthPatchDocument.data(from: SynthPatchDocument.patch(from: first))
        XCTAssertEqual(first, second)
    }

    /// A 64-bit seed survives JSON, which is the one field where an encoder
    /// that quietly went through `Double` would lose precision — and would
    /// take determinism with it.
    func testALargeSeedSurvivesTheRoundTrip() throws {
        var patch = SynthPatch.defaultVoice
        patch.seed = 0xFFFF_FFFF_FFFF_FFF1
        let loaded = try SynthPatchDocument.patch(from: SynthPatchDocument.data(from: patch))
        XCTAssertEqual(loaded.seed, 0xFFFF_FFFF_FFFF_FFF1)
    }

    /// The shipped default voice is itself a valid document.
    func testTheDefaultVoiceRoundTrips() throws {
        let loaded = try SynthPatchDocument.patch(
            from: SynthPatchDocument.data(from: .defaultVoice))
        XCTAssertEqual(loaded, .defaultVoice)
        XCTAssertEqual(loaded.identifier, "builtin.default-voice")
    }

    /// The document carries its format version, so a later change has
    /// something to migrate from.
    func testTheDocumentRecordsItsFormatVersion() throws {
        let data = try SynthPatchDocument.data(from: .defaultVoice)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, SynthPatch.currentVersion)
        XCTAssertNotNil(object["patch"])
    }

    // MARK: Failure behaviour

    /// A patch written by a later version of the app is refused, and the error
    /// says so — rather than being read with whatever fields happen to match.
    func testAFutureVersionIsRefusedWithItsVersionNumbers() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try SynthPatchDocument.data(from: .defaultVoice)) as? [String: Any])
        object["version"] = SynthPatch.currentVersion + 7
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .unsupportedVersion(found: SynthPatch.currentVersion + 7,
                                    supported: SynthPatch.currentVersion)
            )
            XCTAssertTrue(
                "\(error)".contains("newer version"),
                "The message does not say the file is newer: \(error)"
            )
        }
    }

    /// A future version whose *patch* shape has also changed still reports the
    /// version rather than a confusing key error.
    ///
    /// This is why the version is read before anything else: the whole point
    /// of a version field is to be readable when the rest is not.
    func testAFutureVersionWithAnUnreadablePatchStillReportsTheVersion() throws {
        let data = try XCTUnwrap(
            #"{"version": 99, "patch": {"somethingWeHaveNeverSeen": true}}"#.data(using: .utf8))
        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .unsupportedVersion(found: 99, supported: SynthPatch.currentVersion)
            )
        }
    }

    func testBytesThatAreNotJSONAreRefused() {
        let data = Data("this is not a patch, it is a sentence".utf8)
        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            guard case .notJSON = (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .notJSON, got \(error)")
            }
        }
    }

    func testAnEmptyDocumentIsRefused() {
        XCTAssertThrowsError(try SynthPatchDocument.patch(from: Data())) { error in
            guard case .notJSON = (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .notJSON, got \(error)")
            }
        }
    }

    func testAVersionlessDocumentIsRefused() throws {
        let data = try XCTUnwrap(#"{"patch": {}}"#.data(using: .utf8))
        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            XCTAssertEqual(error as? SynthPatchDocumentError, .missingVersion)
        }
    }

    /// A truncated file — the realistic corruption — names the key it could
    /// not find.
    func testAMissingSectionNamesWhatIsMissing() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try SynthPatchDocument.data(from: .defaultVoice)) as? [String: Any])
        var patch = try XCTUnwrap(object["patch"] as? [String: Any])
        patch.removeValue(forKey: "filter")
        object["patch"] = patch
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            guard case .malformed(let reason) = (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .malformed, got \(error)")
            }
            XCTAssertTrue(reason.contains("filter"), "The error does not name `filter`: \(reason)")
        }
    }

    /// An enumerated value this build does not know is a load failure, not a
    /// silent fallback to the first case.
    func testAnUnknownEnumeratedValueIsRefused() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try SynthPatchDocument.data(from: .defaultVoice)) as? [String: Any])
        var patch = try XCTUnwrap(object["patch"] as? [String: Any])
        var oscillators = try XCTUnwrap(patch["oscillators"] as? [[String: Any]])
        oscillators[0]["type"] = "granular"
        patch["oscillators"] = oscillators
        object["patch"] = patch
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data)) { error in
            guard case .malformed = (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }

    /// The architecture is fixed, so a document with the wrong number of
    /// oscillators is not a patch.
    func testTheWrongNumberOfOscillatorsIsRefused() {
        var patch = SynthPatch.defaultVoice
        patch.oscillators.removeLast()
        XCTAssertThrowsError(try SynthPatchDocument.data(from: patch)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .wrongComponentCount(name: "oscillators", found: 2, expected: 3)
            )
        }
    }

    func testTheWrongNumberOfModulationRoutesIsRefused() {
        var patch = SynthPatch.defaultVoice
        patch.modulation = [.init()]
        XCTAssertThrowsError(try SynthPatchDocument.data(from: patch)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .wrongComponentCount(name: "modulation routes", found: 1, expected: 8)
            )
        }
    }

    /// **Out-of-range values are reported, not clamped.**
    ///
    /// The render core clamps too, and that clamp is what protects the audio
    /// thread. The reason to also reject here is that a file claiming a
    /// 900 kHz cutoff is a broken file, and quietly rendering it at 20 kHz
    /// would leave the user with a sound they never chose and no way to tell
    /// why.
    func testOutOfRangeParametersAreReportedWithTheirName() {
        var patch = SynthPatch.defaultVoice
        patch.filter.cutoffHertz = 900_000
        XCTAssertThrowsError(try SynthPatchDocument.data(from: patch)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .parameterOutOfRange(name: "filter.cutoffHertz", value: 900_000,
                                     minimum: 20, maximum: 20_000)
            )
            XCTAssertTrue("\(error)".contains("filter.cutoffHertz"))
        }

        var noisy = SynthPatch.defaultVoice
        noisy.oscillators[1].level = 4
        XCTAssertThrowsError(try SynthPatchDocument.data(from: noisy)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .parameterOutOfRange(name: "oscillators[1].level", value: 4,
                                     minimum: 0, maximum: 1)
            )
        }

        var runaway = SynthPatch.defaultVoice
        runaway.delay.feedback = 1.4
        XCTAssertThrowsError(try SynthPatchDocument.data(from: runaway)) { error in
            XCTAssertEqual(
                error as? SynthPatchDocumentError,
                .parameterOutOfRange(name: "delay.feedback", value: 1.4, minimum: 0, maximum: 0.85)
            )
        }
    }

    func testANonFiniteParameterIsRefused() {
        var patch = SynthPatch.defaultVoice
        patch.outputLevel = .nan
        XCTAssertThrowsError(try SynthPatchDocument.data(from: patch)) { error in
            guard case .parameterOutOfRange(let name, _, _, _) =
                    (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .parameterOutOfRange, got \(error)")
            }
            XCTAssertEqual(name, "outputLevel")
        }
    }

    /// A filter with three poles is not a filter this engine has.
    func testAnImpossiblePoleCountIsRefused() {
        var patch = SynthPatch.defaultVoice
        patch.filter.poles = 3
        XCTAssertThrowsError(try SynthPatchDocument.data(from: patch)) { error in
            guard case .parameterOutOfRange(let name, _, _, _) =
                    (error as? SynthPatchDocumentError) else {
                return XCTFail("Expected .parameterOutOfRange, got \(error)")
            }
            XCTAssertEqual(name, "filter.poles")
        }
    }

    /// A refused document leaves nothing behind: no engine was built, and the
    /// caller still has a working default to fall back on.
    func testARefusedDocumentDoesNotDisturbTheDefaultVoice() {
        let data = Data("garbage".utf8)
        XCTAssertThrowsError(try SynthPatchDocument.patch(from: data))
        let samples = SynthVoiceHarness.renderNote(patch: .defaultVoice, holdSeconds: 0.3)
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(samples, from: 0.05, to: 0.25, sampleRate: 48_000), 0.001
        )
    }

    /// Every error has a message a person could act on.
    func testEveryErrorDescribesItself() {
        let errors: [SynthPatchDocumentError] = [
            .notJSON(reason: "unexpected byte"),
            .missingVersion,
            .unsupportedVersion(found: 4, supported: 1),
            .malformed(reason: "missing filter"),
            .wrongComponentCount(name: "oscillators", found: 2, expected: 3),
            .parameterOutOfRange(name: "outputLevel", value: 5, minimum: 0, maximum: 1)
        ]
        for error in errors {
            XCTAssertGreaterThan(error.description.count, 20, "\(error) has no useful message.")
            XCTAssertFalse(error.description.contains("Optional("))
        }
    }
}
