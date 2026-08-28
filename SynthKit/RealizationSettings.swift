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

    /// What playback uses when the owner has not chosen: on, moderate.
    public static let standard = HumanizationSettings(isEnabled: true, intensity: 40)

    /// Strictly literal playback.
    public static let off = HumanizationSettings(isEnabled: false, intensity: 0)

    /// True when the stage can be skipped entirely because it would change
    /// nothing.
    public var isLiteral: Bool { !isEnabled || intensity == 0 }
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

    public init(presetIdentifier: String = "", humanization: HumanizationSettings = .standard) {
        self.presetIdentifier = presetIdentifier
        self.humanization = humanization
    }

    /// Humanization on at its default amount.
    public static let standard = RealizationSettings()

    /// Strictly literal realization.
    public static let literal = RealizationSettings(humanization: .off)
}
