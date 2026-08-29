import Foundation

/// Where one referenced instrument actually stands right now.
///
/// **Three ways of not being playable, and the owner is owed the difference.**
/// "Download it" and "this version cannot supply it" are the same fact to the
/// audio engine and completely different facts to the person deciding what to
/// do next, so they are separate cases rather than one `nil` with a message
/// attached.
public enum InstrumentResolution: Sendable, Equatable {
    /// Installed, on disk, ready to load.
    case installed(AvailableInstrument)

    /// This build's catalog has the library; the owner has not downloaded it.
    /// Downloading resolves this.
    case notDownloaded(library: CatalogLibrary, instrument: InstrumentCoverage)

    /// The library is installed but this instrument's SFZ entry point is not on
    /// disk — an interrupted install, or files deleted underneath the app.
    /// Re-downloading resolves this.
    case filesMissing(library: CatalogLibrary, instrument: InstrumentCoverage)

    /// This build's catalog contains no such library or instrument. Downloading
    /// does **not** resolve this: there is nothing to download.
    case notInThisVersion(reference: InstrumentReference)

    public var available: AvailableInstrument? {
        if case .installed(let available) = self { return available }
        return nil
    }

    public var isPlayable: Bool { available != nil }

    /// True when pressing Download in the instrument catalog is the answer.
    public var isFixableByDownloading: Bool {
        switch self {
        case .notDownloaded, .filesMissing: return true
        case .installed, .notInThisVersion: return false
        }
    }

    /// The catalog description, when this build has one.
    public var coverage: InstrumentCoverage? {
        switch self {
        case .installed(let available): return available.coverage
        case .notDownloaded(_, let instrument), .filesMissing(_, let instrument):
            return instrument
        case .notInThisVersion: return nil
        }
    }
}

/// A family REQ-020 names that the owner cannot currently play, and why not.
///
/// **The two reasons are not interchangeable** (INS001's owner ruling on the
/// harpsichord is the live example). One is a download the owner has not made;
/// the other is a shortfall this build cannot fix at any bandwidth. Letting the
/// second wear the first's wording would be the app promising that downloading
/// produces an instrument that does not exist.
public enum InstrumentFamilyGap: Sendable, Equatable {
    /// The catalog covers this family; none of the libraries that do are
    /// installed.
    case notDownloaded(family: InstrumentCoverage.Family, libraries: [CatalogLibrary])

    /// No library in this build's catalog covers the family at all.
    case noOpenlyLicensedSource(family: InstrumentCoverage.Family)

    public var family: InstrumentCoverage.Family {
        switch self {
        case .notDownloaded(let family, _), .noOpenlyLicensedSource(let family):
            return family
        }
    }

    public var isFixableByDownloading: Bool {
        if case .notDownloaded = self { return true }
        return false
    }

    /// One sentence the line list and the catalog can both show.
    public var explanation: String {
        switch self {
        case .notDownloaded(let family, let libraries):
            let names = libraries.map(\.name)
            let source = names.count == 1
                ? "“\(names[0])”"
                : names.map { "“\($0)”" }.joined(separator: " or ")
            return "No \(family.displayName.lowercased()) instrument is downloaded yet. "
                + "Download \(source) from the instrument catalog."
        case .noOpenlyLicensedSource(let family):
            return "This version has no \(family.displayName.lowercased()) instrument from any "
                + "openly licensed source, so downloading will not produce one."
        }
    }
}

// MARK: - Resolving against what is installed

extension InstrumentAssetStore {
    /// Where `reference` stands: installed, downloadable, damaged, or unknown
    /// to this build.
    ///
    /// One filesystem-and-database read, no network — `InstrumentAssetStore` is
    /// offline by construction and this stays inside that guarantee.
    public func resolve(_ reference: InstrumentReference) throws -> InstrumentResolution {
        if let available = try availableInstruments().first(where: {
            $0.libraryID == reference.libraryID
                && $0.coverage.identifier == reference.instrumentID
        }) {
            return .installed(available)
        }

        guard let library = catalogLibraries.first(where: { $0.identifier == reference.libraryID }),
              let coverage = library.coverage.first(where: { $0.identifier == reference.instrumentID })
        else {
            return .notInThisVersion(reference: reference)
        }

        // The database is the authority for "installed" (see `availableInstruments`),
        // so a row with no readable SFZ is a damaged install rather than an
        // absent one — a different sentence and the same fix.
        let isLibraryInstalled = try installedLibrary(withID: library.identifier) != nil
        return isLibraryInstalled
            ? .filesMissing(library: library, instrument: coverage)
            : .notDownloaded(library: library, instrument: coverage)
    }

    /// Every REQ-020 family the owner cannot play, each with the honest reason.
    ///
    /// Built from `familiesWithoutAnInstalledInstrument()` — which reports a
    /// family with nothing installed whatever the cause — by asking the catalog
    /// whether it *could* cover that family at all. INS001 deliberately folded
    /// both cases into one list; this is where they come apart again.
    public func familyGaps() throws -> [InstrumentFamilyGap] {
        try familiesWithoutAnInstalledInstrument().map { family in
            let sources = catalogLibraries.filter { $0.families.contains(family) }
            return sources.isEmpty
                ? .noOpenlyLicensedSource(family: family)
                : .notDownloaded(family: family, libraries: sources)
        }
    }

    /// Every instrument this build's catalog declares, installed or not, in
    /// catalog order.
    ///
    /// The list the customization surface offers to start from: an instrument
    /// the owner has not downloaded is still something they can be shown, told
    /// about, and offered a download for — showing only what is installed would
    /// make an empty catalog screen the only place the absence is visible.
    public func catalogInstruments() -> [(library: CatalogLibrary, instrument: InstrumentCoverage)] {
        catalogLibraries.flatMap { library in
            library.coverage.map { (library, $0) }
        }
    }
}

// MARK: - What the owner has to be told about one line

/// Something true about a line that the owner has to see before they trust
/// what they are hearing (REQ-021's honesty, applied per line).
///
/// **The flag is the product, not a diagnostic.** Issue #24 says a line
/// assigned to a not-downloaded instrument is flagged and substituted only with
/// explicit acknowledgment. Every case below therefore states what is wrong,
/// what the line is doing about it right now, and what would fix it — because a
/// line that is quietly wrong is exactly the state this leaf exists to prevent.
public enum LineInstrumentAdvice: Sendable, Equatable {
    /// The line's instrument is not downloaded. The line is silent until the
    /// owner downloads it or acknowledges a substitute.
    case notDownloaded(instrumentName: String, libraryName: String)

    /// The library is installed but the instrument's files are not on disk.
    case filesMissing(instrumentName: String, libraryName: String)

    /// The line names an instrument this build's catalog does not contain.
    case notInThisVersion(instrumentName: String)

    /// The instrument is installed but could not be loaded — corrupt or
    /// truncated files. INS002 reports the reason; this carries it.
    case unplayable(instrumentName: String, reason: String, recovery: String)

    /// The owner accepted a substitute for a missing instrument, and this is
    /// what is being heard instead.
    case substituted(instrumentName: String, substituteName: String)

    /// The instrument loaded but the render engine could not build a voice for
    /// this line, so the line is producing silence.
    ///
    /// **Carried from INS002 deliberately.** `sample_voice_create` gives a
    /// failed line a vtable that renders silence rather than quietly
    /// substituting a synth patch, because a substitute without the owner's
    /// knowledge is the prohibited end state this leaf gates. Silence without
    /// the owner's knowledge is the same failure by the other route, so it is
    /// flagged here.
    case silentVoice(instrumentName: String, unbuiltVoiceCount: Int)

    /// The score names an instrument no openly licensed source supplies, so the
    /// line is playing the closest thing available. Downloading will not change
    /// this.
    case noOpenlyLicensedSource(scoreInstrumentName: String, playingName: String)

    /// True when downloading a library is what fixes this.
    public var isFixableByDownloading: Bool {
        switch self {
        case .notDownloaded, .filesMissing, .unplayable, .substituted: return true
        case .notInThisVersion, .silentVoice, .noOpenlyLicensedSource: return false
        }
    }

    /// True when this line is currently producing no sound at all.
    public var isSilent: Bool {
        switch self {
        case .notDownloaded, .filesMissing, .notInThisVersion, .unplayable, .silentVoice:
            return true
        case .substituted, .noOpenlyLicensedSource:
            return false
        }
    }

    /// The whole sentence the line list shows and VoiceOver reads.
    public var explanation: String {
        switch self {
        case .notDownloaded(let instrument, let library):
            return "“\(instrument)” is not downloaded, so this line is silent. Download "
                + "“\(library)” from the instrument catalog, or choose a substitute sound to "
                + "hear the line meanwhile."
        case .filesMissing(let instrument, let library):
            return "“\(instrument)” is listed as installed but its files are not on disk, so "
                + "this line is silent. Re-download “\(library)” from the instrument catalog."
        case .notInThisVersion(let instrument):
            return "This line plays “\(instrument)”, which this version of Synth does not "
                + "have. Nothing to download will bring it back; choose another sound for "
                + "this line."
        case .unplayable(let instrument, let reason, let recovery):
            return "“\(instrument)” could not be loaded, so this line is silent. \(reason) "
                + "\(recovery)"
        case .substituted(let instrument, let substitute):
            return "“\(instrument)” is not downloaded. You chose to hear “\(substitute)” on "
                + "this line meanwhile; downloading the instrument puts it back."
        case .silentVoice(let instrument, let count):
            let voices = count == 1 ? "its voice" : "\(count) of its voices"
            return "“\(instrument)” loaded, but Synth could not build \(voices) — this line is "
                + "playing silence rather than some other sound. Close other apps to free "
                + "memory and reopen the piece."
        case .noOpenlyLicensedSource(let scoreName, let playing):
            return "No \(scoreName.lowercased()) is available from any openly licensed source "
                + "yet, so this version cannot offer one. This line plays “\(playing)” instead."
        }
    }

    /// Short label for the badge beside the line's name.
    public var badge: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .filesMissing: return "Files missing"
        case .notInThisVersion: return "Not in this version"
        case .unplayable: return "Could not load"
        case .substituted: return "Substituted"
        case .silentVoice: return "Silent"
        case .noOpenlyLicensedSource: return "No source"
        }
    }
}
