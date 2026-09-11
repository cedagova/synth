import Foundation

/// The two humanization controls the product exposes (REQ-012).
///
/// Deliberately two, and only two. The definition's remaining-uncertainty note
/// and D4 both say the owner gets an on/off and an amount, not a panel of
/// interpretive taste settings; anything deeper is the rubato-and-period-style
/// modelling that is an explicit non-goal.
public struct HumanizationSettings: Equatable, Hashable, Sendable, Codable {
    /// On by default, per REQ-012.
    public let isEnabled: Bool

    /// How much variation, 0…100. 0 is indistinguishable from off; the
    /// difference is that the owner can turn the dial back up.
    public let intensity: Int

    public init(isEnabled: Bool, intensity: Int) {
        self.isEnabled = isEnabled
        self.intensity = min(100, max(0, intensity))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, intensity
    }

    /// Through the designated initializer, so a stored document cannot smuggle
    /// an out-of-range intensity past the clamp.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            intensity: try container.decode(Int.self, forKey: .intensity)
        )
    }

    /// What playback uses when the owner has not chosen: on, moderate.
    public static let standard = HumanizationSettings(isEnabled: true, intensity: 50)

    /// Strictly literal playback.
    public static let off = HumanizationSettings(isEnabled: false, intensity: 0)

    /// True when the stage can be skipped entirely because it would change
    /// nothing.
    public var isLiteral: Bool { !isEnabled || intensity == 0 }
}

/// The two expression controls the product exposes (REQ-003, D65-1).
///
/// Two, and only two, for the reason `HumanizationSettings` is two: the owner
/// gets an on/off and an amount, and everything the setting *does* — where a
/// phrase begins and ends, how far it swells, how long a cadence breathes — is
/// derived from the score by the realizer. A phrase-by-phrase editor is the
/// interpretive modelling D4 rules out.
///
/// Deliberately a separate type from `HumanizationSettings` rather than two
/// more fields on it. They are different *kinds* of deviation and REQ-004
/// turns on telling them apart: humanization is seeded unevenness applied
/// uniformly across the piece, expression is a deterministic reading of the
/// notation's phrase structure. The bypass recipe switches off the second and
/// keeps the first, which is only expressible if they are two values.
public struct ExpressionSettings: Equatable, Hashable, Sendable, Codable {
    /// On by default, per D65-3 — for a fresh preset and for a stored preset
    /// written before the field existed.
    public let isEnabled: Bool

    /// How much shaping, 0…100. 0 is indistinguishable from off; the
    /// difference is that the owner can turn the dial back up.
    public let amount: Int

    public init(isEnabled: Bool, amount: Int) {
        self.isEnabled = isEnabled
        self.amount = min(100, max(0, amount))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, amount
    }

    /// Through the designated initializer, so a stored document cannot smuggle
    /// an out-of-range amount past the clamp — the `HumanizationSettings`
    /// precedent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            amount: try container.decode(Int.self, forKey: .amount)
        )
    }

    /// What playback uses when the owner has not chosen: on, moderate (D65-3).
    public static let standard = ExpressionSettings(isEnabled: true, amount: 50)

    /// No phrase shaping at all — REQ-004's bypass state for this term.
    public static let off = ExpressionSettings(isEnabled: false, amount: 0)

    /// True when the stage can be skipped entirely because it would change
    /// nothing. **Load-bearing for REQ-004**: the bypass is a skipped code
    /// path, not a threshold a comparison has to tolerate.
    public var isNeutral: Bool { !isEnabled || amount == 0 }
}

/// Everything outside the score that decides how a piece is realized.
///
/// AD5 in one type: the timeline is a pure function of `(piece, preset,
/// humanization setting)`, so those three things — and no others — are what a
/// realization is allowed to read.
///
/// `presetIdentifier` is a placeholder shape rather than a placeholder value:
/// increment 004 owns the preset document, and when it arrives it passes its
/// identifier here so a preset change re-seeds the interpretation. Until then
/// every piece realizes under the same empty identifier, which is correct —
/// there is nothing to distinguish yet.
public struct RealizationSettings: Equatable, Hashable, Sendable, Codable {
    /// Identity of the active preset, or `""` before increment 004 exists.
    public let presetIdentifier: String

    public let humanization: HumanizationSettings

    /// Score-derived phrase expression (REQ-003): phrase-shaped dynamics and
    /// cadence breathing, on top of what the notation writes.
    public let expression: ExpressionSettings

    public init(
        presetIdentifier: String = "",
        humanization: HumanizationSettings = .standard,
        expression: ExpressionSettings = .standard
    ) {
        self.presetIdentifier = presetIdentifier
        self.humanization = humanization
        self.expression = expression
    }

    /// Humanization and expression on at their default amounts.
    public static let standard = RealizationSettings()

    /// Strictly literal realization: no humanization, no expression. This is
    /// REQ-004's bypass state for both realization terms.
    public static let literal = RealizationSettings(humanization: .off, expression: .off)

    /// Uniform humanization only — REQ-004's recipe for the expression term:
    /// what the notation writes plus the seeded unevenness, and nothing this
    /// leaf adds.
    public static let humanizedWithoutExpression = RealizationSettings(expression: .off)
}
