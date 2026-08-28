import Foundation

/// Every sentence the instrument catalog speaks.
///
/// Here rather than in the views for the reason `AssignmentDisplay` gives: what
/// the app *says* is behaviour, and behaviour belongs somewhere a test can read
/// it. It also means the VoiceOver label and the visible text are the same
/// string by construction rather than by discipline (REQ-027).
public enum InstrumentCatalogDisplay {
    // MARK: Sizes

    /// A download size the owner can judge before committing to it.
    ///
    /// Decimal units, because that is what every download and every disk is
    /// advertised in, and a catalog that says "2.4 GiB" next to a Finder that
    /// says "2.6 GB" invites the owner to think something is wrong.
    public static func size(_ byteCount: Int64) -> String {
        let clamped = max(0, byteCount)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.isAdaptive = false
        // Pinned units rather than adaptive ones, so a list of libraries is
        // comparable at a glance instead of mixing MB and GB down one column.
        switch clamped {
        case ..<1_000: formatter.allowedUnits = [.useBytes]
        case ..<1_000_000_000: formatter.allowedUnits = [.useMB]
        default: formatter.allowedUnits = [.useGB]
        }
        return formatter.string(fromByteCount: clamped)
    }

    // MARK: State

    /// The one-line status under a library's name.
    public static func status(
        of state: InstrumentLibraryState, in library: CatalogLibrary
    ) -> String {
        switch state {
        case .notDownloaded:
            return "Not downloaded — \(size(library.downloadByteCount))"
        case .partiallyDownloaded(let staged):
            return """
                Paused at \(percentage(staged, of: library.downloadByteCount)) — \
                \(size(staged)) of \(size(library.downloadByteCount)) downloaded
                """
        case .installed(let installed):
            return "Downloaded — \(size(installed.byteCount)), \(instrumentCount(library))"
        case .installedFromAnotherCatalog:
            return """
                Downloaded by an older version of Synth — this version pins \
                different files, so it is worth downloading again
                """
        }
    }

    /// What the button beside a library does right now.
    public static func primaryActionTitle(for state: InstrumentLibraryState) -> String {
        switch state {
        case .notDownloaded: return "Download"
        case .partiallyDownloaded: return "Resume"
        case .installed: return "Remove"
        case .installedFromAnotherCatalog: return "Download Again"
        }
    }

    /// Live progress, spoken as well as shown.
    public static func progress(_ progress: InstrumentDownloadProgress) -> String {
        switch progress.phase {
        case .downloading:
            let done = size(progress.completedByteCount)
            let total = size(progress.totalByteCount)
            if progress.totalAssetCount > 1 {
                return """
                    Downloading — \(done) of \(total), \
                    file \(min(progress.completedAssetCount + 1, progress.totalAssetCount)) \
                    of \(progress.totalAssetCount)
                    """
            }
            return "Downloading — \(done) of \(total)"
        case .verifying:
            return "Checking what arrived is intact…"
        case .unpacking:
            return "Unpacking…"
        case .installing:
            return "Installing…"
        case .finished:
            return "Done"
        }
    }

    public static func percentage(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let fraction = Double(part) / Double(whole)
        return "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: Content

    /// "23 instruments across strings, woodwinds, brass, keyboards, harp and
    /// percussion".
    public static func instrumentCount(_ library: CatalogLibrary) -> String {
        let count = library.coverage.count
        let noun = count == 1 ? "instrument" : "instruments"
        let families = list(library.families.map(\.displayName).map { $0.lowercased() })
        return families.isEmpty ? "\(count) \(noun)" : "\(count) \(noun) across \(families)"
    }

    /// The licence line: what it is, and what the owner owes for it.
    public static func licence(_ library: CatalogLibrary) -> String {
        let terms = library.licence
        if terms.requiresAttribution {
            return "\(terms.name) — you must credit \(library.publisher) wherever you use it."
        }
        return "\(terms.name) — public domain, so nothing is owed for using it anywhere."
    }

    /// The credit to show and to copy, for a library that requires one.
    public static func attribution(_ library: CatalogLibrary) -> String? {
        library.licence.requiresAttribution ? library.licence.requiredAttribution : nil
    }

    /// How honest the catalog is being about one instrument.
    ///
    /// REQ-021's "degrade visibly, never fake" begins here: an instrument with
    /// one sampled dynamic says so, before the owner assigns a crescendo to it
    /// and wonders why it sounds flat.
    public static func qualitySummary(_ instrument: InstrumentCoverage) -> String {
        var parts: [String] = []
        switch instrument.dynamicLayerCount {
        case 1:
            parts.append("One sampled dynamic")
        case let layers:
            parts.append("\(layers) sampled dynamics")
        }
        if !instrument.alternateSFZPaths.isEmpty {
            let count = instrument.alternateSFZPaths.count + 1
            parts.append("\(count) articulations")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Coverage

    /// What the owner can and cannot play, for the catalog's summary line.
    public static func coverageSummary(
        installedFamilies: Set<InstrumentCoverage.Family>
    ) -> String {
        let missing = InstrumentCoverage.Family.allCases.filter { !installedFamilies.contains($0) }
        if installedFamilies.isEmpty {
            return "No instruments are downloaded yet — pieces play through synth sounds only."
        }
        if missing.isEmpty {
            return "Every instrument family is downloaded."
        }
        let names = list(missing.map(\.displayName).map { $0.lowercased() })
        return "Downloaded, apart from \(names). Lines needing those play a synth sound instead."
    }

    // MARK: First-run offer

    public static func firstRunOfferTitle() -> String { "Download the instrument library?" }

    public static func firstRunOfferBody(byteCount: Int64, libraryCount: Int) -> String {
        """
        Synth ships no sampled instruments — \(libraryCount) free, openly \
        licensed libraries are available to download, about \(size(byteCount)) \
        in total. You can skip this: everything else works, and pieces play \
        through synth sounds until you change your mind. The offer stays in \
        the Instruments menu.
        """
    }

    // MARK: Errors

    /// A failure, and whether it is worth pressing Retry.
    public static func failure(_ error: Error) -> (summary: String, recovery: String?, isRetryable: Bool) {
        if let transfer = error as? AssetTransferError {
            return (
                transfer.errorDescription ?? "The download failed.",
                transfer.recoverySuggestion,
                transfer.isRetryable
            )
        }
        if let install = error as? InstrumentInstallError {
            return (
                install.errorDescription ?? "The download could not be installed.",
                install.recoverySuggestion,
                install.isRetryable
            )
        }
        if error is CancellationError {
            return ("The download was paused.", "Press Resume to carry on.", true)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return (
                "There is not enough space on your disk to finish this download.",
                "Free up space and press Retry. Nothing was installed.",
                true
            )
        }
        return (nsError.localizedDescription, nil, true)
    }

    // MARK: Small helpers

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
