import XCTest
@testable import SynthKit

/// The purity invariant PLY001 has to hold: compilation reads no clock, draws
/// no random numbers, and consults no environment.
///
/// Two independent guards, in the same shape as the no-network baseline:
///
/// 1. behaviour — the same bytes compile to the same model, repeatedly and
///    under conditions that would expose a hidden dependency; and
/// 2. source — no file in the compiler even mentions a nondeterministic API.
///
/// The behavioural guard alone would pass a compiler that only reads the clock
/// once a day; the source guard alone would pass one that hides the call
/// behind a helper. Together they are hard to defeat by accident.
final class ScoreCompilerPurityTests: XCTestCase {
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
    /// compilations, must not drift. A cache keyed on something mutable, or a
    /// dictionary iterated without sorting, would show up here.
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
    /// claim means in practice.
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
