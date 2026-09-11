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
    /// Moved once on EXP001, when `RealizationSettings` gained its `expression`
    /// field and the canonical bytes changed even where not one note did. Moved
    /// again on EXP002, and this time the music really did change, for two
    /// deliberate reasons:
    ///
    /// - **the legato overlap** stopped being `ticksPerQuarter / 32` — a fraction
    ///   of whatever one tick happens to be on the score in front of it, which is
    ///   a whole sixteenth note at four divisions to the quarter — and became a
    ///   bounded number of microseconds. Articulation is written notation and so
    ///   always on, which is why this reaches the `literal` and `expression-off`
    ///   rows as well: every fixture here that carries a slur moved; and
    /// - **the per-passage line balance** (`PerformanceBalance`) shades the
    ///   leading line above the accompaniment, which moves every row realized
    ///   with expression on whose texture names a leader.
    ///
    /// Both were refrozen from two agreeing runs in separate processes. The claim
    /// that nothing *else* moved in the bypass state is a separate and stronger
    /// one, and `PerformanceExpressionTests` holds it two ways: the fugue
    /// fixture's bypass digests are still the ones recorded before EXP001
    /// existed — it carries no slur, so articulation cannot reach it — and every
    /// fixture's notes, onset times, velocities and measure indices are held
    /// against digests taken on the collector base with the lengths left out.
    private static let frozenTimelineDigests: [String: String] = [
        "ornamentStudy/literal":
            "85f8ca7d4f5683f0e9b3c30c8bef27471b5662c411d30f0b37ff419cbcb31d29",
        "expressiveKeyboardPiece/literal":
            "db894d3b4499133bb81898fe74b7c734ded0bf99c58cdfa96d684b2dae6db8d7",
        "expressiveKeyboardPiece/standard":
            "c0de18f380cce798513a6e554692935db95700590a28a97fb41984ba2b146c24",
        "expressiveKeyboardPiece/intensity-100":
            "7db183a6a665ef81eb00c0c5aabc9d9a2f0be181ea1a9acf5b5f25e16cc87416",
        "stringQuartetMovement/standard":
            "e26d01c2ce88976849bab6efe6bb779bd8ac71aa4c0f23981b2a080dc60c606c",
        "fastOrnamentsAndGraceNotes/intensity-100":
            "bcfa84f69f4c6d1e3820e42fe2702709a3d9701ba77397a73a7b10df671caee9",
        "expressiveKeyboardPiece/expression-off":
            "500e3de196a927e9dfdac8200b15648b8bb48967fbd1d63a734a8570472ff0fc",
        "expressiveKeyboardPiece/expression-100":
            "6972fe0bd1434637026c6580dc990f4d510d0127972f58033581a164049c1172",
        "stringQuartetMovement/expression-only":
            "a220b2f1af69f22e9d612e81306c6bcb7f18260e2f56ec810f280dd52605d2d4",
        "keyboardFugueExposition/expression-100":
            "b9d0cd67068f87b6aa2cdca3cbb2eefa54f3999b78fe900e4e323ea971d4f2ce",
        "articulationAndSlurStudy/literal": "9892001882eaed6f8f42cb43c0ac097c824b9575ad2280b430609170a85a4151",
        "articulationAndSlurStudy/expression-100": "2c93bee833576b25efa2d028f79487af92e4aa52931a9bd984b1be3e7de4ae81",
        "melodyOverAccompaniment/expression-off": "c216e6e05cf4429ae9edd6b17cbe31e3d8daa6d2ebd734a2f335134940d3f5c8",
        "melodyOverAccompaniment/expression-100": "8899911065240758f6d9f61abfe9c0c73aea2b1160c8d357e68c29f5b9870bf4"
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
        ),
        // Articulation (EXP002) is always on, so its reading has to be frozen in
        // the bypass state — where no other stage is running and nothing else
        // could be moving these bytes. The study writes a staccato measure, an
        // accent measure, a tenuto measure and a slurred measure, so one digest
        // covers the shortening table, the détaché default, the legato overlap
        // and the rule that a written mark beats the slur.
        (
            "articulationAndSlurStudy/literal",
            MusicXMLScoreFixtures.articulationAndSlurStudy(),
            .literal
        ),
        (
            "articulationAndSlurStudy/expression-100",
            MusicXMLScoreFixtures.articulationAndSlurStudy(),
            RealizationSettings(
                humanization: .off,
                expression: ExpressionSettings(isEnabled: true, amount: 100)
            )
        ),
        // Per-passage line balance (EXP002) on the fixture built for it: a melody
        // over an accompaniment, where a leader is found in every passage. The
        // `expression-off` companion is the bypass — the balance term has to be
        // absent from it, and a balance that stopped being guarded would move it.
        (
            "melodyOverAccompaniment/expression-off",
            MusicXMLScoreFixtures.melodyOverAccompaniment(),
            .humanizedWithoutExpression
        ),
        (
            "melodyOverAccompaniment/expression-100",
            MusicXMLScoreFixtures.melodyOverAccompaniment(),
            RealizationSettings(expression: ExpressionSettings(isEnabled: true, amount: 100))
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
        "PerformancePhrasing.swift",
        "PerformanceBalance.swift"
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
