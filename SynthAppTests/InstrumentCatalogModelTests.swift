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
        XCTAssertNotNil(catalog.alert)
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
        XCTAssertTrue(alert.summary.contains(TemporaryLibrary.injectedFailure), alert.summary)
        XCTAssertNil(try storedAnswer)
    }
}
