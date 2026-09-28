import XCTest
@testable import Synth
import SynthKit

/// `InstrumentCatalogModel`'s first-run offer: the one preference it reads and
/// writes, and what the owner is told when either fails (#95). Nothing here
/// downloads; declining is the only answer given.
@MainActor
final class InstrumentCatalogModelTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var catalog: InstrumentCatalogModel!

    override func setUp() async throws {
        try await super.setUp()
        library = try TemporaryLibrary()
        catalog = InstrumentCatalogModel(store: library.store)
    }

    override func tearDown() async throws {
        catalog = nil
        library?.tearDown()
        library = nil
        try await super.tearDown()
    }

    private var storedAnswer: String? {
        get throws {
            try library.store.preferences.string(
                forKey: InstrumentCatalogModel.firstRunOfferSeenKey
            )
        }
    }

    func testTheOfferIsMadeOnceAndDecliningIsRecorded() throws {
        catalog.prepareForFirstRun()
        XCTAssertTrue(catalog.isShowingFirstRunOffer)

        catalog.answerFirstRunOffer(downloadNow: false)

        XCTAssertFalse(catalog.isShowingFirstRunOffer)
        XCTAssertEqual(try storedAnswer, "declined")
        XCTAssertNil(catalog.alert)

        catalog.prepareForFirstRun()
        XCTAssertFalse(catalog.isShowingFirstRunOffer, "Answered once is answered")
    }

    /// A read that fails is neither "never asked" nor an answer: the offer
    /// stays down and the failure is in the catalog's alert.
    func testAPreferenceThatCannotBeReadIsReportedAndTheOfferStaysDown() throws {
        try library.store.database.executeScript(
            "ALTER TABLE \(PreferenceStore.tableName) RENAME TO hidden_preferences;"
        )

        catalog.prepareForFirstRun()

        XCTAssertFalse(catalog.isShowingFirstRunOffer)
        XCTAssertEqual(catalog.alert?.title, InstrumentCatalogModel.offerReadFailureTitle)
    }

    /// The owner's answer stands for this session, and they are told it could
    /// not be recorded.
    func testAnAnswerThatCannotBeRecordedIsReported() throws {
        catalog.prepareForFirstRun()
        XCTAssertTrue(catalog.isShowingFirstRunOffer)
        try library.failWrites(.insert, on: PreferenceStore.tableName)

        catalog.answerFirstRunOffer(downloadNow: false)

        XCTAssertFalse(catalog.isShowingFirstRunOffer)
        let alert = try XCTUnwrap(catalog.alert)
        XCTAssertEqual(alert.title, InstrumentCatalogModel.offerWriteFailureTitle)
        XCTAssertTrue(
            alert.failure.summary.contains(TemporaryLibrary.injectedFailure), alert.failure.summary
        )
        XCTAssertNil(try storedAnswer)
    }

    // MARK: Through the shell

    /// The launch path end to end: the offer comes up over a fresh library,
    /// the owner declines, and declining cannot be recorded. The shell would
    /// ordinarily put the catalog away; here it must keep it up, because the
    /// catalog screen is the only place its alert is shown.
    func testADeclineThatCannotBeRecordedKeepsTheCatalogUpToShowWhy() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(container: AppContainer(rootURL: directory))
        await app.bootstrap()
        let store = try XCTUnwrap(app.store)
        let shellCatalog = try XCTUnwrap(app.instrumentCatalog)
        XCTAssertTrue(app.isInstrumentCatalogShowing, "A fresh library raises the offer")
        XCTAssertTrue(shellCatalog.isShowingFirstRunOffer)

        try TemporaryLibrary.failWrites(.insert, on: PreferenceStore.tableName, in: store)
        shellCatalog.answerFirstRunOffer(downloadNow: false)

        XCTAssertEqual(shellCatalog.alert?.title, InstrumentCatalogModel.offerWriteFailureTitle)
        XCTAssertTrue(app.isInstrumentCatalogShowing, "The alert's screen stays up")
    }

    /// And the ordinary decline still puts the catalog away.
    func testARecordedDeclinePutsTheCatalogAway() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "SynthAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(container: AppContainer(rootURL: directory))
        await app.bootstrap()
        XCTAssertNotNil(app.store)
        let shellCatalog = try XCTUnwrap(app.instrumentCatalog)

        shellCatalog.answerFirstRunOffer(downloadNow: false)

        XCTAssertNil(shellCatalog.alert)
        XCTAssertFalse(app.isInstrumentCatalogShowing)
    }
}
