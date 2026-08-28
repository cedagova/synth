import XCTest
@testable import SynthKit

/// The purity invariant PLY001 has to hold: compilation reads no clock, draws
/// no random numbers, and consults no environment.
///
/// Three independent guards, because each one alone has a hole:
///
/// 1. **frozen model digests** — the exact SHA-256 of `canonicalData()` for
///    three fixtures. This is the only guard that spans process launches, and
///    it is the one the acceptance criterion actually asks for;
/// 2. **behaviour** — the same bytes compile to the same model under repeat,
///    interleaved and concurrent use; and
/// 3. **source** — no file in the compiler even mentions a nondeterministic
///    API.
///
/// Why (1) has to exist: Swift seeds `Hasher` **once per process**, so
/// `Dictionary` and `Set` iteration order is stable within a run and varies
/// only between launches. Every in-process byte-equality check on this
/// branch — here and in `ScoreCompilerTests` — would therefore pass a
/// compiler whose output came straight out of an unsorted dictionary.
/// A digest a fresh test process must reproduce is what closes that.
final class ScoreCompilerPurityTests: XCTestCase {
    /// The canonical model bytes each fixture must always produce.
    ///
    /// These are not magic constants to re-record when they fail. They fail
    /// for exactly two reasons:
    ///
    /// - the model gained, lost or reordered a field, in which case the new
    ///   digests are correct and the change is deliberate; or
    /// - something nondeterministic reached the output path, in which case the
    ///   digest will differ between launches rather than consistently, and
    ///   the fix is to sort it.
    ///
    /// Tell them apart by running the suite twice in two processes: a
    /// deliberate change gives the same wrong digest twice.
    private static let frozenModelDigests: [String: String] = [
        "repeatsVoltasAndDaCapo": "1e183de8f7940725b5fbdb6d791c0450aeed99f39d16282cb0f90bbbf368b266",
        "keyboardFugueExposition": "a2d5cef0a066a541e4213204f282942254a5d45cdfd7995d97928364159f73ce",
        "tempoChangesAndFermata": "bc3ca2f1b71cd8d1bdaeb7a1d5cdc761209722845608891d00cf580b5cac6145"
    ]

    func testTheCompiledModelBytesAreFrozenAcrossProcesses() throws {
        let fixtures: [(name: String, data: Data)] = [
            ("repeatsVoltasAndDaCapo", MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()),
            ("keyboardFugueExposition", MusicXMLScoreFixtures.keyboardFugueExposition()),
            ("tempoChangesAndFermata", MusicXMLScoreFixtures.tempoChangesAndFermata())
        ]

        let compiler = ScoreCompiler()
        for fixture in fixtures {
            let score = try compiler.compile(pieceID: "frozen", musicXML: fixture.data)
            let digest = MusicXMLImporter.sha256Hex(try score.canonicalData())
            XCTAssertEqual(
                digest,
                Self.frozenModelDigests[fixture.name],
                "\(fixture.name): canonical model bytes changed. If the model was changed "
                    + "deliberately, run the suite twice and update this digest only when both "
                    + "runs agree; if the two runs disagree, something unsorted reached the "
                    + "output path."
            )
        }
    }

    /// Every source file that makes up the compilation path.
    private static let compilerSourceFiles = [
        "MusicXMLDocument.swift",
        "ScoreModel.swift",
        "ScoreStructure.swift",
        "ScoreCompiler.swift",
        "TempoMap.swift",
        "NotationReport.swift"
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
                + "the compiler purity guard cannot run."
        }
    }

    func testNoCompilerSourceFileTouchesTheClockTheEnvironmentOrRandomness() throws {
        let sourceDirectory = try Self.repositoryRoot()
            .appending(path: "SynthKit")
            .resolvingSymlinksInPath()

        for fileName in Self.compilerSourceFiles {
            let url = sourceDirectory.appending(path: fileName)
            let source = try String(contentsOf: url, encoding: .utf8)
            for symbol in Self.nondeterministicSymbols where source.contains(symbol) {
                XCTFail("\(fileName) references the nondeterministic symbol \(symbol)")
            }
        }
    }

    func testTheGuardIsActuallyLookingAtTheCompilerAndNotAnEmptyList() throws {
        let sourceDirectory = try Self.repositoryRoot().appending(path: "SynthKit")
        for fileName in Self.compilerSourceFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: sourceDirectory.appending(path: fileName).path(percentEncoded: false)
                ),
                "\(fileName) is listed in the purity guard but does not exist"
            )
        }
    }

    /// Compiling the same bytes many times in a row, interleaved with other
    /// compilations, must not drift.
    ///
    /// In-process only — a hash seed is shared by everything in one launch, so
    /// this catches a mutable cache or state leaking between calls, and
    /// `testTheCompiledModelBytesAreFrozenAcrossProcesses` is what catches
    /// unsorted output.
    func testRepeatedInterleavedCompilationsNeverDrift() throws {
        let compiler = ScoreCompiler()
        let quartet = MusicXMLScoreFixtures.stringQuartetMovement()
        let fugue = MusicXMLScoreFixtures.keyboardFugueExposition()
        let structure = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()

        let baseline = try compiler.compile(pieceID: "p", musicXML: quartet).canonicalData()
        for _ in 0..<12 {
            _ = try compiler.compile(pieceID: "other", musicXML: fugue)
            _ = try compiler.compile(pieceID: "other", musicXML: structure)
            XCTAssertEqual(
                try compiler.compile(pieceID: "p", musicXML: quartet).canonicalData(),
                baseline
            )
        }
    }

    /// Two compilers, used from different tasks at the same time, must agree.
    /// `ScoreCompiler` is `Sendable` and holds nothing; this is what that
    /// claim means in practice. Also in-process — task groups share the
    /// launch, and therefore the hash seed.
    func testConcurrentCompilationsAgree() async throws {
        let data = MusicXMLScoreFixtures.orchestralExcerpt(partCount: 6, measureCount: 8)
        let expected = try ScoreCompiler().compile(pieceID: "p", musicXML: data).canonicalData()

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? ScoreCompiler().compile(pieceID: "p", musicXML: data).canonicalData()
                }
            }
            var collected: [Data?] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        for result in results { XCTAssertEqual(result, expected) }
    }

    /// Only the piece identifier and the bytes may reach the model.
    func testTheSameScoreUnderTwoPieceIdentifiersDiffersOnlyByThatIdentifier() throws {
        let data = MusicXMLScoreFixtures.repeatsVoltasAndDaCapo()
        let first = try ScoreCompiler().compile(pieceID: "piece-a", musicXML: data)
        let second = try ScoreCompiler().compile(pieceID: "piece-b", musicXML: data)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lines, second.lines, "line identity does not depend on the piece")
        XCTAssertEqual(first.playbackMeasures, second.playbackMeasures)
        XCTAssertEqual(first.tempoMap, second.tempoMap)
        XCTAssertEqual(first.report, second.report)
    }
}
