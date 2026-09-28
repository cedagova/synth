import Foundation

/// Pre-migration copies of the library database.
///
/// Before `SchemaMigrator` upgrades a store that already has a schema, it
/// writes the whole store to `backups/library-v<from>-<timestamp>.sqlite` with
/// `VACUUM INTO`: a consistent, self-contained snapshot that opens as an
/// ordinary database at the old schema. If that copy cannot be made the
/// migration does not run. After a successful copy only the newest
/// `retainedCount` backups are kept.
///
/// This is the cheapest step toward going back to an older build (#36); it does
/// not restore anything by itself.
public enum LibraryBackup {
    /// How many backups survive pruning, the one just written included.
    public static let retainedCount = 3

    /// What writing a backup produced.
    public struct Outcome: Equatable, Sendable {
        /// The backup file just written.
        public let backupURL: URL

        /// Why pruning older backups failed, when it did. Pruning never blocks
        /// the migration; this is how its failure stays visible.
        public let pruningFailure: String?
    }

    /// The backup file name for a store at `schemaVersion`, taken at `date`.
    ///
    /// The timestamp is UTC to the millisecond and sorts as text, which is
    /// what pruning orders by.
    public static func fileName(schemaVersion: Int, date: Date) -> String {
        "library-v\(schemaVersion)-\(timestamp(date)).sqlite"
    }

    /// Writes a backup of `database` (currently at `schemaVersion`) into
    /// `directoryURL`, then prunes to the newest `retainedCount`.
    ///
    /// The copy is written under a temporary name and moved into place only
    /// once complete, so a half-written file (a full disk) never carries a
    /// backup name — and so can never displace a good backup in pruning.
    ///
    /// - Throws: `StoreError.migrationBackupFailed` naming the backup file when
    ///   the directory cannot be created or the copy cannot be written.
    @discardableResult
    public static func write(
        _ database: SQLiteDatabase,
        schemaVersion: Int,
        into directoryURL: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let name = fileName(schemaVersion: schemaVersion, date: date)
        let backupURL = directoryURL.appending(path: name)
        let partialURL = directoryURL.appending(path: ".\(name).partial")

        func failure(_ reason: String) -> StoreError {
            .migrationBackupFailed(path: backupURL.path(percentEncoded: false), reason: reason)
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw failure((error as NSError).localizedDescription)
        }

        do {
            try database.execute("VACUUM INTO ?;", [.text(partialURL.path(percentEncoded: false))])
            // VACUUM INTO does not guarantee its output is on disk. Flush it
            // before it takes a backup name, so a power cut can never leave a
            // backup-named file that is incomplete.
            try flushToDisk(partialURL)
            try fileManager.moveItem(at: partialURL, to: backupURL)
        } catch {
            removeBestEffort(partialURL, fileManager: fileManager)
            throw failure(
                (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
            )
        }

        var pruningFailure: String?
        do {
            try prune(directoryURL, keeping: retainedCount, protecting: backupURL, fileManager: fileManager)
        } catch {
            let reason = (error as NSError).localizedDescription
            NSLog("Synth: could not prune old library backups in %@: %@",
                  directoryURL.path(percentEncoded: false), reason)
            pruningFailure = reason
        }

        return Outcome(backupURL: backupURL, pruningFailure: pruningFailure)
    }

    /// The backup files in `directoryURL`, newest first. Only names this type
    /// writes are listed; anything else in the folder is not a backup.
    public static func backups(in directoryURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (url: URL, stamp: String)? in
            guard let stamp = timestampComponent(of: url.lastPathComponent) else { return nil }
            return (url, stamp)
        }
        .sorted { ($0.stamp, $0.url.lastPathComponent) > ($1.stamp, $1.url.lastPathComponent) }
        .map(\.url)
    }

    /// Deletes all but `count` backups: `protected` (the one just written) and
    /// the newest `count - 1` others. Touches only files whose names match the
    /// backup pattern.
    ///
    /// The just-written backup is never a candidate, whatever its timestamp:
    /// if the clock once ran ahead and left future-dated backups, ordering by
    /// name alone would prune the only copy of the store about to be migrated.
    static func prune(
        _ directoryURL: URL,
        keeping count: Int,
        protecting protected: URL,
        fileManager: FileManager
    ) throws {
        let others = try backups(in: directoryURL, fileManager: fileManager)
            .filter { $0.lastPathComponent != protected.lastPathComponent }
        for url in others.dropFirst(max(count - 1, 0)) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Forces `url`'s contents to permanent storage (`F_FULLFSYNC`, which on
    /// Apple platforms also flushes the drive's cache; plain `fsync` does not).
    private static func flushToDisk(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            // Some file systems do not support F_FULLFSYNC; fsync is the
            // strongest remaining guarantee, and its failure is a real one.
            try handle.synchronize()
        }
    }

    /// The timestamp part of a backup file name, or `nil` when the name is not
    /// exactly `library-v<digits>-<yyyyMMdd'T'HHmmssSSS'Z'>.sqlite`.
    static func timestampComponent(of name: String) -> String? {
        let prefix = "library-v", suffix = ".sqlite"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let dash = middle.firstIndex(of: "-") else { return nil }
        let version = middle[..<dash]
        let stamp = middle[middle.index(after: dash)...]
        guard !version.isEmpty, version.allSatisfy(\.isASCIIDigit) else { return nil }

        // 8 date digits, "T", 9 time digits (HHmmssSSS), "Z".
        let characters = Array(stamp)
        guard characters.count == 19, characters[8] == "T", characters[18] == "Z",
              characters[0..<8].allSatisfy(\.isASCIIDigit),
              characters[9..<18].allSatisfy(\.isASCIIDigit)
        else { return nil }
        return String(stamp)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }

    private static func removeBestEffort(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            NSLog("Synth: could not remove incomplete library backup at %@: %@",
                  url.path(percentEncoded: false), (error as NSError).localizedDescription)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
