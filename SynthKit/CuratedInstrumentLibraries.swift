import Foundation

/// The curated set this build of Synth offers, pinned to bytes that were
/// fetched and checked on 2026-08-28.
///
/// **Generated data, hand-authored judgement.** The VSCO 2 CE asset list is a
/// mechanical transcription of one immutable git tree — 2539 files,
/// 2574359905 bytes, each pinned to the git blob identifier that commit
/// publishes. The instrument names, families and quality notes below are not:
/// they are the honest description REQ-021 and the plan's "surface
/// per-instrument quality honestly" ask for, and a generator cannot write them.
///
/// ## What was verified, and what it cost
///
/// | Library | Licence | Delivery | Verified |
/// | --- | --- | --- | --- |
/// | VSCO 2 CE | CC0-1.0 | 2539 pinned files at one commit | `206 Partial Content` on `raw.githubusercontent.com`; tree blob sizes match `Content-Range` exactly |
/// | Salamander Grand Piano V3 | CC-BY-3.0 | one `.tar.xz` | `206 Partial Content`, `Content-Length: 412313804`, unchanged since 2016; SHA-256 measured from a full download |
/// | Etherealwinds Harp II CE | CC-BY-4.0 | one `.zip` | `206 Partial Content`, `Content-Length: 214789274`, unchanged since 2023; SHA-256 measured from a full download |
///
/// ## Two sources the plan named that are not here
///
/// * **VCSL** was the plan's harpsichord, organ and extra-percussion source on
///   the understanding that it ships SFZ. At its current head it ships **no
///   `.sfz` file at all** — 4,282 blobs, 4,231 of them raw `.wav`. Its SFZ
///   release exists but carries zero assets, and no maintained third-party
///   mapping set covers it. VSCO 2 CE turns out to cover the organ (four
///   patches) and the extra percussion (timpani, glockenspiel, marimba,
///   xylophone, tubular bells) with real SFZ, so the only thing VCSL uniquely
///   provided was **harpsichord** — which is therefore the one REQ-020
///   instrument this catalog does not cover. That shortfall is escalated to
///   the owner as a product decision rather than papered over with a
///   substitute, which is what the issue's failure behaviour requires.
/// * **Virtual Playing Orchestra 3.3** is excluded. Its wave files are served
///   only through Google Drive, which answers with an HTML interstitial and no
///   `Accept-Ranges` or byte count, so it can satisfy neither resume nor a
///   pinned checksum; and its licence is a mix including CC Sampling Plus 1.0
///   and CC BY-SA, with a Philharmonia component named in the description but
///   absent from the licence table.
enum CuratedInstrumentLibraries {
    static let all: [CatalogLibrary] = [vsco2CommunityEdition, salamanderGrandPiano, etherealwindsHarp]

    // MARK: - VSCO 2 Community Edition

    /// Commit the whole library is pinned to. Everything below is fetched from
    /// `raw.githubusercontent.com` at this SHA, which is byte-stable and
    /// answers range requests — unlike GitHub's generated tag archives, which
    /// are neither and are therefore not used.
    static let vsco2Commit = "28092772094b2d9f1148d84cea97f4545b8c687d"

    static let vsco2CommunityEdition = CatalogLibrary(
        identifier: "vsco2-ce",
        name: "VSCO 2 Community Edition",
        publisher: "Versilian Studios and Sam Gossner",
        summary: """
            The orchestra: strings, woodwinds, brass, timpani and tuned \
            percussion, plus a pipe organ, two upright pianos and a harp. \
            Public domain, so nothing is owed for using it anywhere.
            """,
        licence: InstrumentLicence(
            spdxIdentifier: "CC0-1.0",
            name: "Creative Commons Zero 1.0 Universal (Public Domain Dedication)",
            textURL: "https://creativecommons.org/publicdomain/zero/1.0/",
            requiredAttribution: "",
            redistribution: .mirrorable
        ),
        homepageURL: "https://github.com/sgossner/VSCO-2-CE",
        assets: vsco2Assets,
        coverage: [
                InstrumentCoverage(
                    identifier: "vsco2.violin.solo",
                    name: "Solo violin",
                    family: .strings,
                    sfzPath: "SViolinVib.sfz",
                    alternateSFZPaths: [
                        "SViolin-KS.sfz",
                        "SViolinVib-Quiet.sfz",
                        "SViolinPizz.sfz",
                        "SViolinSpic.sfz",
                        "SViolinTrem.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "Two sustain dynamics (normal and quiet); everything between them is shaped synthetically.",
                        "No true legato — a slur renders as one shaped sustain rather than a joined transition.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.violin.section",
                    name: "Violin section",
                    family: .strings,
                    sfzPath: "ViolinEnsSusVib.sfz",
                    alternateSFZPaths: [
                        "ViolinEns-KS.sfz",
                        "ViolinEnsSusVib-Quiet.sfz",
                        "ViolinEnsPizz.sfz",
                        "ViolinEnsSpic.sfz",
                        "ViolinEnsTrem.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "No true legato — a slur renders as one shaped sustain rather than a joined transition.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.viola.section",
                    name: "Viola section",
                    family: .strings,
                    sfzPath: "ViolaEnsSusVib.sfz",
                    alternateSFZPaths: [
                        "ViolaEns-KS.sfz",
                        "ViolaEnsSusVib-Quiet.sfz",
                        "ViolaEnsPizz.sfz",
                        "ViolaEnsSpic.sfz",
                        "ViolaEnsTrem.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "There is no clean-licence solo viola anywhere in the curated set, so a solo viola line plays this section patch and will sound like more than one player.",
                        "No true legato — a slur renders as one shaped sustain rather than a joined transition.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.cello.section",
                    name: "Cello section",
                    family: .strings,
                    sfzPath: "CelloEnsSusVib.sfz",
                    alternateSFZPaths: [
                        "CelloEns-KS.sfz",
                        "CelloEnsSusVib-Quiet.sfz",
                        "CelloEnsPizz.sfz",
                        "CelloEnsSpic.sfz",
                        "CelloEnsTrem.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "There is no clean-licence solo cello anywhere in the curated set, so a solo cello line plays this section patch and will sound like more than one player.",
                        "No true legato — a slur renders as one shaped sustain rather than a joined transition.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.contrabass",
                    name: "Contrabass",
                    family: .strings,
                    sfzPath: "ContrabassSusVB.sfz",
                    alternateSFZPaths: [
                        "Contrabass-KS.sfz",
                        "ContrabassSusVB-Quiet.sfz",
                        "ContrabassSusNV.sfz",
                        "ContrabassPizz.sfz",
                        "ContrabassSpic.sfz",
                        "ContrabassTrem.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "No true legato — a slur renders as one shaped sustain rather than a joined transition.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.harp",
                    name: "Orchestral harp",
                    family: .harp,
                    sfzPath: "Harp.sfz",
                    dynamicLayerCount: 1,
                    qualityNotes: [
                        "One dynamic layer: how loud a note is plucked is synthetic, not sampled.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.flute",
                    name: "Flute",
                    family: .woodwinds,
                    sfzPath: "FluteSusVib.sfz",
                    alternateSFZPaths: ["Flute-KS.sfz", "FluteSusNV.sfz", "FluteExpVib.sfz", "FluteStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.piccolo",
                    name: "Piccolo",
                    family: .woodwinds,
                    sfzPath: "PiccoloSus.sfz",
                    alternateSFZPaths: ["PiccoloStac.sfz"],
                    dynamicLayerCount: 1,
                    qualityNotes: [
                        "One sustain dynamic: expressive loudness is shaped synthetically.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.oboe",
                    name: "Oboe",
                    family: .woodwinds,
                    sfzPath: "OboeSusVib.sfz",
                    alternateSFZPaths: ["OboeSusNV.sfz", "OboeStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.clarinet",
                    name: "Clarinet",
                    family: .woodwinds,
                    sfzPath: "ClarinetSus.sfz",
                    alternateSFZPaths: ["Clarinet-KS.sfz", "ClarinetStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.bassoon",
                    name: "Bassoon",
                    family: .woodwinds,
                    sfzPath: "BassoonSus.sfz",
                    alternateSFZPaths: ["BassoonVib.sfz", "BassoonStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.trumpet",
                    name: "Trumpet",
                    family: .brass,
                    sfzPath: "TrumpetSus.sfz",
                    alternateSFZPaths: [
                        "TrumpetSusVib.sfz",
                        "TrumpetStac.sfz",
                        "TrumpetHarmonMuteSus.sfz",
                        "TrumpetStraightMuteSus.sfz",
                    ],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.horn",
                    name: "French horn",
                    family: .brass,
                    sfzPath: "FHornSus.sfz",
                    alternateSFZPaths: ["FHornStac.sfz", "FHornMute.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.trombone",
                    name: "Tenor trombone",
                    family: .brass,
                    sfzPath: "TromboneSus.sfz",
                    alternateSFZPaths: ["TromboneVib.sfz", "TromboneStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.tuba",
                    name: "Tuba",
                    family: .brass,
                    sfzPath: "TubaSus.sfz",
                    alternateSFZPaths: ["Tuba-KS.sfz", "TubaStac.sfz"],
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.organ",
                    name: "Pipe organ",
                    family: .keyboards,
                    sfzPath: "OrganLoud.sfz",
                    alternateSFZPaths: ["OrganQuiet.sfz", "OrganLoudPedal.sfz", "OrganQuietPedal.sfz"],
                    dynamicLayerCount: 1,
                    qualityNotes: [
                        "Loud and quiet are separate patches rather than velocity layers, which is how a pipe organ actually behaves — the stops change, the touch does not.",
                        "The pedal division is a separate patch.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.piano.upright",
                    name: "Upright piano",
                    family: .keyboards,
                    sfzPath: "UprightPiano.sfz",
                    alternateSFZPaths: ["VSUpright1.sfz"],
                    dynamicLayerCount: 3,
                    qualityNotes: [
                        "Three dynamic layers. The Salamander grand in this catalog has sixteen and is the better choice for exposed piano writing.",
                    ]
                ),
                InstrumentCoverage(
                    identifier: "vsco2.timpani",
                    name: "Timpani",
                    family: .percussion,
                    sfzPath: "Timpani.sfz",
                    alternateSFZPaths: ["TimpaniRolls.sfz"],
                    dynamicLayerCount: 3,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.glockenspiel",
                    name: "Glockenspiel",
                    family: .percussion,
                    sfzPath: "Glockenspiel.sfz",
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.marimba",
                    name: "Marimba",
                    family: .percussion,
                    sfzPath: "Marimba.sfz",
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.xylophone",
                    name: "Xylophone",
                    family: .percussion,
                    sfzPath: "Xylophone.sfz",
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.tubularbells",
                    name: "Tubular bells",
                    family: .percussion,
                    sfzPath: "TubularBells.sfz",
                    dynamicLayerCount: 2,
                    qualityNotes: []
                ),
                InstrumentCoverage(
                    identifier: "vsco2.percussion.kit",
                    name: "Orchestral percussion kit",
                    family: .percussion,
                    sfzPath: "GM-StylePerc.sfz",
                    dynamicLayerCount: 1,
                    qualityNotes: [
                        "A General MIDI style mapping of snare, bass drum, cymbals, triangle, tambourine and friends across one keyboard, rather than one instrument per line.",
                    ]
                ),
        ]
    )

    // MARK: - Salamander Grand Piano

    static let salamanderGrandPiano = CatalogLibrary(
        identifier: "salamander-grand-v3",
        name: "Salamander Grand Piano V3",
        publisher: "Alexander Holm",
        summary: """
            A Yamaha C5 concert grand in sixteen velocity layers with real \
            release samples — the reference free piano, and by some distance \
            the most finely sampled instrument in this catalog.
            """,
        licence: InstrumentLicence(
            spdxIdentifier: "CC-BY-3.0",
            name: "Creative Commons Attribution 3.0 Unported",
            textURL: "https://creativecommons.org/licenses/by/3.0/",
            requiredAttribution: "Salamander Grand Piano V3 by Alexander Holm, licensed CC BY 3.0.",
            redistribution: .mirrorable
        ),
        homepageURL: "https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html",
        assets: [
            CatalogAsset(
                identifier: "salamander-v3-44k16",
                sourceURL: "https://freepats.zenvoid.org/Piano/SalamanderGrandPiano/SalamanderGrandPianoV3+20161209_44khz16bit.tar.xz",
                byteCount: 412_313_804,
                digest: .sha256("58750eb1366761e187f71ddb9b932355ea894d28ec4331e74ab8acb44c819936"),
                // One wrapper directory, `SalamanderGrandPianoV3_44.1khz16bit/`,
                // which is stripped so the SFZ lands at the library root like
                // every other library's does.
                payload: .tarXZArchive(stripComponents: 1)
            )
        ],
        coverage: [
                InstrumentCoverage(
                    identifier: "salamander.grand",
                    name: "Grand piano",
                    family: .keyboards,
                    sfzPath: "SalamanderGrandPianoV3.sfz",
                    alternateSFZPaths: ["SalamanderGrandPianoV3Retuned.sfz"],
                    dynamicLayerCount: 16,
                    qualityNotes: [
                        "Sixteen velocity layers with real release samples — the most finely sampled instrument in this catalog.",
                        "The retuned variant is the same samples in Young temperament rather than equal temperament.",
                    ]
                ),
        ]
    )

    // MARK: - Etherealwinds Harp II: Community Edition

    static let etherealwindsHarp = CatalogLibrary(
        identifier: "etherealwinds-harp-2-ce",
        name: "Etherealwinds Harp II: Community Edition",
        publisher: "Versilian Studios and Jordi Francis",
        summary: """
            A close-recorded concert harp in two velocity layers with two \
            round robins per note — warmer and more detailed than the harp \
            that comes with VSCO 2.
            """,
        licence: InstrumentLicence(
            spdxIdentifier: "CC-BY-4.0",
            name: "Creative Commons Attribution 4.0 International",
            textURL: "https://creativecommons.org/licenses/by/4.0/",
            // The publisher states the licence but publishes no canonical
            // credit line, so this one is composed from the names it does give:
            // Versilian Studios as the rights holder, Jordi Francis as the
            // performer credited in the bundled manual.
            requiredAttribution: "Etherealwinds Harp II: Community Edition by Versilian Studios LLC and Jordi Francis, licensed CC BY 4.0.",
            redistribution: .mirrorable
        ),
        homepageURL: "https://versilian-studios.com/etherealwinds-harp/",
        assets: [
            CatalogAsset(
                identifier: "ewharp2-ce-sfz-raw",
                sourceURL: "https://versilian-studios.com/Distro/EWHarp2CE_SFZ-Raw.zip",
                byteCount: 214_789_274,
                digest: .sha256("18b78e3c309f5fb6097e1af04482f61a86bab5d9c4d2403f4adfa8bc684af578"),
                payload: .zipArchive(stripComponents: 0)
            )
        ],
        coverage: [
                InstrumentCoverage(
                    identifier: "ewharp.concert",
                    name: "Concert harp",
                    family: .harp,
                    sfzPath: "Harp_Normal.sfz",
                    dynamicLayerCount: 2,
                    qualityNotes: [
                        "Two velocity layers and two round robins.",
                        "Its SFZ writes sample paths with Windows backslashes, so a player has to normalise them.",
                    ]
                ),
        ]
    )

    // MARK: - The pinned VSCO 2 CE file list

    /// Where every VSCO 2 CE file is fetched from: the pinned commit's raw tree.
    static let vsco2RawPrefix = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/\(vsco2Commit)/"

    /// The bundled index's resource name and extension inside SynthKit.
    ///
    /// `VSCO2Index.tsv` holds one line per file:
    /// `<git blob SHA-1>\t<byte count>\t<path>`. The digests are git blob
    /// identifiers taken from the pinned commit's own tree: a file served by
    /// `raw.githubusercontent.com` at a commit **is** that git blob, so the
    /// blob identifier pins exactly the URL's content. The file is shipped app
    /// content, pinned by SHA-256 in `VSCO2IndexResourceTests`; it lives
    /// outside Swift source because 2,539 entries of data slow compiles and
    /// bury the hand-written catalog above.
    static let vsco2IndexResource = (name: "VSCO2Index", extension: "tsv")

    /// `VSCO2Index.tsv`, the resource the pinned file list lives in.
    static var vsco2IndexFileName: String {
        "\(vsco2IndexResource.name).\(vsco2IndexResource.extension)"
    }

    /// Why the bundled VSCO 2 CE index could not be turned into assets.
    enum IndexLoadError: Error, Equatable, CustomStringConvertible {
        /// The bundle has no such resource.
        case missing(resource: String, bundlePath: String)
        /// The resource exists but its bytes could not be read.
        case unreadable(resource: String, reason: String)
        /// The resource is not UTF-8 text.
        case notUTF8(resource: String)
        /// A line is not `<40-hex git blob SHA-1>\t<positive byte count>\t<path>`.
        case corrupt(resource: String, line: Int, reason: String)
        /// The resource parsed but lists no files.
        case empty(resource: String)

        var description: String {
            switch self {
            case let .missing(resource, bundlePath):
                "\(resource) is missing from the bundle at \(bundlePath)."
            case let .unreadable(resource, reason):
                "\(resource) could not be read: \(reason)"
            case let .notUTF8(resource):
                "\(resource) is not UTF-8 text."
            case let .corrupt(resource, line, reason):
                "\(resource) line \(line) is corrupt: \(reason)"
            case let .empty(resource):
                "\(resource) lists no files."
            }
        }
    }

    /// The bundle SynthKit's own resources ship in — the framework, not the
    /// host app, so the index loads the same for the app and for the tests.
    static var frameworkBundle: Bundle { Bundle(for: FrameworkBundleToken.self) }
    private final class FrameworkBundleToken {}

    /// The VSCO 2 CE assets, loaded once from the bundled index.
    ///
    /// A missing or corrupt index is a build defect, not a runtime condition:
    /// an empty or short catalog would offer an incomplete library. So this
    /// site stops with the resource named, and the always-run
    /// `InstrumentCatalogTests` catch it before anything ships.
    static let vsco2Assets: [CatalogAsset] = {
        do {
            return try loadVSCO2Assets(from: frameworkBundle)
        } catch {
            fatalError("SynthKit's VSCO 2 CE index \(vsco2IndexFileName) failed to load: \(error)")
        }
    }()

    /// Reads and strictly validates the bundled index, then builds its assets.
    ///
    /// Unlike `PinnedGitHubAssets.parse`, which skips a malformed line, this
    /// throws on the first one: the resource is pinned content, so any line
    /// that does not parse means the file was damaged.
    static func loadVSCO2Assets(from bundle: Bundle) throws -> [CatalogAsset] {
        let resource = vsco2IndexFileName
        guard let url = bundle.url(
            forResource: vsco2IndexResource.name,
            withExtension: vsco2IndexResource.extension
        ) else {
            throw IndexLoadError.missing(resource: resource, bundlePath: bundle.bundlePath)
        }
        // `FileHandle` rather than a URL-based `Data` read: it cannot
        // leave the filesystem, as `NoNetworkBaselineTests` requires.
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw IndexLoadError.unreadable(resource: resource, reason: error.localizedDescription)
        }
        return try vsco2Assets(fromIndex: data, resource: resource)
    }

    /// Validates index bytes line by line and builds the assets from them.
    static func vsco2Assets(fromIndex data: Data, resource: String) throws -> [CatalogAsset] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw IndexLoadError.notUTF8(resource: resource)
        }
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if line.isEmpty { continue }
            if let reason = problem(inIndexLine: line) {
                throw IndexLoadError.corrupt(resource: resource, line: lineNumber, reason: reason)
            }
        }
        let assets = PinnedGitHubAssets.parse(repositoryRawPrefix: vsco2RawPrefix, index: text)
        guard !assets.isEmpty else { throw IndexLoadError.empty(resource: resource) }
        return assets
    }

    private static func problem(inIndexLine line: Substring) -> String? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return "expected 3 tab-separated fields, found \(fields.count)" }
        let sha = fields[0]
        guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return "the git blob SHA-1 is not 40 lowercase hex digits"
        }
        guard let byteCount = Int64(fields[1]), byteCount > 0 else {
            return "the byte count is not a positive integer"
        }
        // Scalars, not Characters: Swift reads "\r\n" as one Character, so a
        // CRLF-converted file would otherwise hide every later line in the
        // first line's path.
        guard !fields[2].isEmpty,
              !fields[2].unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\t" })
        else {
            return "the path is empty or carries a tab or line break"
        }
        return nil
    }
}
