import Foundation

/// Which metadata the library list is ordered by.
public enum LibrarySortField: String, CaseIterable, Sendable, Identifiable, Equatable {
    case title
    case composer
    case movement
    case importedAt

    public var id: String { rawValue }

    /// Column-header wording for the sort control.
    public var label: String {
        switch self {
        case .title: return "Title"
        case .composer: return "Composer"
        case .movement: return "Movement"
        case .importedAt: return "Date Imported"
        }
    }
}

/// Which way a `LibrarySortField` runs.
public enum LibrarySortDirection: String, CaseIterable, Sendable, Equatable {
    case ascending
    case descending

    public var flipped: LibrarySortDirection {
        self == .ascending ? .descending : .ascending
    }

    /// Wording that suits the field, because "A to Z" is meaningless for a date.
    public func label(for field: LibrarySortField) -> String {
        switch (field, self) {
        case (.importedAt, .ascending): return "Oldest First"
        case (.importedAt, .descending): return "Newest First"
        case (_, .ascending): return "A to Z"
        case (_, .descending): return "Z to A"
        }
    }
}

/// A complete library ordering.
public struct LibrarySort: Equatable, Sendable {
    public var field: LibrarySortField
    public var direction: LibrarySortDirection

    /// What the library opens with: alphabetical by title, which is also the
    /// order the catalog returns rows in.
    public static let byTitle = LibrarySort(field: .title, direction: .ascending)

    public init(field: LibrarySortField, direction: LibrarySortDirection) {
        self.field = field
        self.direction = direction
    }

    public var label: String {
        "\(field.label), \(direction.label(for: field))"
    }
}

/// One entry the composer filter can narrow the library to.
///
/// A named composer is identified by its stored name folded for case and
/// diacritics, so "Dvořák" and "dvorak" are one entry; stored names are never
/// edited or merged beyond that. Pieces with no composer — or a blank one —
/// share the `unknown` entry.
public enum ComposerFilter: Hashable, Sendable {
    case named(String)
    case unknown

    /// The filter a piece belongs to.
    public init(_ record: PieceRecord) {
        if let name = record.composer.flatMap(LibraryQuery.nonEmpty) {
            self = .named(LibraryQuery.foldedComposerName(name))
        } else {
            self = .unknown
        }
    }
}

/// One row of the composer filter: who, and how many pieces.
public struct ComposerFacetEntry: Identifiable, Equatable, Sendable {
    public let filter: ComposerFilter
    /// The stored name as the owner wrote it, or "Unknown composer".
    public let name: String
    public let count: Int

    public var id: ComposerFilter { filter }

    public init(filter: ComposerFilter, name: String, count: Int) {
        self.filter = filter
        self.name = name
        self.count = count
    }
}

/// Search and ordering over the library's records.
///
/// Pure functions over an already-loaded array rather than SQL. The library is
/// a personal collection of scores — hundreds, not millions — so filtering in
/// memory keeps typing instantaneous with no round trip, and makes the exact
/// matching and ordering rules testable without a database.
public enum LibraryQuery {
    /// True when `searchText` appears anywhere in the piece's metadata.
    ///
    /// Case- and diacritic-insensitive, so `dvorak` finds *Dvořák*. An empty or
    /// whitespace-only query matches everything, which is what makes clearing
    /// the search field restore the full library.
    public static func matches(_ record: PieceRecord, searchText: String) -> Bool {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return record.searchableFields.contains { field in
            field.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: nil
            ) != nil
        }
    }

    /// The records matching `searchText`, order preserved.
    public static func filtered(_ records: [PieceRecord], matching searchText: String) -> [PieceRecord] {
        records.filter { matches($0, searchText: searchText) }
    }

    // MARK: - Composer filter

    /// True when the piece belongs to `composer`; a nil filter matches all.
    public static func matches(_ record: PieceRecord, composer: ComposerFilter?) -> Bool {
        guard let composer else { return true }
        return ComposerFilter(record) == composer
    }

    /// The composer filter's entries for `records`, with counts.
    ///
    /// Named composers are ordered by `surnameSortKey`, with the full name
    /// breaking ties; "Unknown composer" is always last. Spellings that differ
    /// only in case or diacritics are one entry, shown under the spelling most
    /// pieces use (ties go to the one that sorts first).
    public static func composerFacet(_ records: [PieceRecord]) -> [ComposerFacetEntry] {
        var spellings: [ComposerFilter: [String: Int]] = [:]
        var unknownCount = 0
        for record in records {
            let filter = ComposerFilter(record)
            switch filter {
            case .unknown:
                unknownCount += 1
            case .named:
                let name = record.composer.flatMap(nonEmpty) ?? ""
                spellings[filter, default: [:]][name, default: 0] += 1
            }
        }

        var entries = spellings.map { filter, names -> ComposerFacetEntry in
            // Most pieces wins; then the spelling that sorts first; then bytes,
            // so the choice never depends on dictionary order.
            let shown = names.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                switch compareComposers(lhs.key, rhs.key) {
                case .orderedAscending: return false
                case .orderedDescending: return true
                case .orderedSame: return lhs.key > rhs.key
                }
            }!.key
            return ComposerFacetEntry(filter: filter, name: shown, count: names.values.reduce(0, +))
        }
        entries.sort { lhs, rhs in
            switch compareComposers(lhs.name, rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                guard case let .named(left) = lhs.filter, case let .named(right) = rhs.filter else {
                    return false
                }
                return left < right
            }
        }
        if unknownCount > 0 {
            entries.append(ComposerFacetEntry(filter: .unknown, name: "Unknown composer", count: unknownCount))
        }
        return entries
    }

    /// `filter` if some record still belongs to it, otherwise nil — so a
    /// filter whose last piece was removed clears itself.
    public static func resolvedComposerFilter(
        _ filter: ComposerFilter?,
        in records: [PieceRecord]
    ) -> ComposerFilter? {
        guard let filter else { return nil }
        return records.contains { ComposerFilter($0) == filter } ? filter : nil
    }

    /// The part of a composer's name that orders it: the text before a comma
    /// when there is one ("Bach, Johann Sebastian"), otherwise the last word
    /// ("Johann Sebastian Bach"), otherwise the whole name ("Palestrina").
    ///
    /// Computed at query time and never stored. Compound surnames written
    /// "First Last" ("Ralph Vaughan Williams") file under their last word;
    /// writing them in comma form files them correctly.
    public static func surnameSortKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ",") {
            let before = trimmed[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { return before }
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.last.map(String.init) ?? trimmed
    }

    /// Surname first, then the full name, both in natural order.
    static func compareComposers(_ left: String, _ right: String) -> ComparisonResult {
        let bySurname = surnameSortKey(left).localizedStandardCompare(surnameSortKey(right))
        guard bySurname == .orderedSame else { return bySurname }
        return left.localizedStandardCompare(right)
    }

    static func foldedComposerName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The records in `sort` order.
    ///
    /// Two rules make this a total order, so the list never reshuffles between
    /// two equal-looking rows:
    ///
    /// - a piece with no value for the sorted field goes **last in both
    ///   directions** — reversing the sort should not promote the unknowns to
    ///   the top; and
    /// - ties break by title, then import time, then identifier, always
    ///   ascending, so only the chosen field responds to the direction toggle.
    public static func sorted(_ records: [PieceRecord], by sort: LibrarySort) -> [PieceRecord] {
        records.sorted { lhs, rhs in
            switch primaryComparison(lhs, rhs, sort: sort) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return tieBreak(lhs, rhs) == .orderedAscending
            }
        }
    }

    /// Filter then order — what the library list actually shows. The composer
    /// filter and the text search both apply.
    public static func arrange(
        _ records: [PieceRecord],
        searchText: String,
        composer: ComposerFilter? = nil,
        sort: LibrarySort
    ) -> [PieceRecord] {
        let narrowed = records.filter { matches($0, composer: composer) }
        return sorted(filtered(narrowed, matching: searchText), by: sort)
    }

    // MARK: - Ordering

    private static func primaryComparison(
        _ lhs: PieceRecord,
        _ rhs: PieceRecord,
        sort: LibrarySort
    ) -> ComparisonResult {
        let left = sortKey(of: lhs, field: sort.field)
        let right = sortKey(of: rhs, field: sort.field)

        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending   // unknowns last, both ways
        case (_, nil): return .orderedAscending
        case let (left?, right?):
            let result = compare(left, right, field: sort.field)
            guard sort.direction == .descending else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }
    }

    /// The text a field sorts on, or `nil` when the score never supplied it.
    private static func sortKey(of record: PieceRecord, field: LibrarySortField) -> String? {
        switch field {
        case .title: return record.title
        case .composer: return record.composer.flatMap(nonEmpty)
        case .movement: return record.movementDescription
        case .importedAt: return record.importedAt
        }
    }

    /// Import time is stored as fixed-width ISO 8601 UTC, so a plain byte
    /// comparison is already chronological — and, unlike a localized compare,
    /// cannot be reordered by the user's locale.
    private static func compare(
        _ left: String,
        _ right: String,
        field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .importedAt:
            return left < right ? .orderedAscending : (left == right ? .orderedSame : .orderedDescending)
        case .composer:
            return compareComposers(left, right)
        case .title, .movement:
            break
        }
        // Natural ordering: "Movement 10" follows "Movement 2" rather than
        // preceding it, and case never decides a tie on its own.
        return left.localizedStandardCompare(right)
    }

    private static func tieBreak(_ lhs: PieceRecord, _ rhs: PieceRecord) -> ComparisonResult {
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        guard byTitle == .orderedSame else { return byTitle }
        guard lhs.importedAt == rhs.importedAt else {
            return lhs.importedAt < rhs.importedAt ? .orderedAscending : .orderedDescending
        }
        guard lhs.id == rhs.id else {
            return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
