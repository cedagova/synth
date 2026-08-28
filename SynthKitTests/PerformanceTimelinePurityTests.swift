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
    private static let frozenTimelineDigests: [String: String] = [
        "ornamentStudy/literal":
            "18fe0fbe1c4d1b95fb2fd4ab8dae21c65b4826e36bf574431667516f27e48173",
        "expressiveKeyboardPiece/literal":
            "86913f7878a67733fe3b6dccbfc5609bb79c742beee573b5cac6c352d2db5f60",
        "expressiveKeyboardPiece/standard":
            "88d1fd0a513b8ffe17a5c903c7f76e4f43b04ce9e4b0d4b23dc3321805b6bf6a",
        "expressiveKeyboardPiece/intensity-100":
            "8a9c7f6b0faf3f22f806ded63e07dac9c4088abad0d6e4a0cc536552a874c8b3",
        "stringQuartetMovement/standard":
            "5fe7df695f51c66db4154fbc8df2fb69db72f3645476709094cdc90bff7c53a2",
        "fastOrnamentsAndGraceNotes/intensity-100":
            "39a2c2d97dedf993b674d371c67c7835d42a2000f3ac6826978b211a2c5ff727"
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
        "PerformanceHumanization.swift"
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
