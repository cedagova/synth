import XCTest
@testable import SynthKit

/// The shipped collection has to be *sounds*, not rows.
///
/// A categorised starter collection of silent or identical patches would pass
/// every structural test in `SoundLibraryTests` and fail the product entirely,
/// so the claims here are measurements of rendered audio: each shipped patch is
/// audible, each one is spectrally distinguishable from the others, and none of
/// them is a distorted or unbounded mess. The technique is the house one from
/// `SynthEngineRenderTests` — deterministic offline rendering through the real
/// voice vtable, then windowed RMS and single-bin Goertzel probes.
final class ShippedSoundCollectionTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// C4 — a note in every one of these sounds' usable range, bass patches
    /// included. One note for the whole collection so "distinct" is a claim
    /// about the sounds rather than about which pitch each was rendered at.
    private let testNote = 60

    private var collection: [SoundEntry] { ShippedSoundCollection.standard.sounds }

    // MARK: Presence and shape (REQ-019)

    func testTheCollectionIsPresentAndCoversEveryCategory() throws {
        XCTAssertGreaterThanOrEqual(collection.count, 8)

        let occupied = Set(collection.map(\.category))
        XCTAssertEqual(
            occupied, Set(SoundCategory.allCases),
            "Every category the library offers must have at least one shipped sound in it"
        )

        for category in SoundCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
        }
    }

    func testEveryShippedSoundIsReadOnlyAndHasNoStoreIdentityOfItsOwn() {
        for sound in collection {
            XCTAssertEqual(sound.origin, .shipped, sound.name)
            XCTAssertFalse(sound.isEditable, sound.name)
            XCTAssertNil(sound.shippedOriginID, sound.name)
            XCTAssertEqual(sound.revision, 0, sound.name)
            XCTAssertFalse(sound.name.isEmpty)
        }
    }

    func testShippedIdentitiesAndNamesAreUniqueAndStable() {
        XCTAssertEqual(Set(collection.map(\.id)).count, collection.count, "Duplicate identity")
        XCTAssertEqual(Set(collection.map(\.name)).count, collection.count, "Duplicate name")

        // The identity is what a preset in increment 004 will store, so it has
        // to be the row identity and the patch identity at once.
        for sound in collection {
            XCTAssertEqual(sound.patch.identifier, sound.id, sound.name)
            XCTAssertEqual(sound.patch.name, sound.name, sound.name)
        }
    }

    /// AD7: increment 002's built-in voice ships as one of these.
    func testTheDefaultVoiceIsOneOfTheShippedSounds() throws {
        let entry = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: SynthPatch.defaultVoice.identifier)
        )
        XCTAssertEqual(entry.patch, SynthPatch.defaultVoice)
        XCTAssertEqual(entry.name, "Default Voice")
        XCTAssertEqual(entry.category, .keys)
    }

    /// Every shipped patch has to be one the store would accept and the reader
    /// would give back unchanged. A shipped sound that could not be copied is
    /// not a shipped sound.
    func testEveryShippedPatchIsValidAndRoundTripsThroughTheDocumentFormat() throws {
        for sound in collection {
            XCTAssertNoThrow(try SynthPatchDocument.validate(sound.patch), sound.name)
            let data = try SynthPatchDocument.data(from: sound.patch)
            XCTAssertEqual(try SynthPatchDocument.patch(from: data), sound.patch, sound.name)
        }
    }

    func testTheCollectionIsListedInStableCategoryThenNameOrder() {
        let ids = ShippedSoundCollection.standard.sounds.map(\.id)
        let rebuilt = ShippedSoundCollection(sounds: collection.reversed()).sounds.map(\.id)
        XCTAssertEqual(ids, rebuilt, "List order must not depend on input order")

        for (earlier, later) in zip(collection, collection.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.category.sortIndex, later.category.sortIndex,
                "\(earlier.name) then \(later.name)"
            )
        }
    }

    // MARK: These are sounds (the claim a structural test cannot make)

    /// Each shipped sound renders audibly, and stays inside the limiter.
    ///
    /// Measured as the loudest 200 ms of a three-second note rather than the
    /// mean over a fixed window. The collection deliberately contains both a
    /// 2 ms pluck and a one-second pad swell, and a fixed early window would
    /// call the pad quiet for having an attack — a measurement artefact rather
    /// than a fact about the sound. "Has an audible moment" is the claim, and
    /// it is fair to both.
    func testEveryShippedSoundIsAudible() throws {
        var levels: [(String, Double, Float)] = []

        for sound in collection {
            let samples = SynthVoiceHarness.renderNote(
                patch: sound.patch,
                midiNoteNumber: testNote,
                velocity: 100,
                holdSeconds: 3.0,
                tailSeconds: 0.5,
                sampleRate: sampleRate
            )

            let level = Self.loudestWindowRMS(samples, seconds: 0.2, sampleRate: sampleRate)
            let peak = AudioRenderFixtures.peak(samples)
            levels.append((sound.name, level, peak))

            XCTAssertGreaterThan(level, 0.01, "\(sound.name) is inaudible (loudest RMS \(level))")
            XCTAssertLessThan(peak, 1.0, "\(sound.name) clips (peak \(peak))")
            XCTAssertTrue(samples.allSatisfy(\.isFinite), "\(sound.name) produced a non-finite sample")
        }

        // Printed so a failure — or a later change to a shipped sound — is
        // readable rather than a bare threshold miss.
        for (name, level, peak) in levels {
            print(String(format: "shipped %-18@ loudest-RMS %.4f  peak %.4f", name as NSString, level, peak))
        }
    }

    /// No two shipped sounds are the same sound.
    ///
    /// **Spectrum alone is not enough, and finding that out is the point.** A
    /// sub bass and a soft lead both reduce to "nearly all fundamental" at one
    /// mid-register note, and comparing only harmonic profiles there scores
    /// them 0.9998 identical while any listener would tell them apart instantly.
    /// What actually separates two sounds is *what they play like*: their
    /// spectrum across the register, and the shape of their loudness over the
    /// note.
    ///
    /// So the fingerprint is both, at three pitches two octaves apart — the low
    /// note is where a filter that tracks the key stops flattering a bass patch
    /// — and every pair must differ somewhere in it.
    func testNoTwoShippedSoundsAreTheSameSound() throws {
        let fingerprints = collection.map { (name: $0.name, vector: fingerprint(of: $0.patch)) }

        var worst = (left: "", right: "", similarity: -1.0)
        for outer in fingerprints.indices {
            for inner in (outer + 1)..<fingerprints.count {
                let similarity = Self.cosineSimilarity(
                    fingerprints[outer].vector, fingerprints[inner].vector
                )
                if similarity > worst.similarity {
                    worst = (fingerprints[outer].name, fingerprints[inner].name, similarity)
                }
                XCTAssertLessThan(
                    similarity, 0.99,
                    "\(fingerprints[outer].name) and \(fingerprints[inner].name) are the same "
                        + "sound (fingerprint similarity \(similarity))"
                )
            }
        }
        print(String(
            format: "closest shipped pair: %@ / %@ — similarity %.4f",
            worst.left, worst.right, worst.similarity
        ))
    }

    /// What a sound is like: its harmonic content and its loudness contour, at
    /// three pitches across the register.
    ///
    /// Each block is normalised on its own before being concatenated, so a loud
    /// sound and a quiet one with the same character still land in the same
    /// place and a difference in *character* is what moves the vector.
    private func fingerprint(of patch: SynthPatch) -> [Double] {
        var vector: [Double] = []

        for note in [36, 60, 72] {
            let samples = SynthVoiceHarness.renderNote(
                patch: patch,
                midiNoteNumber: note,
                velocity: 100,
                holdSeconds: 2.0,
                sampleRate: sampleRate
            )

            // Spectrum, taken from the steady part of the note so an attack
            // transient is not doing the separating on its own.
            let steady = Array(samples[Int(0.8 * sampleRate)..<Int(1.8 * sampleRate)])
            vector += Self.normalised(
                AudioRenderFixtures.harmonicEnergies(
                    steady,
                    fundamental: AudioRenderFixtures.frequency(ofMIDINote: note),
                    count: 10,
                    sampleRate: sampleRate
                )
            )

            // Loudness contour over the whole note, in eight slices: this is
            // what tells a 2 ms pluck from a one-second swell at the same pitch
            // with the same harmonics.
            let sliceCount = 8
            let sliceLength = samples.count / sliceCount
            vector += Self.normalised((0..<sliceCount).map { slice in
                AudioRenderFixtures.rms(
                    samples,
                    from: Double(slice * sliceLength) / sampleRate,
                    to: Double((slice + 1) * sliceLength) / sampleRate,
                    sampleRate: sampleRate
                )
            })
        }

        return vector
    }

    /// Scaled so the block sums to 1, or left at zero when it is silent.
    private static func normalised(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        guard total > 0 else { return values }
        return values.map { $0 / total }
    }

    /// RMS of the loudest window of this length anywhere in the buffer.
    private static func loudestWindowRMS(
        _ samples: [Float], seconds: Double, sampleRate: Double
    ) -> Double {
        let window = Int(seconds * sampleRate)
        guard samples.count >= window, window > 0 else {
            return AudioRenderFixtures.rms(
                samples, from: 0, to: Double(samples.count) / sampleRate, sampleRate: sampleRate
            )
        }
        let hop = max(1, window / 4)
        var loudest = 0.0
        var start = 0
        while start + window <= samples.count {
            var total = 0.0
            for index in start..<(start + window) {
                total += Double(samples[index]) * Double(samples[index])
            }
            loudest = max(loudest, (total / Double(window)).squareRoot())
            start += hop
        }
        return loudest
    }

    /// The collection uses the architecture it ships with, rather than being
    /// thirteen variations on one saw.
    func testTheCollectionExercisesTheWholeSynthesisArchitecture() {
        let oscillatorTypes = Set(collection.flatMap { sound in
            sound.patch.oscillators.filter { $0.level > 0 }.map(\.type)
        })
        XCTAssertEqual(
            oscillatorTypes, Set(SynthPatch.OscillatorType.allCases),
            "Every oscillator type should appear somewhere in the starter collection"
        )

        XCTAssertTrue(collection.contains { $0.patch.filter.isEnabled && $0.patch.filter.poles == 4 })
        XCTAssertTrue(collection.contains { $0.patch.equalizer.isEnabled })
        XCTAssertTrue(collection.contains { $0.patch.chorus.isEnabled })
        XCTAssertTrue(collection.contains { $0.patch.delay.isEnabled })
        XCTAssertTrue(collection.contains { $0.patch.reverb.isEnabled })
        XCTAssertTrue(collection.contains { $0.patch.modulation.contains(where: \.isActive) })
        XCTAssertTrue(collection.contains { $0.patch.noiseLevel > 0 })
    }

    /// A chord of every shipped sound stays inside the limiter.
    ///
    /// SYN001 proved the limiter holds for the heaviest patch it could build.
    /// This leaf is where patches with *chosen* output levels first exist —
    /// Breath Pad runs at 0.45 against the 0.14 default, because a band-passed
    /// pad through a wet reverb needs it — so the headroom question is genuinely
    /// reopened by the collection, one patch at a time.
    func testNoShippedSoundClipsOnAFullChord() throws {
        for sound in collection {
            let voices = min(sound.patch.maximumVoices, 8)
            let harness = SynthVoiceHarness(patch: sound.patch, sampleRate: sampleRate)
            // A wide voicing, so this is polyphony rather than one note tripled.
            for offset in 0..<voices {
                harness.noteOn(48 + offset * 4, velocity: 127)
            }
            let samples = harness.render(seconds: 2.0)

            let peak = AudioRenderFixtures.peak(samples)
            XCTAssertLessThanOrEqual(
                peak, 1.0,
                "\(sound.name) leaves the limiter on a \(voices)-note chord (peak \(peak))"
            )
            XCTAssertTrue(samples.allSatisfy(\.isFinite), sound.name)
            print(String(format: "shipped %-18@ %d-note chord peak %.4f",
                         sound.name as NSString, voices, peak))
        }
    }

    /// A shipped patch is a fixed value, so rendering it twice gives the same
    /// bytes — which is what makes any measurement above reproducible.
    func testAShippedSoundRendersIdenticallyEveryTime() throws {
        let sound = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: "shipped.breath-pad")
        )
        let first = SynthVoiceHarness.renderNote(
            patch: sound.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        let second = SynthVoiceHarness.renderNote(
            patch: sound.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        XCTAssertEqual(first, second, "\(sound.name) is not deterministic")
        XCTAssertGreaterThan(
            AudioRenderFixtures.rms(first, from: 0.5, to: 1.0, sampleRate: sampleRate), 0,
            "A noise-bearing patch that renders silence would pass byte equality trivially"
        )
    }

    /// A copy of a shipped sound is the same sound, audibly, before it is
    /// edited — the other half of edit-as-copy that only a render can prove.
    func testACopyOfAShippedSoundRendersIdenticallyUntilItIsEdited() throws {
        let sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let store = try LibraryStore.open(
            container: AppContainer(rootURL: sandboxRoot.appending(path: "Synth")),
            appVersion: "1.0 (1)"
        )
        defer { store.close() }

        let shipped = try XCTUnwrap(
            ShippedSoundCollection.standard.sound(withID: "shipped.nylon-pluck")
        )
        let copy = try store.sounds.makeEditableCopy(of: shipped)

        let original = SynthVoiceHarness.renderNote(
            patch: shipped.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        let copied = SynthVoiceHarness.renderNote(
            patch: copy.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        XCTAssertEqual(original, copied, "A fresh copy must sound exactly like what it copied")

        // Edit the copy, and only the copy moves.
        var darker = copy.patch
        darker.filter.cutoffHertz = 200
        let edited = try store.sounds.update(copy, patch: darker)

        let afterEdit = SynthVoiceHarness.renderNote(
            patch: edited.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        XCTAssertNotEqual(afterEdit, original, "The edit did not change what the copy sounds like")

        let reloadedShipped = try XCTUnwrap(try store.sounds.sound(withID: shipped.id))
        let shippedAgain = SynthVoiceHarness.renderNote(
            patch: reloadedShipped.patch, midiNoteNumber: testNote, holdSeconds: 1.0,
            sampleRate: sampleRate
        )
        XCTAssertEqual(shippedAgain, original, "Editing a copy changed the shipped original")
    }

    // MARK: Helpers

    private static func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double {
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        let leftNorm = left.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let rightNorm = right.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return dot / (leftNorm * rightNorm)
    }
}
