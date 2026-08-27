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

    /// Filter then order — what the library list actually shows.
    public static func arrange(
        _ records: [PieceRecord],
        searchText: String,
        sort: LibrarySort
    ) -> [PieceRecord] {
        sorted(filtered(records, matching: searchText), by: sort)
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
        guard field != .importedAt else {
            return left < right ? .orderedAscending : (left == right ? .orderedSame : .orderedDescending)
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

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
