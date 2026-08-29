import Foundation
import XCTest
@testable import SynthKit

/// REQ-025 across a **real relaunch**: two separate processes over one
/// container on disk.
///
/// Every other durability test in this suite closes the store and opens it
/// again inside one process. That proves the bytes reached SQLite, and it is
/// the right check for most claims — but "presets survive relaunches
/// indefinitely" is a claim about a *new process*, and a store re-opened by the
/// same executable still shares its page cache, its WAL handle and every
/// statically initialised value in the module. This runs the write in one
/// process and the verification in another, which is the only arrangement in
/// which nothing in memory can be doing the remembering.
///
/// Opt in, because it needs two invocations and a container path they share:
///
/// ```
/// export SYNTH_PRESET_DURABILITY_CONTAINER=/tmp/synth-durability
/// rm -rf "$SYNTH_PRESET_DURABILITY_CONTAINER"
/// xctest -XCTest SynthKitTests.PresetProcessDurabilityTests/testPhaseOneWritesTheLibrary  <bundle>
/// xctest -XCTest SynthKitTests.PresetProcessDurabilityTests/testPhaseTwoVerifiesAfterRelaunch <bundle>
/// ```
///
/// Both phases skip with a reason when the variable is unset, so an ordinary
/// run is unaffected.
final class PresetProcessDurabilityTests: XCTestCase {
    /// The name the phase-one process renames the fugue's top line to.
    private static let renamedLine = "Soprano"

    /// The patch phase one assigns, then deletes, so phase two finds an
    /// embedded copy of it.
    private static let embeddedCutoff: Double = 2_468

    private static let secondPresetName = "Bright"

    /// Where phase one records the digest of the audio it heard, for phase two
    /// to reproduce.
    private static let digestFileName = "durability-render.sha256"

    private func containerRoot() throws -> URL {
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SYNTH_PRESET_DURABILITY_CONTAINER"],
            "unreachable"
        )
        return URL(filePath: path)
    }

    private func requireOptIn() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SYNTH_PRESET_DURABILITY_CONTAINER"] == nil,
            "Set SYNTH_PRESET_DURABILITY_CONTAINER to run the two-process durability check."
        )
    }

    private func open(_ root: URL) throws -> LibraryStore {
        try LibraryStore.open(
            container: AppContainer(rootURL: root.appending(path: "Synth")),
            appVersion: "1.0 (1)"
        )
    }

    private func patch(cutoff: Double) -> SynthPatch {
        SynthPatch(
            identifier: "ignored.by.the.library",
            name: "Ignored By The Library",
            oscillators: [
                .init(type: .analog, analogShape: .saw, level: 0.9),
                .init(level: 0),
                .init(level: 0)
            ],
            filter: .init(isEnabled: true, type: .lowpass, poles: 2, cutoffHertz: cutoff),
            outputLevel: 0.25
        )
    }

    private func renderDigest(_ store: LibraryStore, _ score: CompiledScore) throws -> String {
        let performance = try store.openActivePreset(for: score)
        let audio = try PlaybackEngine.renderTimelineOffline(
            PerformanceRealizer().realize(score, settings: .literal),
            voices: performance.voiceAssignment()
        ) { engine in performance.applyMixer(to: engine) }
        XCTAssertGreaterThan(audio.peak(), 0.001, "The piece rendered as silence.")
        return SHA256Digest.hexString(audio.canonicalData())
    }

    // MARK: Phase one — this process writes

    func testPhaseOneWritesTheLibrary() throws {
        try requireOptIn()
        let root = try containerRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try open(root)
        defer { store.close() }

        let sourceURL = root.appending(path: "fugue.musicxml")
        try MusicXMLScoreFixtures.keyboardFugueExposition().write(to: sourceURL)
        let piece = try store.makeImporter().importPiece(from: sourceURL).piece
        let score = try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)

        let inventory = try store.lineInventory(for: score)
        _ = try store.presets.renameLine(
            try XCTUnwrap(inventory.entries.first), inPieceID: piece.id, to: Self.renamedLine
        )

        var preset = try store.activePreset(for: score)
        let doomed = try store.sounds.create(
            patch: patch(cutoff: Self.embeddedCutoff), named: "Doomed", in: .leads
        )
        preset = try store.presets.assign(
            .library(kind: .synth, soundID: doomed.id), toLine: preset.lines[0].lineID, in: preset
        )
        preset = try store.presets.setMixer(
            LineMixerState(volume: 0.4, pan: -0.6), forLine: preset.lines[1].lineID, in: preset
        )
        _ = try store.presets.duplicate(preset, named: Self.secondPresetName, makeActive: false)

        // The delete that embeds (REQ-029). Nothing after this point writes.
        XCTAssertEqual(try store.presets.usage(ofSoundID: doomed.id).count, 2,
                       "Both the preset and its duplicate should reference the doomed sound.")
        try store.sounds.delete(doomed)

        let digest = try renderDigest(store, score)
        try digest.write(
            to: root.appending(path: Self.digestFileName), atomically: true, encoding: .utf8
        )

        print("""
            Durability phase one — written
              container:     \(root.path(percentEncoded: false))
              piece:         \(piece.id)
              presets:       \(try store.presets.presetCount(forPieceID: piece.id))
              schema:        v\(store.schemaVersion)
              render digest: \(digest)
            """)
    }

    // MARK: Phase two — a different process reads

    func testPhaseTwoVerifiesAfterRelaunch() throws {
        try requireOptIn()
        let root = try containerRoot()

        let store = try open(root)
        defer { store.close() }

        XCTAssertEqual(store.schemaVersion, SchemaMigrator.latestVersion)
        XCTAssertTrue(
            store.migrationOutcome.wasAlreadyCurrent,
            "A relaunch must not migrate a store the previous launch already migrated."
        )

        let piece = try XCTUnwrap(try store.allPieces().first, "The imported piece is gone.")
        let score = try ScoreCompiler().compile(piece: piece, contentStore: store.pieceContent)

        // REQ-005: the rename came back.
        let inventory = try store.lineInventory(for: score)
        XCTAssertEqual(inventory.entries.first?.name, Self.renamedLine)
        XCTAssertEqual(inventory.count, 4)

        // REQ-024: both presets, exactly one active.
        let presets = try store.presets.presets(forPieceID: piece.id)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets.filter(\.isActive).count, 1)
        XCTAssertTrue(presets.contains { $0.name == Self.secondPresetName })

        let active = try XCTUnwrap(try store.presets.activePreset(forPieceID: piece.id))
        XCTAssertEqual(
            active.lines[1].mixer, LineMixerState(volume: 0.4, pan: -0.6),
            "The mixer state did not survive the relaunch."
        )

        // REQ-029: the embedded copy came back, complete.
        guard case .embedded(let embedded) = active.lines[0].assignment else {
            return XCTFail("Line 1 should hold an embedded copy, not \(active.lines[0].assignment)")
        }
        XCTAssertEqual(embedded.name, "Doomed")
        XCTAssertEqual(embedded.patch.filter.cutoffHertz, Self.embeddedCutoff)
        XCTAssertEqual(try store.sounds.userSoundCount(), 0, "The deleted sound is still a row.")
        XCTAssertTrue(try store.sounds.isRetired(id: embedded.originalSoundID))

        // …and the piece still sounds exactly as it did in the other process.
        let expected = try String(
            contentsOf: root.appending(path: Self.digestFileName), encoding: .utf8
        )
        let digest = try renderDigest(store, score)
        XCTAssertEqual(
            digest, expected,
            "The piece does not sound the way the previous process left it."
        )

        print("""
            Durability phase two — verified in a new process
              container:     \(root.path(percentEncoded: false))
              schema:        v\(store.schemaVersion) (no migration needed)
              line rename:   \(inventory.entries.first?.name ?? "—")
              presets:       \(presets.count), active “\(active.name)”
              embedded:      “\(embedded.name)” at \(embedded.patch.filter.cutoffHertz) Hz
              render digest: \(digest) (matches)
            """)
    }
}
