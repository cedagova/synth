import Foundation

/// The curated instrument catalog: what Synth offers to download, where it
/// comes from, what it costs in bytes, and what it is legally.
///
/// **The catalog is app content, not user data** — exactly as
/// `ShippedSoundCollection` is. It is compiled into the build and updated with
/// the app (AD6), so a source that moves is a code change with a review and a
/// pinned checksum behind it, never a silent runtime redirect. Nothing here is
/// fetched; the only thing the network is ever used for is pulling the exact
/// bytes these declarations name (REQ-028).
///
/// Three properties are load-bearing and are why the shape looks the way it
/// does:
///
/// 1. **Every asset is pinned to immutable bytes.** A GitHub asset is pinned to
///    a commit SHA and carries that commit's git blob identifier; an archive is
///    pinned to its SHA-256. Both are verified while the bytes stream in, so a
///    source that changes underneath us fails loudly instead of installing
///    something else.
/// 2. **Every asset is resumable.** Each source was checked to answer
///    `Accept-Ranges: bytes` with a stable `Content-Length`; the byte counts
///    below are that `Content-Length`. This is why GitHub's auto-generated tag
///    archives are not used: they advertise neither, and their bytes are not
///    stable over time.
/// 3. **Redistribution is a property of the licence, not of convenience.** A
///    `mirrorable` library may be fetched from anywhere we like; a
///    `hotlinkOnly` one may only ever be fetched from its canonical host and
///    never re-hosted. The type makes the second case impossible to forget.

// MARK: - Licence

/// What a curated library is, legally, and what that permits.
public struct InstrumentLicence: Sendable, Equatable, Hashable, Codable {
    /// How the licence lets us distribute the content.
    public enum Redistribution: String, Sendable, Equatable, Hashable, Codable {
        /// CC0 / CC-BY: the bytes may be mirrored anywhere, with attribution
        /// where the licence asks for it.
        case mirrorable

        /// Mixed or unclear terms: the bytes may only ever be fetched from the
        /// canonical host, and may never be re-hosted by us.
        case hotlinkOnly
    }

    /// SPDX identifier where one exists (`CC0-1.0`, `CC-BY-3.0`, …).
    public let spdxIdentifier: String

    /// Human name, as the licence itself titles it.
    public let name: String

    /// Canonical licence text URL, shown in the licence sheet.
    public let textURL: String

    /// The exact attribution the licence requires, ready to display and to
    /// copy. Empty for CC0, which requires none.
    public let requiredAttribution: String

    public let redistribution: Redistribution

    public init(
        spdxIdentifier: String,
        name: String,
        textURL: String,
        requiredAttribution: String,
        redistribution: Redistribution
    ) {
        self.spdxIdentifier = spdxIdentifier
        self.name = name
        self.textURL = textURL
        self.requiredAttribution = requiredAttribution
        self.redistribution = redistribution
    }

    /// True when the licence obliges us to show a credit.
    public var requiresAttribution: Bool { !requiredAttribution.isEmpty }
}

// MARK: - Digest

/// How an asset's bytes are pinned.
///
/// Two algorithms rather than one, because the two source shapes publish
/// different primitives and both are exact:
///
/// * A file served by `raw.githubusercontent.com` at a pinned commit **is** a
///   git blob, and its blob identifier is published in that commit's tree. That
///   identifier is what pins the URL's content, so it is what we check.
/// * An archive on an ordinary web host publishes nothing, so we pin the
///   SHA-256 we measured.
///
/// Both are computed while the bytes stream past, so neither needs the whole
/// asset in memory.
public struct AssetDigest: Sendable, Equatable, Hashable, Codable {
    public enum Algorithm: String, Sendable, Equatable, Hashable, Codable {
        /// SHA-256 of the asset's bytes.
        case sha256

        /// Git's blob identifier: `SHA-1("blob " + byteCount + "\0" + bytes)`.
        case gitBlobSHA1
    }

    public let algorithm: Algorithm

    /// Lower-case hexadecimal.
    public let hexValue: String

    public init(algorithm: Algorithm, hexValue: String) {
        self.algorithm = algorithm
        self.hexValue = hexValue.lowercased()
    }

    public static func sha256(_ hex: String) -> AssetDigest {
        AssetDigest(algorithm: .sha256, hexValue: hex)
    }

    public static func gitBlob(_ hex: String) -> AssetDigest {
        AssetDigest(algorithm: .gitBlobSHA1, hexValue: hex)
    }

    /// How the digest is named to the owner when it does not match.
    public var displayName: String {
        switch algorithm {
        case .sha256: return "SHA-256 checksum"
        case .gitBlobSHA1: return "git content identifier"
        }
    }
}

// MARK: - Asset

/// One pinned, downloadable file.
public struct CatalogAsset: Sendable, Equatable, Hashable, Codable {
    /// Stable identity inside its library.
    ///
    /// Free-form: the staging file it downloads into is named by a hash of this
    /// (`AssetStagingArea.stagingFileName`), not by the string itself, so an
    /// identifier may be a path, a slug or a digest without any of them having
    /// to be a legal file name.
    public let identifier: String

    /// Absolute HTTPS URL of the exact bytes. Always `https`; `CatalogAsset`
    /// refuses anything else at construction.
    public let sourceURL: String

    /// Byte count the host reports, and the count we require.
    public let byteCount: Int64

    public let digest: AssetDigest

    /// What the bytes are once they have arrived.
    public enum Payload: Sendable, Equatable, Hashable, Codable {
        /// A single file, installed at `path` relative to the library root.
        case file(path: String)

        /// A `.tar.xz` archive, unpacked into the library root. `stripComponents`
        /// drops that many leading path components from every member, which is
        /// how a tarball with one wrapper directory installs flat.
        case tarXZArchive(stripComponents: Int)

        /// A `.zip` archive, unpacked the same way.
        case zipArchive(stripComponents: Int)

        /// True when the payload has to be unpacked rather than written
        /// straight to its install path.
        public var isArchive: Bool {
            switch self {
            case .file: return false
            case .tarXZArchive, .zipArchive: return true
            }
        }
    }

    public let payload: Payload

    public init(
        identifier: String,
        sourceURL: String,
        byteCount: Int64,
        digest: AssetDigest,
        payload: Payload
    ) {
        self.identifier = identifier
        self.sourceURL = sourceURL
        self.byteCount = byteCount
        self.digest = digest
        self.payload = payload
    }

    /// The parsed URL, whatever its scheme.
    ///
    /// The download manager uses this and does **not** judge the scheme, for
    /// one reason: a scheme check spread over several files is a rule with
    /// several places to get it wrong. There are exactly two enforcement
    /// points, and they are the two that matter —
    /// the allow-listed transport's `fetch`, the only code that can open a
    /// connection at all, refuses anything but HTTPS at the moment of use; and
    /// `httpsURL` below is what `InstrumentCatalog.problems` checks, so a
    /// non-HTTPS URL in the shipped catalog is a failing test rather than a
    /// runtime surprise.
    public var resolvedURL: URL? {
        guard let url = URL(string: sourceURL), url.host() != nil else { return nil }
        return url
    }

    /// The parsed URL, or nil when it is not a well-formed **HTTPS** URL.
    ///
    /// `InstrumentCatalog.problems` turns a nil here into a test failure over
    /// the real catalog, which is what keeps REQ-028's "HTTPS only" true of
    /// every asset this build can ever be asked to fetch.
    public var httpsURL: URL? {
        guard let url = resolvedURL, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

// MARK: - Coverage

/// One playable instrument a library provides, and the honest truth about it.
///
/// The quality notes are REQ-021's "degrade visibly, never fake" at catalog
/// level and the plan's "surface per-instrument quality honestly". INS003 reads
/// them to decide which customization controls it may offer.
public struct InstrumentCoverage: Sendable, Equatable, Hashable, Codable {
    /// The instrument families REQ-020 names.
    public enum Family: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case strings
        case woodwinds
        case brass
        case keyboards
        case harp
        case percussion

        public var displayName: String {
            switch self {
            case .strings: return "Strings"
            case .woodwinds: return "Woodwinds"
            case .brass: return "Brass"
            case .keyboards: return "Keyboards"
            case .harp: return "Harp"
            case .percussion: return "Percussion"
            }
        }
    }

    /// Stable identity, unique across the whole catalog.
    public let identifier: String

    /// What the owner calls it: "Violin section", "Grand piano".
    public let name: String

    public let family: Family

    /// SFZ entry point, relative to the installed library root. This is the
    /// file INS002 opens by default.
    public let sfzPath: String

    /// Other articulations of the same instrument — pizzicato, staccato,
    /// tremolo, muted, keyswitched — as further SFZ entry points relative to
    /// the library root.
    ///
    /// One instrument with several articulations rather than several
    /// instruments, because that is what the owner is choosing: a line is
    /// assigned "Violin section", not "ViolinEnsSpic.sfz". Which articulation
    /// plays is INS003's decision surface, so the paths are carried here and
    /// used by nobody in this leaf.
    public let alternateSFZPaths: [String]

    /// How many distinct velocity layers the samples provide. 1 means the
    /// instrument has no sampled dynamics at all and everything expressive
    /// about its loudness will be synthetic.
    public let dynamicLayerCount: Int

    /// Plain-language bounds worth saying out loud before the owner relies on
    /// it — "section patch standing in for a solo line", "no true legato".
    /// Empty when there is genuinely nothing to warn about.
    public let qualityNotes: [String]

    public init(
        identifier: String,
        name: String,
        family: Family,
        sfzPath: String,
        alternateSFZPaths: [String] = [],
        dynamicLayerCount: Int,
        qualityNotes: [String] = []
    ) {
        self.identifier = identifier
        self.name = name
        self.family = family
        self.sfzPath = sfzPath
        self.alternateSFZPaths = alternateSFZPaths
        self.dynamicLayerCount = dynamicLayerCount
        self.qualityNotes = qualityNotes
    }

    /// Every SFZ this instrument offers, primary first.
    public var allSFZPaths: [String] { [sfzPath] + alternateSFZPaths }
}

// MARK: - Library

/// One curated library: a set of pinned assets and the instruments they play.
public struct CatalogLibrary: Sendable, Equatable, Hashable, Codable {
    /// Stable identity. Also the installed directory's name under `assets/`,
    /// so it must be safe as a single path component.
    public let identifier: String

    public let name: String

    /// Who made it, for the credit line.
    public let publisher: String

    /// One or two sentences describing what the owner gets.
    public let summary: String

    public let licence: InstrumentLicence

    /// Where a human can go to read about it.
    public let homepageURL: String

    public let assets: [CatalogAsset]

    public let coverage: [InstrumentCoverage]

    /// True when the library is not part of the default curated set — an opt-in
    /// extra the owner can add, not something the first-run offer includes.
    public let isOptional: Bool

    public init(
        identifier: String,
        name: String,
        publisher: String,
        summary: String,
        licence: InstrumentLicence,
        homepageURL: String,
        assets: [CatalogAsset],
        coverage: [InstrumentCoverage],
        isOptional: Bool = false
    ) {
        self.identifier = identifier
        self.name = name
        self.publisher = publisher
        self.summary = summary
        self.licence = licence
        self.homepageURL = homepageURL
        self.assets = assets
        self.coverage = coverage
        self.isOptional = isOptional
    }

    /// Total bytes to transfer for a complete install.
    public var downloadByteCount: Int64 {
        assets.reduce(0) { $0 + $1.byteCount }
    }

    /// The families this library contributes to.
    public var families: [InstrumentCoverage.Family] {
        InstrumentCoverage.Family.allCases.filter { family in
            coverage.contains { $0.family == family }
        }
    }

    /// A digest of everything about this library that the installed bytes
    /// depend on. Stored alongside the install, so a build whose catalog pinned
    /// different assets can tell that what is on disk is not what it describes,
    /// rather than trusting the identifier alone.
    public var pinnedManifestDigest: String {
        var lines: [String] = []
        for asset in assets {
            lines.append(
                [
                    asset.identifier,
                    asset.sourceURL,
                    String(asset.byteCount),
                    asset.digest.algorithm.rawValue,
                    asset.digest.hexValue
                ].joined(separator: "\u{1F}")
            )
        }
        return SHA256Digest.hexString(Data(lines.sorted().joined(separator: "\u{1E}").utf8))
    }
}

// MARK: - Catalog

/// The curated set this build offers.
public enum InstrumentCatalog {
    /// Bumped whenever `libraries` changes in a way that alters installed
    /// bytes. Recorded with every install so a stale install is detectable.
    public static let version = 1

    /// Every curated library, in the order the catalog screen shows them.
    public static let libraries: [CatalogLibrary] = CuratedInstrumentLibraries.all

    /// The libraries the first-run offer proposes: everything not marked
    /// optional.
    public static var defaultSelection: [CatalogLibrary] {
        libraries.filter { !$0.isOptional }
    }

    public static func library(withIdentifier identifier: String) -> CatalogLibrary? {
        libraries.first { $0.identifier == identifier }
    }

    /// Bytes for a complete install of the default selection.
    public static var defaultSelectionByteCount: Int64 {
        defaultSelection.reduce(0) { $0 + $1.downloadByteCount }
    }

    /// Every host this build is allowed to fetch bytes from, lower-cased.
    ///
    /// Derived from the catalog rather than written out, so it cannot drift
    /// from what the catalog actually names. The transport refuses a redirect to
    /// anywhere else: without that, the scheme-and-source scoping REQ-028 turns
    /// on would be enforced only on the first request, and a `302` could stream
    /// hundreds of megabytes from a host nothing in this build ever declared.
    public static func sourceHosts(
        in libraries: [CatalogLibrary] = InstrumentCatalog.libraries
    ) -> Set<String> {
        Set(libraries.flatMap(\.assets).compactMap { $0.httpsURL?.host()?.lowercased() })
    }

    /// The instruments REQ-020 names that this build genuinely cannot supply.
    ///
    /// **Not a placeholder and not a TODO — a stated shortfall.** The catalog
    /// says out loud what it does not have, so the app can say it too rather
    /// than reporting complete coverage over a hole. `InstrumentCatalogTests`
    /// pins this against what the catalog actually covers, so an entry that
    /// stops being true fails the suite.
    public static let knownUncoveredInstruments: [String] = ["harpsichord"]

    /// Every structural rule the catalog data must satisfy.
    ///
    /// A pure function returning problems rather than a set of assertions, so
    /// the test suite can state each rule once and the catalog cannot drift
    /// into an unbuildable shape between releases.
    public static func problems(in libraries: [CatalogLibrary] = InstrumentCatalog.libraries)
        -> [String]
    {
        var problems: [String] = []
        var seenLibraryIDs: Set<String> = []
        var seenCoverageIDs: Set<String> = []

        if libraries.isEmpty {
            problems.append("The catalog is empty.")
        }

        for library in libraries {
            let prefix = "Library \(library.identifier)"

            if !seenLibraryIDs.insert(library.identifier).inserted {
                problems.append("\(prefix): duplicate library identifier.")
            }
            if !isSafePathComponent(library.identifier) {
                problems.append("\(prefix): identifier is not a safe path component.")
            }
            if library.assets.isEmpty {
                problems.append("\(prefix): has no assets, so it can never be installed.")
            }
            if library.coverage.isEmpty {
                problems.append("\(prefix): covers no instruments, so it has nothing to offer.")
            }
            if library.licence.redistribution == .mirrorable,
               library.licence.spdxIdentifier != "CC0-1.0",
               !library.licence.requiresAttribution
            {
                problems.append(
                    "\(prefix): is mirrorable under \(library.licence.spdxIdentifier) but names "
                        + "no attribution, and every licence except CC0 requires one."
                )
            }

            var seenAssetIDs: Set<String> = []
            for asset in library.assets {
                let assetPrefix = "\(prefix) asset \(asset.identifier)"
                if !seenAssetIDs.insert(asset.identifier).inserted {
                    problems.append("\(assetPrefix): duplicate asset identifier.")
                }
                if asset.identifier.isEmpty {
                    problems.append("\(assetPrefix): identifier is empty.")
                }
                if asset.httpsURL == nil {
                    problems.append("\(assetPrefix): \(asset.sourceURL) is not a usable HTTPS URL.")
                }
                if asset.byteCount <= 0 {
                    problems.append("\(assetPrefix): byte count \(asset.byteCount) is not positive.")
                }
                if !isHexadecimal(asset.digest.hexValue, expectedLength: asset.digest.algorithm == .sha256 ? 64 : 40) {
                    problems.append("\(assetPrefix): \(asset.digest.hexValue) is not a well-formed digest.")
                }
                if case .file(let path) = asset.payload, !isSafeRelativePath(path) {
                    problems.append("\(assetPrefix): install path \(path) escapes the library root.")
                }
            }

            let installedPaths = Set(library.assets.compactMap { asset -> String? in
                if case .file(let path) = asset.payload { return path }
                return nil
            })
            let unpacksAnArchive = library.assets.contains { $0.payload.isArchive }

            for instrument in library.coverage {
                let coveragePrefix = "\(prefix) instrument \(instrument.identifier)"
                if !seenCoverageIDs.insert(instrument.identifier).inserted {
                    problems.append("\(coveragePrefix): duplicate instrument identifier.")
                }
                if instrument.dynamicLayerCount < 1 {
                    problems.append("\(coveragePrefix): dynamic layer count must be at least 1.")
                }
                for path in instrument.allSFZPaths {
                    if !isSafeRelativePath(path) {
                        problems.append("\(coveragePrefix): SFZ path \(path) escapes the library root.")
                    }
                    // An archive's members are not enumerable from the manifest,
                    // so this rule only binds libraries whose assets are all
                    // files — which is exactly where a typo would otherwise go
                    // unnoticed until a 2.6 GB download finished.
                    if !unpacksAnArchive, !installedPaths.contains(path) {
                        problems.append(
                            "\(coveragePrefix): SFZ path \(path) is not installed by any asset."
                        )
                    }
                }
            }
        }

        return problems
    }

    /// A single path component with no separators, no traversal and no
    /// surprises.
    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
            && !value.hasPrefix(".")
    }

    /// A relative path that stays inside the library root.
    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    static func isHexadecimal(_ value: String, expectedLength: Int) -> Bool {
        value.count == expectedLength && value.allSatisfy(\.isHexDigit)
            && value.lowercased() == value
    }
}
