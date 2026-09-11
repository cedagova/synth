import XCTest
@testable import SynthKit

/// The purity invariant PLY002 has to hold, and the one PLY001 already holds
/// one layer down: realization reads no clock, draws nothing by chance, and
/// consults no environment.
///
/// The same three independent guards, for the same reason each alone has a
/// hole:
///
/// 1. **frozen timeline digests** — the exact SHA-256 of `canonicalData()` for
///    fixtures realized at several settings. This is the only guard that spans
///    process launches, and it is the one REQ-012 actually asks for;
/// 2. **behaviour** — the same score realizes to the same timeline under
///    repeat, interleaved and concurrent use (in `HumanizationTests`); and
/// 3. **source** — no file on the realization path even mentions a
///    nondeterministic API.
///
/// Why (1) has to exist: Swift seeds `Hasher` once per process, so `Dictionary`
/// and `Set` iteration order is stable within a run and varies only between
/// launches. Every in-process byte-equality check would therefore pass a
/// realizer whose output came out of an unsorted dictionary. A digest a fresh
/// process must reproduce is what closes that — which matters more here than
/// in the compiler, because this stage builds per-staff tracks in dictionaries
/// and merges them per line.
final class PerformanceTimelinePurityTests: XCTestCase {
    /// The canonical timeline bytes each fixture and setting must always
    /// produce.
    ///
    /// These are not constants to re-record when they fail. They fail for
    /// exactly two reasons:
    ///
    /// - the timeline or a realization rule changed, in which case the new
    ///   digests are correct and the change is deliberate; or
    /// - something nondeterministic reached the output path, in which case the
    ///   digest will differ between launches rather than consistently.
    ///
    /// Tell them apart by running the suite twice in two processes: a
    /// deliberate change gives the same wrong digest twice.
    ///
    /// Every digest here moved once, on this leaf, for one deliberate reason:
    /// `RealizationSettings` gained its `expression` field and the timeline
    /// encodes the settings it was realized under, so the canonical bytes
    /// changed even where not one note did. The values below were refrozen from
    /// two agreeing runs in separate processes. The claim that the *music* is
    /// unchanged wherever expression is off is a separate and stronger one, and
    /// `PerformanceExpressionTests` holds it: it freezes the event digests
    /// recorded before this leaf existed, with the settings record left out.
    private static let frozenTimelineDigests: [String: String] = [
        "ornamentStudy/literal":
            "85f8ca7d4f5683f0e9b3c30c8bef27471b5662c411d30f0b37ff419cbcb31d29",
        "expressiveKeyboardPiece/literal":
            "7a5e6b2d15a75cfee6d8143b7b8565f81a7fbeae51cddfda955029e0ea590b8a",
        "expressiveKeyboardPiece/standard":
            "54820c418db8ac40223a61353641bc5efc835fc662c2bd95bccb8a44f70650a8",
        "expressiveKeyboardPiece/intensity-100":
            "22896a7c787660fc6d5089034ce9fd27e9b202332a5c8958de1282897ed2d50b",
        "stringQuartetMovement/standard":
            "23609e3d67d04886f9037ff4726ff0b615d592ce393ee4a491b8d15168bc0117",
        "fastOrnamentsAndGraceNotes/intensity-100":
            "bcfa84f69f4c6d1e3820e42fe2702709a3d9701ba77397a73a7b10df671caee9",
        "expressiveKeyboardPiece/expression-off":
            "3b28b8e2fe6a33a4ce14566f5f7f7f8024a92e4c9d44f941e4df3add3a12b3d8",
        "expressiveKeyboardPiece/expression-100":
            "125a96ddaefd65d9ed9b3c67b3a00cca6318b1e21a4a0ef521222c2588baef9f",
        "stringQuartetMovement/expression-only":
            "2892a63e0960e3d61012d8d420a09991eaf5beb6265469a01ae3fd067f240a1c",
        "keyboardFugueExposition/expression-100":
            "b9d0cd67068f87b6aa2cdca3cbb2eefa54f3999b78fe900e4e323ea971d4f2ce"
    ]

    private static let frozenCases: [(name: String, data: Data, settings: RealizationSettings)] = [
        ("ornamentStudy/literal", MusicXMLScoreFixtures.ornamentStudy(), .literal),
        (
            "expressiveKeyboardPiece/literal",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            .literal
        ),
        (
            "expressiveKeyboardPiece/standard",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            .standard
        ),
        (
            "expressiveKeyboardPiece/intensity-100",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        ),
        ("stringQuartetMovement/standard", MusicXMLScoreFixtures.stringQuartetMovement(), .standard),
        // The humanization room bound only engages where figures are tighter
        // than the jitter range, which none of the fixtures above reach. This
        // one does, so the bound is frozen across processes too.
        (
            "fastOrnamentsAndGraceNotes/intensity-100",
            MusicXMLScoreFixtures.fastOrnamentsAndGraceNotes(),
            RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100)
            )
        ),
        // Phrase expression (REQ-003) is a second realization stage with its
        // own bypass, so the frozen set covers both of its states and not only
        // the default. Without the `expression-off` row, a change that quietly
        // made the bypass stop bypassing would move no digest here at all.
        (
            "expressiveKeyboardPiece/expression-off",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            .humanizedWithoutExpression
        ),
        (
            "expressiveKeyboardPiece/expression-100",
            MusicXMLScoreFixtures.expressiveKeyboardPiece(),
            RealizationSettings(expression: ExpressionSettings(isEnabled: true, amount: 100))
        ),
        // Expression alone, with the noise switched off: the only thing
        // separating these bytes from the literal reading of the score is the
        // phrasing, so this digest moves when — and only when — the phrasing
        // itself changes.
        (
            "stringQuartetMovement/expression-only",
            MusicXMLScoreFixtures.stringQuartetMovement(),
            RealizationSettings(humanization: .off, expression: .standard)
        ),
        (
            "keyboardFugueExposition/expression-100",
            MusicXMLScoreFixtures.keyboardFugueExposition(),
            RealizationSettings(
                humanization: HumanizationSettings(isEnabled: true, intensity: 100),
                expression: ExpressionSettings(isEnabled: true, amount: 100)
            )
        )
    ]

    func testTheRealisedTimelineBytesAreFrozenAcrossProcesses() throws {
        let compiler = ScoreCompiler()
        let realizer = PerformanceRealizer()

        for testCase in Self.frozenCases {
            let score = try compiler.compile(pieceID: "frozen", musicXML: testCase.data)
            let timeline = realizer.realize(score, settings: testCase.settings)
            let digest = MusicXMLImporter.sha256Hex(try timeline.canonicalData())
            XCTAssertEqual(
                digest,
                Self.frozenTimelineDigests[testCase.name],
                "\(testCase.name): canonical timeline bytes changed. If the realization was "
                    + "changed deliberately, run the suite twice and update this digest only "
                    + "when both runs agree; if the two runs disagree, something unsorted "
                    + "reached the output path."
            )
        }
    }

    /// Every source file that makes up the realization path.
    private static let realizationSourceFiles = [
        "ScoreExpression.swift",
        "RealizationSettings.swift",
        "SeededJitter.swift",
        "PerformanceTimeline.swift",
        "PerformanceRealizer.swift",
        "PerformanceLineRealization.swift",
        "PerformanceOrnaments.swift",
        "PerformanceHumanization.swift",
        "PerformancePhrasing.swift"
    ]

    /// APIs whose result depends on when, where, or on which run the code is
    /// executed.
    private static let nondeterministicSymbols = [
        "Date(",
        "Date.now",
        "DispatchTime",
        "CFAbsoluteTime",
        "mach_absolute_time",
        "ProcessInfo",
        "getenv",
        "random",
        "Random",
        "arc4",
        "UUID(",
        "shuffled",
        "Task.sleep"
    ]

    private static func repositoryRoot() throws -> URL {
        var candidate = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = candidate.appending(path: "Synth.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw RepositoryRootNotFound(searchedUpwardsFrom: #filePath)
    }

    struct RepositoryRootNotFound: Error, CustomStringConvertible {
        let searchedUpwardsFrom: String
        var description: String {
            "Could not find the directory containing Synth.xcodeproj above \(searchedUpwardsFrom); "
                + "the realization purity guard cannot run."
        }
    }

    func testNoRealisationSourceFileTouchesTheClockTheEnvironmentOrChance() throws {
        let sourceDirectory = try Self.repositoryRoot()
            .appending(path: "SynthKit")
            .resolvingSymlinksInPath()

        for fileName in Self.realizationSourceFiles {
            let url = sourceDirectory.appending(path: fileName)
            let source = try String(contentsOf: url, encoding: .utf8)
            for symbol in Self.nondeterministicSymbols where source.contains(symbol) {
                XCTFail("\(fileName) references the nondeterministic symbol \(symbol)")
            }
        }
    }

    func testTheGuardIsActuallyLookingAtTheRealiserAndNotAnEmptyList() throws {
        let sourceDirectory = try Self.repositoryRoot().appending(path: "SynthKit")
        for fileName in Self.realizationSourceFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: sourceDirectory.appending(path: fileName).path(percentEncoded: false)
                ),
                "\(fileName) is listed in the purity guard but does not exist"
            )
        }
    }

    /// The seed is a function of the configuration and nothing else, and it is
    /// stable across launches — which `Hasher` would not be.
    func testTheSeedIsAStableFunctionOfTheConfiguration() {
        let settings = RealizationSettings(
            presetIdentifier: "preset-1",
            humanization: HumanizationSettings(isEnabled: true, intensity: 40)
        )
        let hex = SeededJitter.seedHex(
            pieceID: "piece", contentSHA256: "abc", settings: settings
        )
        XCTAssertEqual(
            hex,
            "b4dfd3ba080228209530c94b5ab1ffddbd8107ceac66870550565ddd10c10ec7",
            "the seed derivation changed; every stored interpretation moves with it"
        )
        XCTAssertEqual(
            hex,
            SeededJitter.seedHex(pieceID: "piece", contentSHA256: "abc", settings: settings)
        )
    }

    /// One key must give one value, whatever else has been asked for before.
    func testTheJitterFunctionHasNoMemory() {
        let seed = SeededJitter.seed(
            pieceID: "piece", contentSHA256: "abc", settings: .standard
        )
        let expected = SeededJitter.value(seed: seed, key: "line|3|48|60|notated|7")
        for index in 0..<64 {
            _ = SeededJitter.value(seed: seed, key: "other-\(index)")
        }
        XCTAssertEqual(SeededJitter.value(seed: seed, key: "line|3|48|60|notated|7"), expected)
    }

    func testSignedValuesStayInsideTheirMagnitude() {
        let seed = SeededJitter.seed(pieceID: "p", contentSHA256: "c", settings: .standard)
        for index in 0..<512 {
            let value = SeededJitter.signed(
                SeededJitter.value(seed: seed, key: "k\(index)"),
                magnitude: 25
            )
            XCTAssertTrue((-25...25).contains(value), "\(value) is outside the magnitude")
        }
        XCTAssertEqual(SeededJitter.signed(12_345, magnitude: 0), 0)
    }

    /// The spread has to actually spread: a "seeded" function that returned
    /// the same value for every key would pass every determinism test and
    /// produce no humanization at all.
    func testTheJitterActuallyVaries() {
        let seed = SeededJitter.seed(pieceID: "p", contentSHA256: "c", settings: .standard)
        let values = (0..<256).map {
            SeededJitter.signed(SeededJitter.value(seed: seed, key: "k\($0)"), magnitude: 25)
        }
        XCTAssertGreaterThan(Set(values).count, 30, "the spread is degenerate")
        XCTAssertTrue(values.contains { $0 < 0 } && values.contains { $0 > 0 })
    }
}
