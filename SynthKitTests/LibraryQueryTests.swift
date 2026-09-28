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

    /// By surname (owner decision on #30): Bach before Dvořák, although
    /// "Antonín" precedes "Johann" as a full string.
    func testSortsByComposer() {
        XCTAssertEqual(
            LibraryQuery.sorted(library, by: LibrarySort(field: .composer, direction: .ascending))
                .map(\.id),
            ["bach", "dvorak", "anon"]
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
        XCTAssertEqual(descending.map(\.id), ["dvorak", "bach", "anon"])
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

    // MARK: - Composer surname ordering (#94, #30)

    func testSurnameKeyUsesTheTextBeforeACommaWhenThereIsOne() {
        XCTAssertEqual(LibraryQuery.surnameSortKey("Bach, Johann Sebastian"), "Bach")
        XCTAssertEqual(LibraryQuery.surnameSortKey("  Vaughan Williams , Ralph "), "Vaughan Williams")
    }

    func testSurnameKeyIsTheLastWordOfAFirstLastName() {
        XCTAssertEqual(LibraryQuery.surnameSortKey("Johann Sebastian Bach"), "Bach")
        XCTAssertEqual(LibraryQuery.surnameSortKey("Antonín  Dvořák "), "Dvořák")
    }

    func testSurnameKeyOfASingleNameIsTheName() {
        XCTAssertEqual(LibraryQuery.surnameSortKey("Palestrina"), "Palestrina")
        XCTAssertEqual(LibraryQuery.surnameSortKey(", Anonymous"), "Anonymous",
                       "an empty text before the comma falls back to the last word")
    }

    private var composers: [PieceRecord] {
        [
            piece(id: "js", title: "A", composer: "Johann Sebastian Bach"),
            piece(id: "cpe", title: "B", composer: "Bach, Carl Philipp Emanuel"),
            piece(id: "ravel", title: "C", composer: "Maurice Ravel"),
            piece(id: "pal", title: "D", composer: "Palestrina"),
            piece(id: "anon", title: "E", composer: nil),
            piece(id: "dvorak", title: "F", composer: "Antonín Dvořák"),
            piece(id: "clara", title: "G", composer: "Clara Schumann"),
            piece(id: "robert", title: "H", composer: "Schumann, Robert")
        ]
    }

    /// Comma form, "First Last" and single names file together by surname;
    /// equal surnames break by the full name; unknown is last.
    func testComposerSortOrdersBySurnameWithFullNameBreakingTies() {
        XCTAssertEqual(
            LibraryQuery.sorted(composers, by: LibrarySort(field: .composer, direction: .ascending))
                .map(\.id),
            ["cpe", "js", "dvorak", "pal", "ravel", "clara", "robert", "anon"]
        )
        XCTAssertEqual(
            LibraryQuery.sorted(composers, by: LibrarySort(field: .composer, direction: .descending))
                .map(\.id),
            ["robert", "clara", "ravel", "pal", "dvorak", "js", "cpe", "anon"]
        )
    }

    func testComposerFacetOrdersBySurnameWithUnknownLast() {
        let facet = LibraryQuery.composerFacet(composers)
        XCTAssertEqual(
            facet.map(\.name),
            [
                "Bach, Carl Philipp Emanuel", "Johann Sebastian Bach", "Antonín Dvořák",
                "Palestrina", "Maurice Ravel", "Clara Schumann", "Schumann, Robert",
                "Unknown composer"
            ]
        )
        XCTAssertEqual(facet.last?.filter, .unknown)
    }

    func testComposerFacetCountsAndGroupsCaseAndDiacriticInsensitively() {
        let records = [
            piece(id: "1", title: "A", composer: "Antonín Dvořák"),
            piece(id: "2", title: "B", composer: "antonin dvorak"),
            piece(id: "3", title: "C", composer: "Antonín Dvořák"),
            piece(id: "4", title: "D", composer: "Ravel"),
            piece(id: "5", title: "E", composer: nil),
            piece(id: "6", title: "F", composer: "   ")
        ]
        let facet = LibraryQuery.composerFacet(records)
        XCTAssertEqual(facet.map(\.name), ["Antonín Dvořák", "Ravel", "Unknown composer"],
                       "variants share one entry under the spelling most pieces use")
        XCTAssertEqual(facet.map(\.count), [3, 1, 2],
                       "a blank composer counts as unknown")
    }

    func testComposerFacetIsEmptyForAnEmptyLibraryAndOmitsUnknownWhenNoneIsMissing() {
        XCTAssertEqual(LibraryQuery.composerFacet([]), [])
        let facet = LibraryQuery.composerFacet([piece(title: "A", composer: "Ravel")])
        XCTAssertEqual(facet.map(\.filter), [ComposerFilter(piece(title: "A", composer: "RAVEL"))])
    }

    // MARK: - Composer filter

    func testChoosingAComposerShowsOnlyTheirPiecesAndClearingRestoresAll() {
        let dvorak = LibraryQuery.composerFacet(composers).first { $0.name == "Antonín Dvořák" }!.filter
        let byTitle = LibrarySort.byTitle

        XCTAssertEqual(
            LibraryQuery.arrange(composers, searchText: "", composer: dvorak, sort: byTitle).map(\.id),
            ["dvorak"]
        )
        XCTAssertEqual(
            LibraryQuery.arrange(composers, searchText: "", composer: .unknown, sort: byTitle).map(\.id),
            ["anon"]
        )
        XCTAssertEqual(
            LibraryQuery.arrange(composers, searchText: "", composer: nil, sort: byTitle).count,
            composers.count
        )
    }

    func testTheComposerFilterMatchesVariantSpellings() {
        let records = [
            piece(id: "1", title: "A", composer: "Antonín Dvořák"),
            piece(id: "2", title: "B", composer: "ANTONIN DVORAK"),
            piece(id: "3", title: "C", composer: "Ravel")
        ]
        let filter = ComposerFilter(records[0])
        XCTAssertEqual(
            LibraryQuery.arrange(records, searchText: "", composer: filter, sort: .byTitle).map(\.id),
            ["1", "2"]
        )
    }

    func testTheComposerFilterCombinesWithTextSearch() {
        let records = [
            piece(id: "p1", title: "Prelude in C", composer: "Johann Sebastian Bach"),
            piece(id: "f1", title: "Fugue in C", composer: "Johann Sebastian Bach"),
            piece(id: "p2", title: "Prelude in D-flat", composer: "Frédéric Chopin")
        ]
        let bach = ComposerFilter(records[0])

        XCTAssertEqual(
            LibraryQuery.arrange(records, searchText: "prelude", composer: bach, sort: .byTitle).map(\.id),
            ["p1"]
        )
        XCTAssertEqual(
            LibraryQuery.arrange(records, searchText: "prelude", composer: nil, sort: .byTitle).map(\.id),
            ["p1", "p2"],
            "the search alone is unchanged"
        )
        XCTAssertEqual(
            LibraryQuery.arrange(records, searchText: "chopin", composer: bach, sort: .byTitle),
            [],
            "both must match"
        )
    }

    func testAFilterWhoseLastPieceIsGoneClearsItself() {
        let ravel = ComposerFilter(piece(title: "X", composer: "Maurice Ravel"))
        XCTAssertEqual(LibraryQuery.resolvedComposerFilter(ravel, in: composers), ravel)

        let withoutRavel = composers.filter { $0.id != "ravel" }
        XCTAssertNil(LibraryQuery.resolvedComposerFilter(ravel, in: withoutRavel))
        XCTAssertNil(LibraryQuery.resolvedComposerFilter(
            .unknown, in: withoutRavel.filter { $0.id != "anon" }
        ))
        XCTAssertNil(LibraryQuery.resolvedComposerFilter(nil, in: composers))
    }
}
