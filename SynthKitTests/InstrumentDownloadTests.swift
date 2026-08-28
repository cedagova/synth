import CryptoKit
import Foundation
import XCTest
@testable import SynthKit

/// The download manager against a real loopback HTTP server.
///
/// Every acceptance criterion about *transfers* is here, and each one is proved
/// against bytes that really crossed a socket rather than against a stubbed
/// protocol:
///
/// * an interrupted transfer resumes from where it stopped (REQ-022);
/// * a removed library re-downloads (REQ-022);
/// * a checksum mismatch discards the content, reports it, and leaves it
///   re-downloadable;
/// * a disk-full fails cleanly with no partial asset state;
/// * an unreachable source gives a retryable error and corrupts nothing.
final class InstrumentDownloadTests: XCTestCase {
    private var server: CatalogFixtureServer!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try CatalogFixtureServer()
        try server.start()
        root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "synth-ins001-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    /// Deterministic pseudo-random bytes: compressible enough to be quick,
    /// varied enough that a wrongly assembled file cannot accidentally match.
    private func payload(byteCount: Int, seed: UInt64) -> Data {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8((state >> 33) & 0xFF))
        }
        return Data(bytes)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func gitBlobHex(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A catalog library of `assetCount` plain files served by the fixture.
    private func makeLibrary(
        identifier: String = "fixture-lib",
        assetCount: Int = 3,
        byteCountEach: Int = 40_000,
        useGitBlobDigests: Bool = false
    ) -> (library: CatalogLibrary, payloads: [String: Data]) {
        var assets: [CatalogAsset] = []
        var payloads: [String: Data] = [:]

        for index in 0..<assetCount {
            let name = "asset\(index).wav"
            let data = payload(byteCount: byteCountEach, seed: UInt64(index) &+ 7)
            payloads[name] = data
            server.serve(data, at: name)
            assets.append(
                CatalogAsset(
                    identifier: "Samples/\(name)",
                    sourceURL: server.url(for: name).absoluteString,
                    byteCount: Int64(data.count),
                    digest: useGitBlobDigests ? .gitBlob(gitBlobHex(data)) : .sha256(sha256Hex(data)),
                    payload: .file(path: "Samples/\(name)")
                )
            )
        }

        // One tiny SFZ so the library has a real entry point to resolve.
        let sfz = Data("<control>\ndefault_path=Samples/\n".utf8)
        payloads["fixture.sfz"] = sfz
        server.serve(sfz, at: "fixture.sfz")
        assets.append(
            CatalogAsset(
                identifier: "fixture.sfz",
                sourceURL: server.url(for: "fixture.sfz").absoluteString,
                byteCount: Int64(sfz.count),
                digest: .sha256(sha256Hex(sfz)),
                payload: .file(path: "fixture.sfz")
            )
        )

        let library = CatalogLibrary(
            identifier: identifier,
            name: "Fixture Library",
            publisher: "The Test Suite",
            summary: "Not a real instrument.",
            licence: InstrumentLicence(
                spdxIdentifier: "CC0-1.0",
                name: "Creative Commons Zero 1.0",
                textURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                requiredAttribution: "",
                redistribution: .mirrorable
            ),
            homepageURL: "https://example.invalid/",
            assets: assets,
            coverage: [
                InstrumentCoverage(
                    identifier: "fixture.instrument",
                    name: "Fixture instrument",
                    family: .strings,
                    sfzPath: "fixture.sfz",
                    dynamicLayerCount: 1
                )
            ]
        )
        return (library, payloads)
    }

    private func makeStore(
        catalog: [CatalogLibrary],
        opener: StagingFileOpening = FileSystemStagingFileOpener()
    ) throws -> (store: InstrumentAssetStore, database: SQLiteDatabase, assetsURL: URL) {
        let container = AppContainer(rootURL: root.appending(path: "Synth"))
        try container.prepare()
        let database = try SQLiteDatabase.open(at: container.databaseURL)
        try SchemaMigrator.migrate(database, appVersion: "test")
        let store = InstrumentAssetStore(
            database: database,
            assetsRootURL: container.assetsURL,
            catalog: catalog,
            stagingFileOpener: opener
        )
        return (store, database, container.assetsURL)
    }

    // MARK: A complete install

    func testDownloadsVerifiesAndInstallsALibraryAtomically() async throws {
        let (library, payloads) = makeLibrary()
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        XCTAssertEqual(try store.state(of: library), .notDownloaded)

        var lastPhase: InstrumentDownloadProgress.Phase?
        let manager = InstrumentDownloadManager(store: store, transfer: makeFixtureTransfer())
        let phases = PhaseRecorder()
        try await manager.install(library) { progress in
            phases.record(progress.phase)
        }
        lastPhase = phases.all.last

        XCTAssertEqual(lastPhase, .finished)

        // Installed, recorded, and the bytes are exactly what the server has.
        guard case .installed(let installed) = try store.state(of: library) else {
            return XCTFail("The library is not installed.")
        }
        XCTAssertEqual(installed.assetCount, library.assets.count)
        XCTAssertEqual(installed.byteCount, library.downloadByteCount)
        XCTAssertEqual(installed.pinnedManifestDigest, library.pinnedManifestDigest)

        let libraryRoot = assetsURL.appending(path: library.identifier)
        for (name, expected) in payloads {
            let installedPath = name.hasSuffix(".sfz")
                ? libraryRoot.appending(path: name)
                : libraryRoot.appending(path: "Samples").appending(path: name)
            let actual = try Data(contentsOf: installedPath)
            XCTAssertEqual(actual, expected, "\(name) did not install byte-for-byte.")
        }

        // Nothing is left staged, and the instrument resolves.
        XCTAssertEqual(store.stagedByteCount(for: library), 0)
        let instruments = try store.availableInstruments()
        XCTAssertEqual(instruments.count, 1)
        XCTAssertEqual(instruments.first?.coverage.identifier, "fixture.instrument")
    }

    func testGitBlobDigestsVerifyTheSameContent() async throws {
        let (library, _) = makeLibrary(assetCount: 2, useGitBlobDigests: true)
        let (store, database, _) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(store: store, transfer: makeFixtureTransfer())
        try await manager.install(library)

        guard case .installed = try store.state(of: library) else {
            return XCTFail("A git-blob-pinned library did not install.")
        }
    }

    func testALibraryOfHundredsOfFilesFinishesRatherThanExhaustingConnections() async throws {
        // The defect this exists for: the transport used to build one
        // `URLSession` per asset. Downloading the real 2,539-file orchestral
        // library stalled dead at file 1,649 with 162 established and 83
        // half-closed sockets and the process at zero per cent CPU — a session
        // owns a connection pool and retires it asynchronously, so one per file
        // leaks connections faster than the system reclaims them. Three assets
        // never came close to showing it; four hundred do.
        let (library, payloads) = makeLibrary(assetCount: 400, byteCountEach: 2_048)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 6
        )
        try await manager.install(library)

        guard case .installed(let installed) = try store.state(of: library) else {
            return XCTFail("A 401-asset library did not install.")
        }
        XCTAssertEqual(installed.assetCount, 401)

        // Spot-check the ends and the middle byte-for-byte: a connection pool
        // that muddled two responses would show up as one file holding
        // another's bytes, which the digests would catch — but this says so
        // directly.
        for name in ["asset0.wav", "asset199.wav", "asset399.wav"] {
            let installedBytes = try Data(
                contentsOf: assetsURL
                    .appending(path: library.identifier)
                    .appending(path: "Samples")
                    .appending(path: name)
            )
            XCTAssertEqual(installedBytes, payloads[name], "\(name) did not install byte-for-byte.")
        }

        XCTAssertEqual(
            server.requests.filter { $0.path.hasSuffix(".wav") }.count, 400,
            "Every asset should have been fetched exactly once."
        )
    }

    // MARK: Resume

    func testAnInterruptedTransferResumesFromWhereItStopped() async throws {
        // One large asset so the truncation lands in the middle of it.
        let (library, payloads) = makeLibrary(assetCount: 1, byteCountEach: 300_000)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 1
        )

        // The server hangs up after 100 KB — the shape of a killed transfer.
        server.setBehavior(.truncateAfter(count: 100_000))
        do {
            try await manager.install(library)
            XCTFail("A truncated transfer must not report success.")
        } catch {
            // Either the connection error or the length check; both are correct.
        }

        // Nothing is installed, but the partial bytes are kept.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            ),
            "A failed transfer must leave no installed library."
        )
        let staged = store.stagedByteCount(for: library)
        XCTAssertGreaterThan(staged, 0, "Nothing was kept, so there is nothing to resume from.")
        XCTAssertLessThan(staged, library.downloadByteCount)
        guard case .partiallyDownloaded(let reported) = try store.state(of: library) else {
            return XCTFail("The library should report itself partially downloaded.")
        }
        XCTAssertEqual(reported, staged)

        // Resume. The second run must ask for a range, not the whole file.
        server.setBehavior(.serve)
        let requestsBefore = server.requests.count
        let bigAssetStaged = store.stagingArea.stagedByteCount(
            forLibraryID: library.identifier, assetID: "Samples/asset0.wav"
        )
        XCTAssertGreaterThan(bigAssetStaged, 0)
        try await manager.install(library)

        let resumeRequests = Array(server.requests.dropFirst(requestsBefore))
        let bigAssetRequest = try XCTUnwrap(
            resumeRequests.first { $0.path.contains("asset0.wav") },
            "The resumed run never asked for the interrupted asset."
        )
        let rangeHeader = try XCTUnwrap(
            bigAssetRequest.rangeHeader, "The resumed run did not send a Range header."
        )
        XCTAssertEqual(
            CatalogFixtureServer.parseRangeStart(rangeHeader),
            Int(bigAssetStaged),
            "The Range offset is not the number of bytes already on disk."
        )

        guard case .installed = try store.state(of: library) else {
            return XCTFail("The resumed transfer did not finish the install.")
        }
        let installedBytes = try Data(
            contentsOf: assetsURL
                .appending(path: library.identifier)
                .appending(path: "Samples")
                .appending(path: "asset0.wav")
        )
        XCTAssertEqual(
            installedBytes, payloads["asset0.wav"],
            "The resumed file is not byte-identical — the two halves were joined wrongly."
        )
    }

    func testAServerThatIgnoresRangeRestartsRatherThanAppending() async throws {
        let (library, payloads) = makeLibrary(assetCount: 1, byteCountEach: 200_000)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 1
        )

        server.setBehavior(.truncateAfter(count: 60_000))
        _ = try? await manager.install(library)
        XCTAssertGreaterThan(store.stagedByteCount(for: library), 0)

        // Now the server answers 200 and sends everything, ignoring the Range.
        // Appending would produce a file 60 KB too long with a duplicated head.
        server.setBehavior(.ignoreRangeRequests)
        try await manager.install(library)

        let installed = try Data(
            contentsOf: assetsURL
                .appending(path: library.identifier)
                .appending(path: "Samples")
                .appending(path: "asset0.wav")
        )
        XCTAssertEqual(
            installed, payloads["asset0.wav"],
            "A server that ignored the Range header produced a corrupted file."
        )
    }

    // MARK: Re-download

    func testRemovingAnInstalledLibraryMakesItDownloadableAgain() async throws {
        let (library, _) = makeLibrary(assetCount: 2)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(store: store, transfer: makeFixtureTransfer())
        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The first install did not take.")
        }

        try manager.remove(library)

        XCTAssertEqual(try store.state(of: library), .notDownloaded)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            ),
            "Removing a library left its files behind."
        )
        XCTAssertTrue(try store.availableInstruments().isEmpty)

        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("A removed library did not re-download.")
        }
        XCTAssertEqual(try store.availableInstruments().count, 1)
    }

    func testDeletingTheFilesUnderneathTheStoreIsReportedRatherThanPlayed() async throws {
        let (library, _) = makeLibrary(assetCount: 1)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(store: store, transfer: makeFixtureTransfer())
        try await manager.install(library)

        // The owner throws the folder away in the Finder.
        try FileManager.default.removeItem(at: assetsURL.appending(path: library.identifier))

        XCTAssertTrue(
            try store.availableInstruments().isEmpty,
            "An instrument whose files are gone must not be offered as playable."
        )
        let reconciled = try store.reconcileWithDisk()
        XCTAssertEqual(reconciled.rowsDropped, [library.identifier])
        XCTAssertEqual(try store.state(of: library), .notDownloaded)

        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The library did not come back after its files were deleted.")
        }
    }

    // MARK: Checksum mismatch

    func testAChecksumMismatchDiscardsTheContentReportsItAndStaysDownloadable() async throws {
        let (library, _) = makeLibrary(assetCount: 1, byteCountEach: 50_000)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 1
        )

        server.setBehavior(.serveCorruptedBytes)
        var reported: InstrumentInstallError?
        do {
            try await manager.install(library)
            XCTFail("Corrupted bytes must not install.")
        } catch let error as InstrumentInstallError {
            reported = error
        }

        guard case .digestMismatch(let libraryID, _, let algorithm, _, _) = try XCTUnwrap(reported)
        else { return XCTFail("The failure was not reported as a checksum mismatch.") }
        XCTAssertEqual(libraryID, library.identifier)
        XCTAssertEqual(algorithm, "SHA-256 checksum")

        // Discarded, so a resume cannot build on bad bytes.
        XCTAssertEqual(
            store.stagingArea.stagedByteCount(
                forLibraryID: library.identifier, assetID: "Samples/asset0.wav"
            ),
            0,
            "The corrupted download was kept, so retrying would resume onto it."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            ),
            "A checksum failure left an installed library behind."
        )

        // And it is immediately re-downloadable.
        server.setBehavior(.serve)
        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The library did not install after the mismatch was fixed.")
        }
    }

    // MARK: Disk full

    func testASimulatedDiskFullFailsCleanlyWithNoPartialAssetState() async throws {
        let (library, _) = makeLibrary(assetCount: 2, byteCountEach: 80_000)
        let opener = DiskFillingStagingFileOpener(bytesBeforeFailure: 30_000)
        let (store, database, assetsURL) = try makeStore(catalog: [library], opener: opener)
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 1
        )

        var thrown: Error?
        do {
            try await manager.install(library)
            XCTFail("A full disk must not produce an install.")
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(thrown) as NSError
        XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(
            error.code, Int(ENOSPC),
            "The failure that reached the caller is not the disk-full one."
        )

        // The whole point: nothing observable was installed.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            ),
            "A disk-full during download produced a partially installed library."
        )
        XCTAssertEqual(try store.state(of: library).installedLibrary, nil)
        XCTAssertTrue(try store.installedLibraries().isEmpty)
        XCTAssertTrue(try store.availableInstruments().isEmpty)

        // With space free again, the library installs; whatever the failed run
        // left is either resumed or replaced, and either way the result is
        // byte-correct because the digest says so.
        opener.stopFailing()
        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The library did not install once the disk had room.")
        }
    }

    // MARK: Unreachable source

    func testAnUnreachableSourceIsRetryableAndCorruptsNothing() async throws {
        let (library, _) = makeLibrary(assetCount: 1)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(stallTimeout: 5),
            concurrentTransferLimit: 1
        )

        // The server is up but refusing, which is the 5xx case: retryable.
        server.setBehavior(.refuse(statusCode: 503))
        do {
            try await manager.install(library)
            XCTFail("A refusing source must not install.")
        } catch let error as AssetTransferError {
            guard case .sourceRefused(_, let statusCode) = error else {
                return XCTFail("Expected a refusal, got \(error).")
            }
            XCTAssertEqual(statusCode, 503)
            XCTAssertTrue(error.isRetryable, "A 503 must be offered as retryable.")
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            )
        )
        XCTAssertTrue(try store.installedLibraries().isEmpty)

        server.setBehavior(.serve)
        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("Retrying after the source came back did not work.")
        }
    }

    func testASourceThatIsNotThereIsNotOfferedAsRetryable() async throws {
        let (library, _) = makeLibrary(assetCount: 1)
        let (store, database, _) = try makeStore(catalog: [library])
        defer { database.close() }

        // Point one asset at a path the fixture does not serve.
        let missing = CatalogAsset(
            identifier: "Samples/gone.wav",
            sourceURL: server.url(for: "not-served.wav").absoluteString,
            byteCount: 1_000,
            digest: .sha256(String(repeating: "0", count: 64)),
            payload: .file(path: "Samples/gone.wav")
        )
        let broken = CatalogLibrary(
            identifier: library.identifier,
            name: library.name,
            publisher: library.publisher,
            summary: library.summary,
            licence: library.licence,
            homepageURL: library.homepageURL,
            assets: [missing],
            coverage: library.coverage
        )

        let manager = InstrumentDownloadManager(store: store, transfer: makeFixtureTransfer())
        do {
            try await manager.install(broken)
            XCTFail("A missing asset must not install.")
        } catch let error as AssetTransferError {
            guard case .sourceRefused(_, let statusCode) = error else {
                return XCTFail("Expected a refusal, got \(error).")
            }
            XCTAssertEqual(statusCode, 404)
            XCTAssertFalse(
                error.isRetryable,
                "A 404 means the source moved; offering Retry would just fail again."
            )
        }
    }

    // MARK: Pause

    func testCancellingPausesAndKeepsWhatArrived() async throws {
        let (library, _) = makeLibrary(assetCount: 1, byteCountEach: 400_000)
        let (store, database, assetsURL) = try makeStore(catalog: [library])
        defer { database.close() }

        let manager = InstrumentDownloadManager(
            store: store, transfer: makeFixtureTransfer(), concurrentTransferLimit: 1
        )

        // Loopback is fast enough to finish a download before a test can react,
        // so the server dribbles: 20 KB every 50 ms, about a second in total.
        server.setBehavior(.throttle(chunkByteCount: 20_000, delayMilliseconds: 50))

        let task = Task {
            try await manager.install(library)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = try? await task.value

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: assetsURL.appending(path: library.identifier).path(percentEncoded: false)
            ),
            "A paused download must not have installed anything."
        )
        XCTAssertGreaterThan(
            store.stagedByteCount(for: library), 0,
            "Pausing threw away everything that had arrived."
        )

        // Resuming completes it.
        server.setBehavior(.serve)
        try await manager.install(library)
        guard case .installed = try store.state(of: library) else {
            return XCTFail("The paused download did not resume to completion.")
        }
    }
}

// MARK: - Test doubles

/// Records the phases progress went through, from whatever thread reports them.
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [InstrumentDownloadProgress.Phase] = []

    func record(_ phase: InstrumentDownloadProgress.Phase) {
        lock.lock(); phases.append(phase); lock.unlock()
    }

    var all: [InstrumentDownloadProgress.Phase] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }
}

/// A staging opener whose files stop accepting bytes, the way a full disk does.
///
/// It throws the **real** `NSPOSIXErrorDomain` / `ENOSPC` error Foundation
/// raises when a write runs out of space, so the code path under test is the
/// production one and not a special case for a special error.
final class DiskFillingStagingFileOpener: StagingFileOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingBeforeFailure: Int
    private var failing = true

    init(bytesBeforeFailure: Int) {
        self.remainingBeforeFailure = bytesBeforeFailure
    }

    func stopFailing() {
        lock.lock(); failing = false; lock.unlock()
    }

    func openForAppending(at url: URL) throws -> AppendableFile {
        let real = try FileSystemStagingFileOpener().openForAppending(at: url)
        return Wrapper(underlying: real, owner: self)
    }

    fileprivate func consume(_ count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard failing else { return }
        remainingBeforeFailure -= count
        guard remainingBeforeFailure < 0 else { return }
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
    }

    private final class Wrapper: AppendableFile {
        private let underlying: AppendableFile
        private weak var owner: DiskFillingStagingFileOpener?

        init(underlying: AppendableFile, owner: DiskFillingStagingFileOpener) {
            self.underlying = underlying
            self.owner = owner
        }

        func append(_ data: Data) throws {
            try owner?.consume(data.count)
            try underlying.append(data)
        }

        func close() throws { try underlying.close() }
    }
}

// MARK: - Small conveniences

extension InstrumentLibraryState {
    /// The installed record, when there is one.
    var installedLibrary: InstalledInstrumentLibrary? {
        switch self {
        case .installed(let record), .installedFromAnotherCatalog(let record): return record
        case .notDownloaded, .partiallyDownloaded: return nil
        }
    }
}
