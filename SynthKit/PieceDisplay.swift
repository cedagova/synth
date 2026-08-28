import Foundation

/// How a piece reads on screen and to VoiceOver.
///
/// These live in SynthKit rather than the view layer for one reason: the
/// accessibility label REQ-027 promises is derived text, and derived text that
/// is only ever assembled inside a `View` cannot be tested. Every string the
/// library list shows — including the one VoiceOver speaks for a row — comes
/// from here.
extension PieceRecord {
    /// Shown wherever a composer is missing. A piece is never blank-authored on
    /// screen; the score simply did not name anyone.
    public static let unknownComposer = "Unknown composer"

    /// The composer, or `unknownComposer`.
    public var composerDescription: String {
        Self.presentable(composer) ?? Self.unknownComposer
    }

    /// `work-title` and `work-number` as one line, when the score has either.
    ///
    /// - "Das wohltemperierte Klavier (BWV 846)"
    /// - "Das wohltemperierte Klavier"
    /// - "BWV 846"
    public var workDescription: String? {
        switch (Self.presentable(workTitle), Self.presentable(workNumber)) {
        case let (title?, number?): return "\(title) (\(number))"
        case let (title?, nil): return title
        case let (nil, number?): return number
        case (nil, nil): return nil
        }
    }

    /// `movement-number` and `movement-title` as one line, when the score has
    /// either.
    ///
    /// - "2. Andante"
    /// - "Andante"
    /// - "Movement 2"
    public var movementDescription: String? {
        switch (Self.presentable(movementNumber), Self.presentable(movementTitle)) {
        case let (number?, title?): return "\(number). \(title)"
        case let (nil, title?): return title
        case let (number?, nil): return "Movement \(number)"
        case (nil, nil): return nil
        }
    }

    /// The secondary line under the title: composer, then work, then movement.
    public var subtitleDescription: String {
        [composerDescription, workDescription, movementDescription]
            .compactMap { $0 }
            .joined(separator: " — ")
    }

    /// What VoiceOver speaks for this piece's row.
    ///
    /// Spelled out rather than punctuated so it is heard as a sentence:
    /// "Prelude in C, composer Bach, movement 2. Andante".
    public var accessibilityDescription: String {
        var spoken = title
        spoken += ", composer \(composerDescription)"
        if let work = workDescription {
            spoken += ", work \(work)"
        }
        if let movement = movementDescription {
            spoken += ", movement \(movement)"
        }
        return spoken
    }

    /// Every metadata field library search looks at, in display order.
    ///
    /// `sourceFileName` is included deliberately: the owner who exported
    /// `bwv846.musicxml` and cannot remember the title still finds it.
    public var searchableFields: [String] {
        [
            title,
            composer,
            workTitle,
            workNumber,
            movementTitle,
            movementNumber,
            sourceFileName
        ].compactMap { Self.presentable($0) }
    }

    /// Trims a stored value and treats whitespace-only as absent, so a score
    /// that declared `<creator type="composer"> </creator>` reads as unknown
    /// rather than blank.
    private static func presentable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
