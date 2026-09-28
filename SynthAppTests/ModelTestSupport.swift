import XCTest
@testable import Synth
import SynthKit

/// A real, migrated store in a temporary container, for the per-model suites.
///
/// **Why a real store rather than a fake.** Every app-layer model is a thin
/// layer of interaction over `LibraryStore`: the order it touches things in,
/// and what it tells the owner when a write fails. A fake store would prove the
/// model calls a method; a real one proves the owner's state actually changed,
/// which is what these suites assert.
///
/// **Failures are injected in SQLite itself**, with a `TEMP` trigger that
/// aborts one kind of write on one table. A temp trigger lives only on this
/// connection and vanishes with it, needs no production seam, and makes the
/// store fail exactly the way a damaged or full database would — at the write,
/// with the transaction rolled back — so the model's own failure handling is
/// what runs.
@MainActor
final class TemporaryLibrary {
    let directory: URL
    let store: LibraryStore

    /// The message the injected failure raises, so a test can recognise it in
    /// the alert the owner sees.
    static let injectedFailure = "Injected test failure"

    init(label: String = #fileID) throws {
        let safeLabel = label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".swift", with: "")
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "\(safeLabel)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try LibraryStore.open(
            container: AppContainer(rootURL: directory.appending(path: "container")),
            appVersion: "test"
        )
    }

    func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Failure injection

    enum Write: String {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    /// Makes every `write` to `table` fail until `allowWrites` is called.
    func failWrites(_ write: Write, on table: String) throws {
        try store.database.executeScript("""
            CREATE TEMP TRIGGER IF NOT EXISTS \(Self.triggerName(write, table))
            BEFORE \(write.rawValue) ON main.\(table)
            BEGIN SELECT RAISE(ABORT, '\(Self.injectedFailure)'); END;
            """)
    }

    func allowWrites(_ write: Write, on table: String) throws {
        try store.database.executeScript(
            "DROP TRIGGER IF EXISTS temp.\(Self.triggerName(write, table));"
        )
    }

    private static func triggerName(_ write: Write, _ table: String) -> String {
        "test_fail_\(write.rawValue.lowercased())_\(table)"
    }

    // MARK: Pieces

    /// Writes `musicXML` to a file and returns its URL, without importing it.
    func sourceFile(named name: String, musicXML: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(musicXML.utf8).write(to: url)
        return url
    }

    /// Imports a score straight through the store's importer.
    @discardableResult
    func importPiece(named name: String = "fixture.musicxml", musicXML: String) throws -> PieceRecord {
        let url = try sourceFile(named: name, musicXML: musicXML)
        return try store.makeImporter().importPiece(from: url).piece
    }

    // MARK: Instruments

    /// Installs one real catalog instrument with placeholder samples.
    ///
    /// The same technique `AppModelWiringTests.installFixtureCello` uses: the
    /// store resolves an instrument by asking the catalog where its SFZ lives
    /// and looking on disk, so writing the files the entry names is the whole
    /// of what a download does as far as the models are concerned.
    @discardableResult
    func installFixtureCello() throws -> InstrumentReference {
        let library = try XCTUnwrap(InstrumentCatalog.library(withIdentifier: "vsco2-ce"))
        let coverage = try XCTUnwrap(
            library.coverage.first { $0.identifier == "vsco2.cello.section" }
        )
        let root = try store.instruments.stagingArea.installedURL(forLibraryID: library.identifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try Self.mono16BitWave(seconds: 0.25).write(to: root.appending(path: "cello.wav"))
        for path in coverage.allSFZPaths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try """
                <group> ampeg_attack=0 ampeg_release=0.2
                <region> sample=cello.wav lokey=36 hikey=72 pitch_keycenter=57
                """.write(to: url, atomically: true, encoding: .utf8)
        }
        try store.instruments.recordInstall(of: library)
        return InstrumentReference(library: library, coverage: coverage)
    }

    /// A short 44.1 kHz mono sine as a canonical RIFF/WAVE file.
    static func mono16BitWave(seconds: Double, hertz: Double = 220) -> Data {
        let sampleRate = 44_100
        let frames = Int(Double(sampleRate) * seconds)

        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = sin(2 * .pi * hertz * Double(frame) / Double(sampleRate)) * 0.4
            let quantised = Int16(max(-32_768, min(32_767, (value * 32_767).rounded())))
            withUnsafeBytes(of: quantised.littleEndian) { samples.append(contentsOf: $0) }
        }

        func chunk(_ identifier: String, _ payload: Data) -> Data {
            var out = Data(identifier.utf8)
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(payload)
            if payload.count % 2 == 1 { out.append(0) }
            return out
        }

        var format = Data()
        for value in [UInt16(1), UInt16(1)] {
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }
        for value in [UInt32(sampleRate), UInt32(sampleRate * 2)] {
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }
        for value in [UInt16(2), UInt16(16)] {
            withUnsafeBytes(of: value.littleEndian) { format.append(contentsOf: $0) }
        }

        let body = Data("WAVE".utf8) + chunk("fmt ", format) + chunk("data", samples)
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        return file + body
    }
}

/// Small MusicXML scores for the model suites.
enum ModelFixtures {
    /// A score with one part per name, each `measures` measures of four
    /// quarter notes. Part names are real instrument names so the
    /// Switched-On mapping and the line names have something to read.
    static func score(
        title: String = "Model Fixture",
        composer: String? = nil,
        parts: [String] = ["Flute"],
        measures: Int = 4
    ) -> String {
        let partList = parts.enumerated().map { index, name in
            "<score-part id=\"P\(index + 1)\"><part-name>\(name)</part-name></score-part>"
        }.joined(separator: "\n")

        let partBodies = parts.indices.map { index in
            let octave = index == 0 ? 5 : 3
            let clef = index == 0
                ? "<clef><sign>G</sign><line>2</line></clef>"
                : "<clef><sign>F</sign><line>4</line></clef>"
            let body = (1...measures).map { number in
                let attributes = number == 1
                    ? """
                      <attributes>
                        <divisions>4</divisions>
                        <key><fifths>0</fifths></key>
                        <time><beats>4</beats><beat-type>4</beat-type></time>
                        \(clef)
                      </attributes>
                      """
                    : ""
                let notes = ["C", "D", "E", "F"].map { step in
                    """
                    <note>
                      <pitch><step>\(step)</step><octave>\(octave)</octave></pitch>
                      <duration>4</duration><type>quarter</type>
                    </note>
                    """
                }.joined()
                return "<measure number=\"\(number)\">\(attributes)\(notes)</measure>"
            }.joined(separator: "\n")
            return "<part id=\"P\(index + 1)\">\n\(body)\n</part>"
        }.joined(separator: "\n")

        let identification = composer.map {
            "<identification><creator type=\"composer\">\($0)</creator></identification>"
        } ?? ""

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <score-partwise version="4.0">
              <work><work-title>\(title)</work-title></work>
              \(identification)
              <part-list>
            \(partList)
              </part-list>
            \(partBodies)
            </score-partwise>
            """
    }
}
