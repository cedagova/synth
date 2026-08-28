import Foundation

/// The owner's small, durable choices, in the versioned store.
///
/// One key-value table rather than a column per setting, and rather than a
/// property list beside the database. The reasons are the same three every
/// time:
///
/// - it is **one** persistence mechanism. The store is already versioned,
///   migrated forward-only and backed up as a unit; a second file beside it
///   would have neither property.
/// - adding a preference needs no migration, so the schema chain stays about
///   real shape changes.
/// - a value that cannot be read is never fatal. Every accessor falls back to
///   the shipped default, because a corrupt preference must not be able to stop
///   a piece from playing.
///
/// Values are text because the table is `STRICT`, and because a preference the
/// owner may one day inspect should be legible.
public final class PreferenceStore: @unchecked Sendable {
    /// Name of the table this store owns.
    public static let tableName = "preferences"

    // MARK: Keys

    /// Whether humanization is applied at all (REQ-012).
    public static let humanizationEnabledKey = "playback.humanization.enabled"

    /// How much humanization, 0…100.
    public static let humanizationIntensityKey = "playback.humanization.intensity"

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: Raw access

    public func string(forKey key: String) throws -> String? {
        try database.scalarText(
            "SELECT value FROM \(Self.tableName) WHERE key = ?;",
            [.text(key)]
        )
    }

    public func setString(_ value: String, forKey key: String) throws {
        try database.execute(
            """
            INSERT INTO \(Self.tableName) (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at;
            """,
            [.text(key), .text(value), .text(SchemaMigrator.timestamp())]
        )
    }

    public func remove(key: String) throws {
        try database.execute("DELETE FROM \(Self.tableName) WHERE key = ?;", [.text(key)])
    }

    // MARK: Humanization (REQ-012)

    /// The stored humanization setting, or `.standard` when nothing usable is
    /// stored.
    ///
    /// A missing, malformed or out-of-range value falls back rather than
    /// throwing: the worst a damaged preference row may do is give the owner
    /// the default interpretation, never an unplayable piece.
    /// `HumanizationSettings` clamps the intensity itself, so a stored `900`
    /// becomes 100 rather than an error.
    public func humanization() -> HumanizationSettings {
        let stored = try? string(forKey: Self.humanizationEnabledKey)
        let storedIntensity = try? string(forKey: Self.humanizationIntensityKey)

        let isEnabled: Bool
        switch stored ?? nil {
        case "1": isEnabled = true
        case "0": isEnabled = false
        default: return .standard
        }

        let intensity = (storedIntensity ?? nil).flatMap(Int.init) ?? HumanizationSettings.standard.intensity
        return HumanizationSettings(isEnabled: isEnabled, intensity: intensity)
    }

    /// Persists the owner's humanization choice.
    public func setHumanization(_ settings: HumanizationSettings) throws {
        try setString(settings.isEnabled ? "1" : "0", forKey: Self.humanizationEnabledKey)
        try setString(String(settings.intensity), forKey: Self.humanizationIntensityKey)
    }
}
