import Foundation
import XCTest
@testable import SynthKit

/// Search, ordering, and the derived text the library list and VoiceOver read.
///
/// REQ-002's acceptance — "find an imported piece by typing part of its
/// composer's name" — is proved here, at the layer that decides it. The running
/// app's search field does nothing but hand its text to `LibraryQuery`.
final class LibraryQueryTests: XCTestCase {

    // MARK: - Fixtures

    private func piece(
        id: String = UUID().uuidString,
        title: String,
        composer: String? = nil,
        workTitle: String? = nil,
        workNumber: String? = nil,
        movementTitle: String? = nil,
        movementNumber: String? = nil,
        sourceFileName: String = "score.musicxml",
        importedAt: String = "2026-08-01T10:00:00Z"
    ) -> PieceRecord {
        PieceRecord(
            id: id,
            title: title,
            composer: composer,
            workTitle: workTitle,
            workNumber: workNumber,
            movementTitle: movementTitle,
            movementNumber: movementNumber,
            sourceFileName: sourceFileName,
            sourceFormat: .musicXML,
            contentFileName: "\(id).musicxml",
            contentSHA256: String(repeating: "a", count: 64),
            contentByteCount: 100,
            importedAt: importedAt
        )
    }

    private var library: [PieceRecord] {
        [
            piece(
                id: "bach",
                title: "Prelude in C",
                composer: "Johann Sebastian Bach",
                workTitle: "Das wohltemperierte Klavier",
                workNumber: "BWV 846",
                sourceFileName: "prelude.musicxml",
                importedAt: "2026-08-01T10:00:00Z"
            ),
            piece(
                id: "dvorak",
                title: "Humoresque",
                composer: "Antonín Dvořák",
                workNumber: "Op. 101",
                movementTitle: "Poco lento e grazioso",
                movementNumber: "7",
                sourceFileName: "humoresque.mxl",
                importedAt: "2026-08-03T10:00:00Z"
            ),
            piece(
                id: "anon",
                title: "Untitled Sketch",
                composer: nil,
                sourceFileName: "sketch.xml",
                importedAt: "2026-08-02T10:00:00Z"
            )
        ]
    }

    // MARK: - Search (REQ-002)

    func testFindsAPieceByPartOfItsComposersName() {
        let matches = LibraryQuery.filtered(library, matching: "seba")

        XCTAssertEqual(matches.map(\.id), ["bach"])
    }

    func testSearchIgnoresCase() {
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "BACH").map(\.id), ["bach"])
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "bach").map(\.id), ["bach"])
    }

    /// Typing on a US keyboard has to find *Dvořák*, or the search is unusable
    /// for exactly the repertoire this app is for.
    func testSearchIgnoresDiacritics() {
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "dvorak").map(\.id), ["dvorak"])
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "Antonin").map(\.id), ["dvorak"])
    }

    func testSearchLooksAtEveryMetadataField() {
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "Humoresque").map(\.id), ["dvorak"],
                       "title")
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "wohltemperierte").map(\.id), ["bach"],
                       "work title")
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "BWV 846").map(\.id), ["bach"],
                       "work number")
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "grazioso").map(\.id), ["dvorak"],
                       "movement title")
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "sketch.xml").map(\.id), ["anon"],
                       "source file name")
    }

    func testAnEmptyOrBlankSearchShowsTheWholeLibrary() {
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "").count, 3)
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "   ").count, 3)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(LibraryQuery.filtered(library, matching: "  bach  ").map(\.id), ["bach"])
    }

    /// An unmatched search is empty, never an error — the surface shows an
    /// empty state on this result.
    func testASearchThatMatchesNothingReturnsNoRows() {
        XCTAssertTrue(LibraryQuery.filtered(library, matching: "tuba concerto").isEmpty)
    }

    func testAMissingFieldIsNeverSearchedAsEmptyText() {
        // The anonymous piece has no composer. Searching for the empty-ish
        // needle a nil field would produce must not select it.
        let anonymous = piece(id: "x", title: "X", composer: nil)
        XCTAssertFalse(LibraryQuery.matches(anonymous, searchText: "composer"))
    }

    // MARK: - Sorting

    func testSortsByTitleAscendingAndDescending() {
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: .byTitle).map(\.title),
            ["Humoresque", "Prelude in C", "Untitled Sketch"]
        )
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: LibrarySort(field: .title, direction: .descending))
                .map(\.title),
            ["Untitled Sketch", "Prelude in C", "Humoresque"]
        )
    }

    func testSortsByComposer() {
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: LibrarySort(field: .composer, direction: .ascending))
                .map(\.id),
            ["dvorak", "bach", "anon"]
        )
    }

    /// Reversing the sort must not promote the pieces that have no value for
    /// the sorted field: "unknown" belongs at the end either way.
    func testPiecesWithoutTheSortedFieldStayLastInBothDirections() {
        let ascending = LibraryQuery.sorted(
            library, by: LibrarySort(field: .composer, direction: .ascending)
        )
        let descending = LibraryQuery.sorted(
            library, by: LibrarySort(field: .composer, direction: .descending)
        )

        XCTAssertEqual(ascending.last?.id, "anon")
        XCTAssertEqual(descending.last?.id, "anon")
        XCTAssertEqual(descending.map(\.id), ["bach", "dvorak", "anon"])
    }

    func testSortsByImportDate() {
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: LibrarySort(field: .importedAt, direction: .ascending))
                .map(\.id),
            ["bach", "anon", "dvorak"]
        )
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: LibrarySort(field: .importedAt, direction: .descending))
                .map(\.id),
            ["dvorak", "anon", "bach"]
        )
    }

    /// Movement 10 comes after movement 2, which a plain string compare gets
    /// backwards.
    func testMovementsSortNumericallyRatherThanLexically() {
        let movements = [
            piece(id: "m10", title: "J", movementTitle: "Finale", movementNumber: "10"),
            piece(id: "m2", title: "B", movementTitle: "Andante", movementNumber: "2"),
            piece(id: "m1", title: "A", movementTitle: "Allegro", movementNumber: "1")
        ]

        XCTAssertEqual(
            LibraryQuery.sorted(movements, by: LibrarySort(field: .movement, direction: .ascending))
                .map(\.id),
            ["m1", "m2", "m10"]
        )
    }

    /// Two pieces that tie on the sorted field must keep a fixed order, or the
    /// list visibly reshuffles as the owner types.
    func testEqualKeysBreakDeterministicallyByTitle() {
        let sameComposer = [
            piece(id: "z", title: "Zephyr", composer: "Ravel"),
            piece(id: "a", title: "Alborada", composer: "Ravel"),
            piece(id: "m", title: "Miroirs", composer: "Ravel")
        ]

        let sort = LibrarySort(field: .composer, direction: .descending)
        XCTAssertEqual(
            LibraryQuery.sorted(sameComposer, by: sort).map(\.title),
            ["Alborada", "Miroirs", "Zephyr"],
            "The tie-break is always ascending by title, whichever way the field runs"
        )
        XCTAssertEqual(
            LibraryQuery.sorted(sameComposer.reversed(), by: sort).map(\.title),
            ["Alborada", "Miroirs", "Zephyr"],
            "and it does not depend on the input order"
        )
    }

    func testArrangeFiltersThenSorts() {
        let arranged = LibraryQuery.arrange(
            library,
            searchText: "o",
            sort: LibrarySort(field: .title, direction: .ascending)
        )

        XCTAssertEqual(arranged.map(\.id), ["dvorak", "bach"])
    }

    // MARK: - Displayed and spoken text

    func testMovementDescriptionCombinesNumberAndTitle() {
        XCTAssertEqual(
            piece(title: "X", movementTitle: "Andante", movementNumber: "2").movementDescription,
            "2. Andante"
        )
        XCTAssertEqual(
            piece(title: "X", movementTitle: "Andante").movementDescription,
            "Andante"
        )
        XCTAssertEqual(
            piece(title: "X", movementNumber: "2").movementDescription,
            "Movement 2"
        )
        XCTAssertNil(piece(title: "X").movementDescription)
    }

    func testWorkDescriptionCombinesTitleAndNumber() {
        XCTAssertEqual(
            piece(title: "X", workTitle: "Das wohltemperierte Klavier", workNumber: "BWV 846")
                .workDescription,
            "Das wohltemperierte Klavier (BWV 846)"
        )
        XCTAssertEqual(piece(title: "X", workNumber: "Op. 101").workDescription, "Op. 101")
        XCTAssertNil(piece(title: "X").workDescription)
    }

    func testAMissingComposerReadsAsUnknownRatherThanBlank() {
        XCTAssertEqual(piece(title: "X").composerDescription, "Unknown composer")
        XCTAssertEqual(piece(title: "X", composer: "   ").composerDescription, "Unknown composer",
                       "A whitespace-only creator element is absent, not blank")
    }

    /// The exact sentence VoiceOver speaks for a row (REQ-027).
    func testTheAccessibilityLabelSpeaksThePieceAsASentence() {
        let record = piece(
            title: "Humoresque",
            composer: "Antonín Dvořák",
            workNumber: "Op. 101",
            movementTitle: "Poco lento e grazioso",
            movementNumber: "7"
        )

        XCTAssertEqual(
            record.accessibilityDescription,
            "Humoresque, composer Antonín Dvořák, work Op. 101, movement 7. Poco lento e grazioso"
        )
    }

    func testTheAccessibilityLabelStillNamesAnUnknownComposer() {
        XCTAssertEqual(
            piece(title: "Untitled Sketch").accessibilityDescription,
            "Untitled Sketch, composer Unknown composer"
        )
    }

    func testTheSubtitleShowsWhatTheScoreDeclared() {
        XCTAssertEqual(
            piece(title: "X", composer: "Bach", workTitle: "WTC", movementNumber: "2")
                .subtitleDescription,
            "Bach — WTC — Movement 2"
        )
        XCTAssertEqual(piece(title: "X").subtitleDescription, "Unknown composer")
    }

    /// The title is usually derived from the work or movement title, so the
    /// subtitle (and the spoken sentence) must not say the same thing twice.
    func testTheSubtitleDoesNotRepeatTheTitle() {
        let record = piece(title: "Fugue in C minor", composer: "J. S. Bach", workTitle: "Fugue in C minor")
        XCTAssertEqual(record.subtitleDescription, "J. S. Bach")
        XCTAssertEqual(record.accessibilityDescription, "Fugue in C minor, composer J. S. Bach")

        // A work line that adds something beyond the title still shows.
        let numbered = piece(
            title: "Fugue in C minor", composer: "J. S. Bach",
            workTitle: "Fugue in C minor", workNumber: "BWV 847"
        )
        XCTAssertEqual(numbered.subtitleDescription, "J. S. Bach — Fugue in C minor (BWV 847)")
    }

    // MARK: - Sort control wording

    func testSortDirectionWordingSuitsTheField() {
        XCTAssertEqual(LibrarySortDirection.descending.label(for: .importedAt), "Newest First")
        XCTAssertEqual(LibrarySortDirection.ascending.label(for: .importedAt), "Oldest First")
        XCTAssertEqual(LibrarySortDirection.ascending.label(for: .composer), "A to Z")
        XCTAssertEqual(LibrarySort.byTitle.label, "Title, A to Z")
    }
}
