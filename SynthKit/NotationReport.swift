import Foundation

/// Why an entry is in the report.
public enum NotationReportCategory: String, Equatable, Sendable, Codable, CaseIterable {
    /// The compiler recognised the notation and did not turn it into anything
    /// audible. Nothing is silently dropped: if it is here, it was seen.
    case notHonored

    /// The notation was contradictory or incomplete, and the compiler applied
    /// a documented fallback so the piece still plays.
    case structuralFallback
}

/// Where in the score something was found.
public struct ScoreLocation: Equatable, Sendable, Codable {
    /// `score-part/@id`, when the finding belongs to a part.
    public let partID: String?

    /// The part's printed name, for display.
    public let partName: String?

    /// Index into `CompiledScore.sourceMeasures`.
    public let sourceMeasureIndex: Int?

    /// The measure's printed number.
    public let measureNumber: String?

    public init(
        partID: String? = nil,
        partName: String? = nil,
        sourceMeasureIndex: Int? = nil,
        measureNumber: String? = nil
    ) {
        self.partID = partID
        self.partName = partName
        self.sourceMeasureIndex = sourceMeasureIndex
        self.measureNumber = measureNumber
    }

    /// One line an owner can read, e.g. `Violin I, measure 12`.
    public var displayText: String {
        var pieces: [String] = []
        if let partName, !partName.isEmpty {
            pieces.append(partName)
        } else if let partID {
            pieces.append("part \(partID)")
        }
        if let measureNumber {
            pieces.append("measure \(measureNumber)")
        } else if let sourceMeasureIndex {
            pieces.append("measure \(sourceMeasureIndex + 1)")
        }
        return pieces.isEmpty ? "the whole score" : pieces.joined(separator: ", ")
    }
}

/// One kind of finding, in one part, with where it was first seen and how
/// often it occurred.
///
/// Aggregated rather than one entry per occurrence: a score that uses an
/// unsupported ornament fifty times is one fact the owner needs to know, not
/// fifty rows to scroll past. The first location is kept so the finding can
/// still be pointed at in the score.
public struct NotationReportEntry: Equatable, Sendable, Codable {
    public let category: NotationReportCategory

    /// What it is, e.g. `ornament: mordent`, `grace note`, or
    /// `unmatched backward repeat`.
    public let kind: String

    /// Where it was first met.
    public let firstLocation: ScoreLocation

    /// How many times it was met.
    public let occurrenceCount: Int

    /// What the compiler did about it, for a fallback; a short clarification
    /// otherwise.
    public let detail: String?

    public init(
        category: NotationReportCategory,
        kind: String,
        firstLocation: ScoreLocation,
        occurrenceCount: Int,
        detail: String?
    ) {
        self.category = category
        self.kind = kind
        self.firstLocation = firstLocation
        self.occurrenceCount = occurrenceCount
        self.detail = detail
    }

    /// One sentence for the piece report UI (PLY004).
    public var displayText: String {
        let where_ = firstLocation.displayText
        let times = occurrenceCount == 1 ? "" : " (\(occurrenceCount) occurrences, first at"
        let head = occurrenceCount == 1 ? "\(kind) at \(where_)" : "\(kind)\(times) \(where_))"
        guard let detail, !detail.isEmpty else { return head }
        return "\(head) — \(detail)"
    }
}

/// Everything one compilation met and did not honour (REQ-014's data).
///
/// The UI that shows this is PLY004; this leaf owns the data and its ordering.
/// Ordering is canonical — category, then kind, then first location — so the
/// same file always produces the same report bytes.
public struct NotationReport: Equatable, Sendable, Codable {
    public let entries: [NotationReportEntry]

    /// How many distinct findings were dropped because the report hit its cap.
    /// Zero in every ordinary score.
    public let truncatedKindCount: Int

    public init(entries: [NotationReportEntry], truncatedKindCount: Int = 0) {
        self.entries = entries
        self.truncatedKindCount = truncatedKindCount
    }

    public var isEmpty: Bool { entries.isEmpty && truncatedKindCount == 0 }

    /// Entries of one category, in canonical order.
    public func entries(in category: NotationReportCategory) -> [NotationReportEntry] {
        entries.filter { $0.category == category }
    }

    /// True when some entry names `kind`.
    public func mentions(kind: String) -> Bool {
        entries.contains { $0.kind == kind }
    }
}

/// Accumulates report findings during a compilation, then freezes them into a
/// canonically ordered `NotationReport`.
///
/// Not thread-safe and not meant to be: one compilation, one collector.
struct NotationReportCollector {
    /// Most distinct (category, kind, part) findings a report will carry.
    /// A score that trips more than this has a systemic problem, and the
    /// overflow count says so without producing an unreadable list.
    static let maximumEntryCount = 200

    private struct Key: Hashable {
        let category: NotationReportCategory
        let kind: String
        let partID: String?
    }

    private struct Accumulated {
        let location: ScoreLocation
        let detail: String?
        var count: Int
        /// Insertion order, so the fold is stable before sorting.
        let sequence: Int
    }

    private var findings: [Key: Accumulated] = [:]
    private var overflowKinds: Set<Key> = []
    private var nextSequence = 0

    /// Records one occurrence.
    mutating func record(
        _ category: NotationReportCategory,
        kind: String,
        at location: ScoreLocation = ScoreLocation(),
        detail: String? = nil
    ) {
        let key = Key(category: category, kind: kind, partID: location.partID)
        if findings[key] != nil {
            findings[key]?.count += 1
            return
        }
        guard findings.count < Self.maximumEntryCount else {
            overflowKinds.insert(key)
            return
        }
        findings[key] = Accumulated(
            location: location,
            detail: detail,
            count: 1,
            sequence: nextSequence
        )
        nextSequence += 1
    }

    /// The finished report, canonically ordered.
    func finish() -> NotationReport {
        let sorted = findings
            .map { key, value -> (Key, Accumulated) in (key, value) }
            .sorted { left, right in
                if left.0.category != right.0.category {
                    return left.0.category.rawValue < right.0.category.rawValue
                }
                if left.0.kind != right.0.kind {
                    return left.0.kind < right.0.kind
                }
                let leftMeasure = left.1.location.sourceMeasureIndex ?? Int.max
                let rightMeasure = right.1.location.sourceMeasureIndex ?? Int.max
                if leftMeasure != rightMeasure {
                    return leftMeasure < rightMeasure
                }
                return (left.0.partID ?? "") < (right.0.partID ?? "")
            }

        return NotationReport(
            entries: sorted.map { key, value in
                NotationReportEntry(
                    category: key.category,
                    kind: key.kind,
                    firstLocation: value.location,
                    occurrenceCount: value.count,
                    detail: value.detail
                )
            },
            truncatedKindCount: overflowKinds.count
        )
    }
}
