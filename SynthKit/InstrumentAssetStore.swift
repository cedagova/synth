import Foundation

/// What is installed, where it is, and what it may be used for.
///
/// **This is the offline half of the leaf, and it is offline by construction.**
/// Every question INS002 and INS003 will ask — which libraries are installed,
/// where an instrument's SFZ file is, what licence it carries, which REQ-020
/// instruments are missing — is answered from the database and the filesystem.
/// Nothing here can reach the network: it holds no transfer, no URL session and
/// no networking symbol, and `NoNetworkBaselineTests` fails the build if that
/// ever stops being true. REQ-022's "works fully offline after download" is
/// therefore a property of the type rather than a thing to remember to test.
///
/// The database is the authority for *installed*. A directory under `assets/`
/// with no row is debris from an interrupted install, exactly as a file under
/// `pieces/` with no row is debris from an interrupted import — same rule, same
/// reason.

// MARK: - Records

/// One installed library, as the store knows it.
public struct InstalledInstrumentLibrary: Sendable, Equatable {
    public let libraryID: String

    /// Catalog version that installed it, for diagnosis.
    public let catalogVersion: Int

    /// ISO 8601 UTC.
    public let installedAt: String

    /// Bytes transferred to install it.
    public let byteCount: Int64

    public let assetCount: Int

    /// `CatalogLibrary.pinnedManifestDigest` at install time.
    ///
    /// Compared with the running build's catalog: when they differ, the bytes
    /// on disk are a different pinning of the same library and the owner is
    /// offered a re-download rather than told everything is fine.
    public let pinnedManifestDigest: String

    public init(
        libraryID: String,
        catalogVersion: Int,
        installedAt: String,
        byteCount: Int64,
        assetCount: Int,
        pinnedManifestDigest: String
    ) {
        self.libraryID = libraryID
        self.catalogVersion = catalogVersion
        self.installedAt = installedAt
        self.byteCount = byteCount
        self.assetCount = assetCount
        self.pinnedManifestDigest = pinnedManifestDigest
    }
}

/// An instrument that is installed and ready to play.
///
/// The value INS002 opens and INS003 gates capabilities on. Deliberately a
/// resolved thing — real file URLs, not paths to join — so no consumer has to
/// know the container layout.
public struct AvailableInstrument: Sendable, Equatable {
    public let libraryID: String
    public let libraryName: String

    /// The catalog's description of it, including the quality notes INS003
    /// reads.
    public let coverage: InstrumentCoverage

    /// Absolute URL of the primary SFZ entry point.
    public let sfzURL: URL

    /// Absolute URLs of the alternate articulations, in catalog order.
    public let alternateSFZURLs: [URL]

    /// Root of the installed library, which is what an SFZ's `default_path` is
    /// relative to.
    public let libraryRootURL: URL

    /// Attribution the licence obliges the app to show wherever this plays.
    /// Empty for CC0.
    public let requiredAttribution: String

    public init(
        libraryID: String,
        libraryName: String,
        coverage: InstrumentCoverage,
        sfzURL: URL,
        alternateSFZURLs: [URL],
        libraryRootURL: URL,
        requiredAttribution: String
    ) {
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.coverage = coverage
        self.sfzURL = sfzURL
        self.alternateSFZURLs = alternateSFZURLs
        self.libraryRootURL = libraryRootURL
        self.requiredAttribution = requiredAttribution
    }
}

/// Where one catalog library stands right now.
public enum InstrumentLibraryState: Sendable, Equatable {
    /// Nothing of it is on disk.
    case notDownloaded

    /// Some of it is staged from an interrupted transfer.
    case partiallyDownloaded(stagedByteCount: Int64)

    /// Installed and matching this build's pinning.
    case installed(InstalledInstrumentLibrary)

    /// Installed, but from a build whose catalog pinned different bytes.
    case installedFromAnotherCatalog(InstalledInstrumentLibrary)
}

// MARK: - Store

/// The installed-instrument half of the library store.
public final class InstrumentAssetStore: @unchecked Sendable {
    public static let tableName = "installed_instrument_libraries"

    private let database: SQLiteDatabase
    private let staging: AssetStagingArea
    private let catalog: [CatalogLibrary]
    private let fileManager: FileManager

    public init(
        database: SQLiteDatabase,
        assetsRootURL: URL,
        catalog: [CatalogLibrary] = InstrumentCatalog.libraries,
        stagingFileOpener: StagingFileOpening = FileSystemStagingFileOpener(),
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.staging = AssetStagingArea(
            assetsRootURL: assetsRootURL, opener: stagingFileOpener, fileManager: fileManager
        )
        self.catalog = catalog
        self.fileManager = fileManager
    }

    /// The staging area, for the download manager. Read-only to everyone else.
    public var stagingArea: AssetStagingArea { staging }

    public var catalogLibraries: [CatalogLibrary] { catalog }

    // MARK: Reading

    /// Every installed library, oldest install first.
    ///
    /// A row this build cannot decode is a loud failure, for the same reason
    /// `soundRowUnreadable` is: an instrument the owner spent 2.5 GB of
    /// bandwidth on must never quietly stop existing.
    public func installedLibraries() throws -> [InstalledInstrumentLibrary] {
        try database.query(
            """
            SELECT library_id, catalog_version, installed_at, byte_count, asset_count, manifest_digest
            FROM \(Self.tableName)
            ORDER BY installed_at ASC, library_id ASC;
            """
        )
        .map { row in
            guard let libraryID = row.text("library_id"),
                  let catalogVersion = row.integer("catalog_version"),
                  let installedAt = row.text("installed_at"),
                  let byteCount = row.integer("byte_count"),
                  let assetCount = row.integer("asset_count"),
                  let digest = row.text("manifest_digest")
            else {
                throw StoreError.installedInstrumentRowUnreadable(
                    id: row.text("library_id") ?? "(unknown)",
                    reason: "a column is missing or the wrong type."
                )
            }
            return InstalledInstrumentLibrary(
                libraryID: libraryID,
                catalogVersion: Int(catalogVersion),
                installedAt: installedAt,
                byteCount: byteCount,
                assetCount: Int(assetCount),
                pinnedManifestDigest: digest
            )
        }
    }

    public func installedLibrary(withID libraryID: String) throws -> InstalledInstrumentLibrary? {
        try installedLibraries().first { $0.libraryID == libraryID }
    }

    /// Where each catalog library stands, in catalog order.
    public func states() throws -> [(library: CatalogLibrary, state: InstrumentLibraryState)] {
        let installed = try installedLibraries().reduce(into: [String: InstalledInstrumentLibrary]()) {
            $0[$1.libraryID] = $1
        }
        return catalog.map { library in
            (library, state(of: library, installed: installed[library.identifier]))
        }
    }

    public func state(of library: CatalogLibrary) throws -> InstrumentLibraryState {
        state(of: library, installed: try installedLibrary(withID: library.identifier))
    }

    private func state(
        of library: CatalogLibrary, installed: InstalledInstrumentLibrary?
    ) -> InstrumentLibraryState {
        if let installed {
            return installed.pinnedManifestDigest == library.pinnedManifestDigest
                ? .installed(installed)
                : .installedFromAnotherCatalog(installed)
        }
        let staged = stagedByteCount(for: library)
        return staged > 0 ? .partiallyDownloaded(stagedByteCount: staged) : .notDownloaded
    }

    /// How many bytes of `library` are already staged from an interrupted run.
    public func stagedByteCount(for library: CatalogLibrary) -> Int64 {
        library.assets.reduce(0) { total, asset in
            total + staging.stagedByteCount(
                forLibraryID: library.identifier, assetID: asset.identifier
            )
        }
    }

    /// Every instrument the owner can actually play right now.
    ///
    /// Only libraries with a database row are considered, and each SFZ entry
    /// point is checked to exist on disk before its instrument is offered. A
    /// row whose files were deleted from underneath the app therefore yields
    /// nothing rather than a list of instruments that fail when played, which
    /// is what makes the re-download offer honest.
    public func availableInstruments() throws -> [AvailableInstrument] {
        var results: [AvailableInstrument] = []
        for installed in try installedLibraries() {
            guard let library = catalog.first(where: { $0.identifier == installed.libraryID })
            else { continue }
            let root = staging.installedURL(forLibraryID: library.identifier)

            for instrument in library.coverage {
                let sfzURL = root.appending(path: instrument.sfzPath)
                guard fileManager.fileExists(atPath: sfzURL.path(percentEncoded: false)) else {
                    continue
                }
                let alternates = instrument.alternateSFZPaths
                    .map { root.appending(path: $0) }
                    .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }

                results.append(
                    AvailableInstrument(
                        libraryID: library.identifier,
                        libraryName: library.name,
                        coverage: instrument,
                        sfzURL: sfzURL,
                        alternateSFZURLs: alternates,
                        libraryRootURL: root,
                        requiredAttribution: library.licence.requiredAttribution
                    )
                )
            }
        }
        return results
    }

    /// REQ-020 families with nothing installed to play them.
    ///
    /// INS003's missing-instrument flag reads this. Families the catalog cannot
    /// cover at all are included, because "we do not have it" and "you have not
    /// downloaded it" are both reasons a line has no instrument, and the owner
    /// is owed the difference in wording, not in the fact.
    public func familiesWithoutAnInstalledInstrument() throws -> [InstrumentCoverage.Family] {
        let covered = Set(try availableInstruments().map(\.coverage.family))
        return InstrumentCoverage.Family.allCases.filter { !covered.contains($0) }
    }

    /// Attribution lines that must be shown, one per installed library that
    /// requires one, in catalog order.
    public func requiredAttributions() throws -> [(library: CatalogLibrary, attribution: String)] {
        let installedIDs = Set(try installedLibraries().map(\.libraryID))
        return catalog
            .filter { installedIDs.contains($0.identifier) && $0.licence.requiresAttribution }
            .map { ($0, $0.licence.requiredAttribution) }
    }

    // MARK: Writing

    /// Records a completed install. Called only after the staged tree has been
    /// renamed into place.
    public func recordInstall(
        of library: CatalogLibrary,
        catalogVersion: Int = InstrumentCatalog.version,
        at explicitTimestamp: String? = nil
    ) throws {
        let timestamp = explicitTimestamp ?? SchemaMigrator.timestamp()
        try database.execute(
            """
            INSERT INTO \(Self.tableName)
                (library_id, catalog_version, installed_at, byte_count, asset_count, manifest_digest)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_id) DO UPDATE SET
                catalog_version = excluded.catalog_version,
                installed_at = excluded.installed_at,
                byte_count = excluded.byte_count,
                asset_count = excluded.asset_count,
                manifest_digest = excluded.manifest_digest;
            """,
            [
                .text(library.identifier),
                .integer(Int64(catalogVersion)),
                .text(timestamp),
                .integer(library.downloadByteCount),
                .integer(Int64(library.assets.count)),
                .text(library.pinnedManifestDigest)
            ]
        )
    }

    /// Removes a library completely: its files and its row.
    ///
    /// Files first, row second. The other order would leave a window in which
    /// the store says nothing is installed while the bytes are still there —
    /// and a crash in that window would strand 2.5 GB the app no longer knows
    /// about. This order's window is the harmless one: a row with no files,
    /// which `availableInstruments()` already declines to offer.
    public func removeInstalledLibrary(withID libraryID: String) throws {
        try staging.removeInstalled(libraryID: libraryID)
        staging.discardStaging(forLibraryID: libraryID)
        try database.execute(
            "DELETE FROM \(Self.tableName) WHERE library_id = ?;", [.text(libraryID)]
        )
    }

    /// Launch-time tidy-up: drops staging for libraries this build no longer
    /// has a catalog entry for, and drops rows whose files have vanished.
    ///
    /// Staging for a *known* library is deliberately kept — that is the resume.
    @discardableResult
    public func reconcileWithDisk() throws -> (rowsDropped: [String], stagingDropped: Bool) {
        staging.discardStagingForLibrariesNotIn(Set(catalog.map(\.identifier)))

        var dropped: [String] = []
        for installed in try installedLibraries() {
            let root = staging.installedURL(forLibraryID: installed.libraryID)
            if !fileManager.fileExists(atPath: root.path(percentEncoded: false)) {
                try database.execute(
                    "DELETE FROM \(Self.tableName) WHERE library_id = ?;",
                    [.text(installed.libraryID)]
                )
                dropped.append(installed.libraryID)
            }
        }
        return (dropped, true)
    }
}
