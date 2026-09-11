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
    /// Moved a third time on #80: the articulation shortening gained a
    /// microsecond residual on top of its tick-grid reading, so every plain or
    /// articulated note's sounding length changed by whatever the grid had
    /// floored — which reaches every row here, in every expression state.
    ///
    /// All were refrozen from two agreeing runs in separate processes. The claim
    /// that nothing *else* moved in the bypass state is a separate and stronger
    /// one, and `PerformanceExpressionTests` holds it two ways: the fugue
    /// fixture's bypass digests are still the ones recorded before EXP001
    /// existed — it carries no slur, so articulation cannot reach it — and every
    /// fixture's notes, onset times, velocities and measure indices are held
    /// against digests taken on the collector base with the lengths left out.
    private static let frozenTimelineDigests: [String: String] = [
        "ornamentStudy/literal":
            "62ccbeb40e15ee00f1ceaff8da18b6664916e4e97dfc808d4eac294b776f58cf",
        "expressiveKeyboardPiece/literal":
            "8e4f006110dc5e9da65f1066177c91abd8cb79ae36a474b7aa31fa2f5508f0e7",
        "expressiveKeyboardPiece/standard":
            "023d8474d081606947a2f8306dc3a0b38140dd646c9792994d08d7f5c0996d40",
        "expressiveKeyboardPiece/intensity-100":
            "c8fca2ef4e963775d20e07d95ed60d06c340029b1cf7fca0000e556f56234fa2",
        "stringQuartetMovement/standard":
            "bfe168ac4e4da513bd241d1c7399a09c5dae1cb79860b22d60deaef9bff90fad",
        "fastOrnamentsAndGraceNotes/intensity-100":
            "1747489fce171bccab874e99f29014494dffae64df07e2d842dca144982786de",
        "expressiveKeyboardPiece/expression-off":
            "63d0a8add80f7dda672d1546b9eef8a5687aa29489d299fe8188f440e0436cf9",
        "expressiveKeyboardPiece/expression-100":
            "ca769b06961ca99aa5381532fb56529d230cf42d053bc58f5dac3e182a50616b",
        "stringQuartetMovement/expression-only":
            "3c83f5abbd172bf888903362aefabcff1bc037657c95b4a75852e6b493bc5557",
        "keyboardFugueExposition/expression-100":
            "414895aed5fcef0de372bc075e7691345e15a3fa75cc0ebec16514244894c5fb",
        "articulationAndSlurStudy/literal": "0041dce40dd09bab681fac72c4ea65a73c4919d209fcf09435e25064a96c7806",
        "articulationAndSlurStudy/expression-100": "055a0fd9df7a74b8107e2307fc343fe598657d14b19d45380a0af15d2dc0d27e",
        "melodyOverAccompaniment/expression-off": "29e38ba4e33b957b640002fa5358e9795649e4da62c1b36bf3a1ddd93e919f95",
        "melodyOverAccompaniment/expression-100": "154268f4c5e2bfa08c417c62ff906a31f897f2dc1f1a6b78899fb89050ac42b3"
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
