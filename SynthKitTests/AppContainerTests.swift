import XCTest
@testable import SynthKit

final class AppContainerTests: XCTestCase {
    private var sandboxRoot: URL!

    override func setUpWithError() throws {
        sandboxRoot = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sandboxRoot.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sandboxRoot)
        }
    }

    func testDefaultContainerLivesInApplicationSupport() throws {
        let container = try AppContainer.default()
        let path = container.rootURL.path(percentEncoded: false)

        XCTAssertTrue(
            path.hasSuffix("/Application Support/Synth"),
            "Expected the container under Application Support, got \(path)"
        )
        XCTAssertEqual(container.databaseURL.lastPathComponent, "library.sqlite")
    }

    func testPrepareCreatesTheWholeLayout() throws {
        let container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))

        try container.prepare()

        for directory in container.managedDirectoryURLs {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: directory.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            XCTAssertTrue(exists, "Missing \(directory.lastPathComponent)")
            XCTAssertTrue(isDirectory.boolValue, "\(directory.lastPathComponent) is not a directory")
        }
        XCTAssertEqual(
            container.managedDirectoryURLs.map(\.lastPathComponent),
            ["Synth", "pieces", "sounds", "assets"]
        )
    }

    func testPrepareIsIdempotentAndKeepsExistingContent() throws {
        let container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        try container.prepare()

        let marker = container.piecesURL.appending(path: "existing.musicxml")
        try Data("<score-partwise/>".utf8).write(to: marker)

        try container.prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    func testPrepareRejectsAPathOccupiedByAFile() throws {
        let container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        try FileManager.default.createDirectory(at: container.rootURL, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: container.piecesURL)

        XCTAssertThrowsError(try container.prepare()) { error in
            guard case StoreError.containerPathIsNotADirectory(let path) = error else {
                return XCTFail("Expected containerPathIsNotADirectory, got \(error)")
            }
            XCTAssertEqual(path, container.piecesURL.path(percentEncoded: false))
        }

        // The pre-existing root must survive: rollback only removes what this
        // call created.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: container.rootURL.path(percentEncoded: false))
        )
    }

    func testPrepareLeavesNoPartialContainerWhenCreationFailsPartWay() throws {
        let container = AppContainer(rootURL: sandboxRoot.appending(path: "Synth"))
        // Fail on the third createDirectory: root and pieces succeed, sounds throws.
        let fileManager = FailingFileManager(failOnCreateCallNumber: 3)

        XCTAssertThrowsError(try container.prepare(fileManager: fileManager)) { error in
            guard case StoreError.containerCreationFailed = error else {
                return XCTFail("Expected containerCreationFailed, got \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.rootURL.path(percentEncoded: false)),
            "A failed prepare must not leave a partially built container behind"
        )
    }
}

/// A `FileManager` that throws on the Nth `createDirectory` call so the
/// partial-failure rollback path can be exercised deterministically.
private final class FailingFileManager: FileManager {
    private let failOnCreateCallNumber: Int
    private var createCallCount = 0

    init(failOnCreateCallNumber: Int) {
        self.failOnCreateCallNumber = failOnCreateCallNumber
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createCallCount += 1
        if createCallCount == failOnCreateCallNumber {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}
