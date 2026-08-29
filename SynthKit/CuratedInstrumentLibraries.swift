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
        assets: PinnedGitHubAssets.parse(
            repositoryRawPrefix: "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/28092772094b2d9f1148d84cea97f4545b8c687d/",
            index: vsco2Index
        ),
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

    /// One line per file: `<git blob SHA-1>\t<byte count>\t<path>`.
    ///
    /// A string rather than 2539 `CatalogAsset` literals because Swift
    /// type-checks a large array literal element by element and a source file
    /// of that shape takes minutes to compile, while a string literal of the
    /// same information takes none. It is still compiled-in app content: the
    /// bytes below ship in the binary and nothing at runtime can change them.
    ///
    /// The digests are git blob identifiers, taken from the pinned commit's own
    /// tree. That is not a convenience: a file served by
    /// `raw.githubusercontent.com` at a commit **is** that git blob, so the
    /// blob identifier is exactly the thing that pins the URL's content, and it
    /// comes from the source rather than from us having measured it once.
    static let vsco2Index = #"""
63ae2edbbb93de31199dbddbdd6618b8e0b0ae22	5192	BassoonStac.sfz
84e2030f33b8631d4489e05afbe020508a51dbd1	2796	BassoonSus.sfz
282d04530cebd5643a5e97742d1a30fe104344d2	2378	BassoonVib.sfz
15bf6eaf150f8c82cceb900bf6d5c0620739f55c	990284	Brass/F Horn/mute/MOHorn_mute_A#1_v1_1.wav
9bed2009ef1ad61bb047ffff007e9674e5bb5c2b	831072	Brass/F Horn/mute/MOHorn_mute_A#1_v2_1.wav
9f16addd8f3895c1253c8032f8f2e21f70370b23	1709220	Brass/F Horn/mute/MOHorn_mute_A#3_v1_1.wav
b9902d63efe083c06a8ad85ca7b95eba9ddca138	808200	Brass/F Horn/mute/MOHorn_mute_A#3_v2_1.wav
9d1099482cc16eeb718861c5c16a1af4ac549164	1820248	Brass/F Horn/mute/MOHorn_mute_C3_v1_1.wav
b1f101c95251d1ee49d406b42f1fcbbf135be5e9	820440	Brass/F Horn/mute/MOHorn_mute_C3_v2_1.wav
984a9d3b61715344d1118d2a9866f548c7aaad14	809116	Brass/F Horn/mute/MOHorn_mute_C3_v3_1.wav
adc23b39fcaa0e3c14ce0a72dc0aac0d698bf717	1346584	Brass/F Horn/mute/MOHorn_mute_D#2_v1_1.wav
180bcb12dd3a0a91ba48f4debedac07ffa8337c4	840692	Brass/F Horn/mute/MOHorn_mute_D#2_v2_1.wav
00e567776c4d4c10ca14283c6df3e9296db1a284	2962804	Brass/F Horn/mute/MOHorn_mute_D#3_v1_1.wav
a4bd7adecfe74e1661970832258d5c5b057c9d26	908184	Brass/F Horn/mute/MOHorn_mute_D#3_v2_1.wav
30214f0dc1d1e8577b05fd6161de79cd448657b2	707860	Brass/F Horn/mute/MOHorn_mute_D4_v1_1.wav
a99603eb8d6dd98dc46621d860268522c733a5af	1460260	Brass/F Horn/mute/MOHorn_mute_F2_v1_1.wav
98069bd0f4e11c92fcf60111a5241bec80ea15a5	965224	Brass/F Horn/mute/MOHorn_mute_F2_v2_1.wav
e0266dd22c5d6bc387ac2c736f4747cb341e1a01	752628	Brass/F Horn/mute/MOHorn_mute_F4_v1_1.wav
2402993d5b6164b06f6b7867efc44664bd270d5c	1581168	Brass/F Horn/mute/MOHorn_mute_G#3_v1_1.wav
db7e653fe45dff1de4c95a6e6775254d616a61ee	966276	Brass/F Horn/mute/MOHorn_mute_G#3_v2_1.wav
0ad23ac3fb888d58998c243366d8bc6a6a6ab945	224480	Brass/F Horn/stac/MOHorn_stac_A#1_v1_rr1.wav
4695bb104ac11fe68c4a104860496977394eb64a	170144	Brass/F Horn/stac/MOHorn_stac_A#1_v2_rr1.wav
5505a18af7635f4e77f5f884dc39f90177cb9b6a	200052	Brass/F Horn/stac/MOHorn_stac_A#1_v2_rr2.wav
4eecb34737af98b755d811073800cdc2d3f5e614	259404	Brass/F Horn/stac/MOHorn_stac_A#1_v3_rr1.wav
a870bfb0261f586982d44676c47126bfb98b883d	203944	Brass/F Horn/stac/MOHorn_stac_A#1_v3_rr2.wav
21cdbc65e41581f2f056d7843a9051046454c2b9	243804	Brass/F Horn/stac/MOHorn_stac_A0_v1_rr1.wav
aae88ff21fcb891fed3ffce10c327042b3ebe09d	295924	Brass/F Horn/stac/MOHorn_stac_A0_v1_rr2.wav
0d38b7c363d9e738c102ea45b6fe17467331578e	318380	Brass/F Horn/stac/MOHorn_stac_A2_v1_rr1.wav
13138976e958f01bf919bcd31208116775beeda0	295352	Brass/F Horn/stac/MOHorn_stac_A2_v1_rr2.wav
6a8e9210be8110d882d8802b6220a5fabc700f14	258348	Brass/F Horn/stac/MOHorn_stac_A2_v2_rr1.wav
b23c4741a106b8d7316516b2db6c4c976e44374b	397316	Brass/F Horn/stac/MOHorn_stac_A2_v2_rr2.wav
81272129a1b36a49bf14cb044944cba081923699	275300	Brass/F Horn/stac/MOHorn_stac_A2_v3_rr1.wav
8dc8428dc7a7e3da2ab0dfbd0579140275561504	333348	Brass/F Horn/stac/MOHorn_stac_A2_v3_rr2.wav
8be34036567895ad596631913b481a044afe5228	217668	Brass/F Horn/stac/MOHorn_stac_C1_v1_rr1.wav
74754adfb070dc97b81237cf2df725cca8eee845	236328	Brass/F Horn/stac/MOHorn_stac_C1_v1_rr2.wav
67abd61db24af51a4d9e662f1377098b7be16d20	217880	Brass/F Horn/stac/MOHorn_stac_C1_v2_rr1.wav
ea9f7e517d0adcb0160c3a7fe1dd1a999ea23e6d	226988	Brass/F Horn/stac/MOHorn_stac_C1_v2_rr2.wav
e9852c8758d48a52867de600c0e7575bb09c5d50	311768	Brass/F Horn/stac/MOHorn_stac_C3_v1_rr1.wav
d8423035c775845a17bb2d191c7c52e39ec53458	270908	Brass/F Horn/stac/MOHorn_stac_C3_v1_rr2.wav
674eb871334956e97c2fbbe0954bb412f9fac62b	116584	Brass/F Horn/stac/MOHorn_stac_C3_v2_rr1.wav
e4915198b7c7fa377c7a53b730ca16ef9d6a07ea	185020	Brass/F Horn/stac/MOHorn_stac_C3_v2_rr2.wav
e7974939bf27e3b7c6bc7b79340f1a251d8ad869	280932	Brass/F Horn/stac/MOHorn_stac_C3_v3_rr1.wav
f7c9a73161cf5096507c550f87f04afd491bee98	293568	Brass/F Horn/stac/MOHorn_stac_C3_v3_rr2.wav
fabbe689f05387f0862de2f2db1c3d9f7929e2dc	224960	Brass/F Horn/stac/MOHorn_stac_D#1_v1_rr1.wav
70e9bc1c6aea8894e48564823f248f25f2053bf2	200716	Brass/F Horn/stac/MOHorn_stac_D#1_v1_rr2.wav
80f44b6df8dbf2eb92e9ee88f3f1173a3f3dafd6	231760	Brass/F Horn/stac/MOHorn_stac_D#1_v2_rr1.wav
69d02d36f92ed2ffb2938561c1066f57041ee41f	262668	Brass/F Horn/stac/MOHorn_stac_D#1_v2_rr2.wav
05a4dc149ca7f958a98caed1343f2bce2dbcefa9	198688	Brass/F Horn/stac/MOHorn_stac_D2_v1_rr1.wav
eaed62522cec5b188bee039b4fa2b18c7b636297	214420	Brass/F Horn/stac/MOHorn_stac_D2_v1_rr2.wav
d6a5165f419819413bf907b65c2bec795ba864db	227660	Brass/F Horn/stac/MOHorn_stac_D2_v2_rr1.wav
ebb78e98cacebf05e2016b9a244ce0f4481a9621	284172	Brass/F Horn/stac/MOHorn_stac_D2_v2_rr2.wav
f86313efe12277b893333660a562a1f3d4ef0afc	141252	Brass/F Horn/stac/MOHorn_stac_D2_v3_rr1.wav
c713805a6c02679c4f141de8971dfce8afa51d74	294828	Brass/F Horn/stac/MOHorn_stac_D2_v3_rr2.wav
e6104e3514a59841d25c519a22305f021d750e64	261348	Brass/F Horn/stac/MOHorn_stac_D4_v1_rr1.wav
70d735e5b6dbff7ff8217e16e89402a5f325d43d	254328	Brass/F Horn/stac/MOHorn_stac_D4_v1_rr2.wav
a06da55ae32393863f62ec4e26c2703f210a1017	258364	Brass/F Horn/stac/MOHorn_stac_D4_v2_rr1.wav
28bf3a642d65cd12246f0745f3415092ede96a09	299504	Brass/F Horn/stac/MOHorn_stac_D4_v2_rr2.wav
a7d84979e0f58e5a6ebcf0f6620e50064aef232c	206752	Brass/F Horn/stac/MOHorn_stac_D4_v3_rr1.wav
5e86bad3c152fbe75bebcf52d82f54f482292da6	256428	Brass/F Horn/stac/MOHorn_stac_D4_v3_rr2.wav
a3a28ef5bbf2f6698e28b9f264c37a7f7852e876	301428	Brass/F Horn/stac/MOHorn_stac_F2_v1_rr1.wav
36ea670efec820a74036244c830dd6a1717e6dbc	185692	Brass/F Horn/stac/MOHorn_stac_F2_v1_rr2.wav
6d312fa649c6bb8bed53fd9d5b5d8f4d0e7c03b1	203892	Brass/F Horn/stac/MOHorn_stac_F2_v2_rr1.wav
0cbed0b3f735964ccd62352e0329d280d095c1e3	271464	Brass/F Horn/stac/MOHorn_stac_F2_v2_rr2.wav
be315404c5fafc92dd9a064607db00c488f369e4	302936	Brass/F Horn/stac/MOHorn_stac_F2_v3_rr1.wav
1fe4faa5848826fd908cadf9aad81bad090a5e18	220860	Brass/F Horn/stac/MOHorn_stac_F2_v3_rr2.wav
0dbd4dd983ad393e1b8870eef3db68edde128c41	258680	Brass/F Horn/stac/MOHorn_stac_F4_v1_rr1.wav
58139112fa3ce20a7e5d872048f329ccbc4c74a6	275956	Brass/F Horn/stac/MOHorn_stac_F4_v1_rr2.wav
dddbe9bbccc37615ad633ffb0d0bbf51275b2c0b	155352	Brass/F Horn/stac/MOHorn_stac_F4_v2_rr1.wav
0c6534363ae031ddca9fee5d01cf989d2b8ec1b2	285776	Brass/F Horn/stac/MOHorn_stac_F4_v2_rr2.wav
79ef903028b1ace619f9ae03153428ad5da841b2	176088	Brass/F Horn/stac/MOHorn_stac_F4_v3_rr1.wav
5133c5597d11973de6c740360166d03002c5228b	248164	Brass/F Horn/stac/MOHorn_stac_G1_v1_rr1.wav
4d376c4bc9fb36d008b14011dbce69580aff1887	266484	Brass/F Horn/stac/MOHorn_stac_G1_v1_rr2.wav
d9056fbcb1723f83a646e2686027d64190928b06	203244	Brass/F Horn/stac/MOHorn_stac_G1_v2_rr1.wav
5f69b52371a079189e097644b839e295b5b860b1	185444	Brass/F Horn/stac/MOHorn_stac_G1_v2_rr2.wav
573db456092f7eff6af7245819f162828f749e10	2417592	Brass/F Horn/sus/MOHorn_sus_A#1_v1_1.wav
62c15504278f9c2dfaa0006530d34a5a3d92ecb0	2740036	Brass/F Horn/sus/MOHorn_sus_A#1_v2_1.wav
8fe919bf02a81284083f9a356db56591ffbb5e31	1829064	Brass/F Horn/sus/MOHorn_sus_A#1_v3_1.wav
bec79afe2bde69ed445c52da977b83e31cc81ed7	947196	Brass/F Horn/sus/MOHorn_sus_A0_v1_1.wav
d358aadfb3bb1e0f28ab742d96f5418dc750057b	2672192	Brass/F Horn/sus/MOHorn_sus_A2_v1_1.wav
5ea35c7b0bf50d85195ba726380e611817f4ba9a	2542000	Brass/F Horn/sus/MOHorn_sus_A2_v2_1.wav
d4088d29905d60944c524d443f66c55035301e47	1305440	Brass/F Horn/sus/MOHorn_sus_A2_v3_1.wav
eed8f32ab91afd3381e42d0a5d0ad1d2beccbd11	1093856	Brass/F Horn/sus/MOHorn_sus_C1_v1_1.wav
48ea1921e88607d0aea8aece16be6bc2456f6a4e	807756	Brass/F Horn/sus/MOHorn_sus_C1_v2_1.wav
3503c90afff58abd64db51f24e7f0ffc02954e3d	704216	Brass/F Horn/sus/MOHorn_sus_C1_v3_1.wav
e53d2d03f0902c9f3a6add7c6bf51122bcc7d573	2519448	Brass/F Horn/sus/MOHorn_sus_C3_v1_1.wav
9f89dc248404a1a1e0240035ac5fa55c89e9c9cd	2240888	Brass/F Horn/sus/MOHorn_sus_C3_v2_1.wav
69e3187ccc4d4338931d412a9f50978ca576db5c	2114316	Brass/F Horn/sus/MOHorn_sus_C3_v3_1.wav
98bc7d3d4709c8d7a240a1f39c615bef3af7e5b0	1761688	Brass/F Horn/sus/MOHorn_sus_C3_v4_1.wav
238de6f129810744e89a22c414daf926e1b55a37	1425196	Brass/F Horn/sus/MOHorn_sus_D#1_v1_1.wav
20c33d3ffb3bf369e30359e3eb8b8ac7548adda3	970468	Brass/F Horn/sus/MOHorn_sus_D#1_v2_1.wav
db97debcf24dfa898ce069d9b21b5bbea371e552	927292	Brass/F Horn/sus/MOHorn_sus_D#1_v3_1.wav
e63cadc76d2b3e56ee26ad558e52fd633cc8c4b1	2500360	Brass/F Horn/sus/MOHorn_sus_D2_v1_1.wav
665f09cf0fe70efdcec1d93b064d5a5a32d6ebe0	2583372	Brass/F Horn/sus/MOHorn_sus_D2_v2_1.wav
aec5cfdb8e2532338f69f6726c77c1d8e5044f0d	1746204	Brass/F Horn/sus/MOHorn_sus_D2_v3_1.wav
e61e2d828400580fd267e5af934eee65e62d21b7	1166236	Brass/F Horn/sus/MOHorn_sus_D2_v4_1.wav
0d13acd769ecdfc234c416fe859a4eda9aac2f22	1445100	Brass/F Horn/sus/MOHorn_sus_D4_v1_1.wav
90c68f7833a7aa2325dea7159aad8af4c9b13a76	2163124	Brass/F Horn/sus/MOHorn_sus_F2_v1_1.wav
37655b24ac23b96a47a6bb75c091bedef6913632	2558276	Brass/F Horn/sus/MOHorn_sus_F2_v2_1.wav
af9345753c5b31083a3e344dd7bbf6c978de59c3	1692688	Brass/F Horn/sus/MOHorn_sus_F2_v3_1.wav
3061198e82995900230e9ddde1138a076d8dca9f	1477536	Brass/F Horn/sus/MOHorn_sus_F4_v1_1.wav
587133d2ed466473bd29438555973d9e75c3285a	2038728	Brass/F Horn/sus/MOHorn_sus_G1_v1_1.wav
e09ff9550c6ed4b660baeaba5497040ca7add35e	1300556	Brass/F Horn/sus/MOHorn_sus_G1_v2_1.wav
e824ccfe9f9b0a33e31151cec90e838dc769d949	941656	Brass/F Horn/sus/MOHorn_sus_G1_v3_1.wav
97cb62a68dae1f05ac29eb2d45766eefe1f5ea5b	750830	Brass/OldTrombone/Buzz/Trombone_Buzz_A#1_v1_1.wav
5ca18d6bf0d2ae817316b1ceb7baed2a4b5f114a	998636	Brass/OldTrombone/Buzz/Trombone_Buzz_A#1_v1_2.wav
2639be78f8d07c7355614f8b6ec5a4924613f35e	752594	Brass/OldTrombone/Buzz/Trombone_Buzz_A#1_v2_1.wav
3f0498c08187ca2cfeadd6809011f4e4c4bc10ae	883736	Brass/OldTrombone/Buzz/Trombone_Buzz_A#2_v1_1.wav
8b86b5b85bea57c1257860b813db704d96b49b06	483518	Brass/OldTrombone/Buzz/Trombone_Buzz_A#2_v2_1.wav
341bfe7828c384656954b4511e6323c4e5e56b14	829826	Brass/OldTrombone/Buzz/Trombone_Buzz_A1_v1_1.wav
df2d2f86aafbbe362ea86dc329a2ee0d244cd0b2	544226	Brass/OldTrombone/Buzz/Trombone_Buzz_A1_v2_1.wav
c25d4e079dbecbccdb590ef114aa471d4565f7f8	906608	Brass/OldTrombone/Buzz/Trombone_Buzz_A2_v1_1.wav
23ade9e7f1f0583f45181a38c41f561d7c6a85ad	543050	Brass/OldTrombone/Buzz/Trombone_Buzz_A2_v2_1.wav
e48570076faee97c7696e7082cdc364204521152	984704	Brass/OldTrombone/Buzz/Trombone_Buzz_C2_v1_1.wav
b7efa93d9fb5c19465a0e1ac8fe89e66224dc300	735764	Brass/OldTrombone/Buzz/Trombone_Buzz_C2_v2_1.wav
c5ce0bbeb5644d4bd859bbef393328f81ac44129	527540	Brass/OldTrombone/Buzz/Trombone_Buzz_C3_v2_1.wav
3f1c56d765ae92154403951cfd34daef18010fb4	855650	Brass/OldTrombone/Buzz/Trombone_Buzz_D#2_v1_1.wav
0458595ce37ff0a053cb90c0922679782bbc2c18	692474	Brass/OldTrombone/Buzz/Trombone_Buzz_D#2_v2_1.wav
46360ce2a9e611527d6467b8d0880016ce4d7c99	919010	Brass/OldTrombone/Buzz/Trombone_Buzz_D2_v1_1.wav
dc0889d2642ecbebda060094dd9503aba8874e4f	612800	Brass/OldTrombone/Buzz/Trombone_Buzz_D2_v2_1.wav
5c4e01c2fdee1d589f0dfe2cfc32e42f9d823ea3	520934	Brass/OldTrombone/Buzz/Trombone_Buzz_D3_v2_1.wav
a6881ad8726988115362a02ac8aaa063bd6ceb8d	1071740	Brass/OldTrombone/Buzz/Trombone_Buzz_F1_v1_1.wav
4ce910231c3545112fff60bf4724ae7a34b31ded	762518	Brass/OldTrombone/Buzz/Trombone_Buzz_F1_v2_1.wav
5f08cc0207012621bf2c194105fed50656e38cf3	989258	Brass/OldTrombone/Buzz/Trombone_Buzz_F2_v1_1.wav
f2f3c064b864bdafdcd4e6818ff672241eb8d510	775082	Brass/OldTrombone/Buzz/Trombone_Buzz_F2_v2_1.wav
2681d8fb86246c1cead2fc184bc6bdff9bcbdb2d	830894	Brass/OldTrombone/Buzz/Trombone_Buzz_G1_v1_1.wav
a365481bd7e82b3a03b00bdc53c417ed343b1d51	572690	Brass/OldTrombone/Buzz/Trombone_Buzz_G1_v2_1.wav
e8726323e4f34c8c4a6bf6295ac7d2ab2783b054	882890	Brass/OldTrombone/Buzz/Trombone_Buzz_G2_v1_1.wav
5c3ab87f244e0b351b5379b92edc555ae51041f7	591530	Brass/OldTrombone/Buzz/Trombone_Buzz_G2_v2_1.wav
b7b75ce7dd692d8f86c84500d24dd8918ce0debe	235940	Brass/OldTrombone/Fall/Trombone_Fall_A#1_1.wav
a928263a0b323ad0ecf228ea4fc237b313b9ed3b	215036	Brass/OldTrombone/Fall/Trombone_Fall_A#2_1.wav
f533ae40467e3d6014e8d901477f22e837ab4873	215300	Brass/OldTrombone/Fall/Trombone_Fall_A#2_2.wav
83605fd3c3cf35ffac0cd1abeef43635e0dbe4a9	234374	Brass/OldTrombone/Fall/Trombone_Fall_A1_1.wav
9eec4a5f7a7a3a94b5ac4dfa668fb56f82cdd3fb	238214	Brass/OldTrombone/Fall/Trombone_Fall_A2_1.wav
642ca5410d1b4bbf3ed308a77218e55d75480383	257792	Brass/OldTrombone/Fall/Trombone_Fall_B2_1.wav
74476ab26f4dff886aacf449b3fd48ec381b3713	209678	Brass/OldTrombone/Fall/Trombone_Fall_C#2_1.wav
0dc195421c683fc3c72611a44767517ca595a2be	252452	Brass/OldTrombone/Fall/Trombone_Fall_C#2_2.wav
2bd1a2a8c44523ee3abe7d3ae329247f6eb2034f	223274	Brass/OldTrombone/Fall/Trombone_Fall_C2_1.wav
28e83d28fdbfe02310a0064261eb20f8aa8992aa	212114	Brass/OldTrombone/Fall/Trombone_Fall_D#2_1.wav
ca24b6ae8055581cb0d088fa6285950197d95e26	295460	Brass/OldTrombone/Fall/Trombone_Fall_D#2_2.wav
cbffa45ebcdb352afcf40ecf879836c2a221d89f	209198	Brass/OldTrombone/Fall/Trombone_Fall_D2_1.wav
fe48a949ea60317f38e66a096d47054415437051	249302	Brass/OldTrombone/Fall/Trombone_Fall_D2_2.wav
36f1d65df7b990a1db442b6d8141e90c5cb1da2b	217754	Brass/OldTrombone/Fall/Trombone_Fall_D2_3.wav
9cbc292a85b7af121e4042ce3a0150bc4fb20b52	219722	Brass/OldTrombone/Fall/Trombone_Fall_E2_1.wav
7bf801c644b2a01634cd161e391a1924f73c9d2d	278162	Brass/OldTrombone/Fall/Trombone_Fall_E2_2.wav
6ba1cc1ba4eb0eba5736ead56b62edaa74d09349	235310	Brass/OldTrombone/Fall/Trombone_Fall_F2_1.wav
5f72266eef793c2e606332afd9d8d8b568a59720	277514	Brass/OldTrombone/Fall/Trombone_Fall_F2_2.wav
db5d7d98d096b281df44b232df0abf914b8ca351	212636	Brass/OldTrombone/Fall/Trombone_Fall_G#1_1.wav
3645edc1a7e84c6e4a888df15804b488865a4f6c	238772	Brass/OldTrombone/Fall/Trombone_Fall_G#2_1.wav
c241d2a669437248c793ec99733b0045fb0e7f8b	205028	Brass/OldTrombone/Fall/Trombone_Fall_G1_1.wav
6cd4c393e831c2970947581fd8d02b2b1eeece3b	237116	Brass/OldTrombone/Fall/Trombone_Fall_G2_1.wav
7b21c953dd5d4557204fa05337e9eb2d3570362e	122	Brass/OldTrombone/Notes.txt
d37b5c1a9d0c3ce97a5a0c7bd50586efc927a40a	150572	Brass/OldTrombone/Short/Trombone_Short_A#1_v1_1.wav
9ecfd4f80bf8c0f2e5fcb7018dc910b9a540accd	157778	Brass/OldTrombone/Short/Trombone_Short_A#1_v1_2.wav
7414f30c84793cb8d6c8f349ca82d1a6a5958844	138284	Brass/OldTrombone/Short/Trombone_Short_A#1_v1_3.wav
fa679dcb99d0341dff01b0dfcb169bbb69cfc97b	143942	Brass/OldTrombone/Short/Trombone_Short_A#1_v1_4.wav
cdd1c61bbae5c5744d9061a8a10a9c7356d4e02d	138284	Brass/OldTrombone/Short/Trombone_Short_A#1_v2_1.wav
23d87eadeb9c3fe1c0b5ab24a3d038c369da9bf5	212012	Brass/OldTrombone/Short/Trombone_Short_A#1_v2_2.wav
a400f1073bcaba0569ce76482f9da6ba1ef2f8ea	169004	Brass/OldTrombone/Short/Trombone_Short_A#1_v2_3.wav
5a8e610bc23380b105863ccfa58650891d481895	308618	Brass/OldTrombone/Short/Trombone_Short_A#1_v2_4.wav
a36bfa7134470675762063730c656fa9dd095db3	163658	Brass/OldTrombone/Short/Trombone_Short_A#1_v2_5.wav
96c68a0a73320d80e19dae47ad1b1fa1ad7c86ae	133328	Brass/OldTrombone/Short/Trombone_Short_A#1_v3_1.wav
0e9e6b3f7682513a6d24a459b6b6578a6a06ee88	259490	Brass/OldTrombone/Short/Trombone_Short_A#1_v3_2.wav
d25fcd80f61e6c38fccb54d1c8d1daecd9d9d8c5	288980	Brass/OldTrombone/Short/Trombone_Short_A#1_v3_3.wav
316b04480bacd3e5f0250b7f03f49e8f576c923c	208940	Brass/OldTrombone/Short/Trombone_Short_A#1_v3_4.wav
78590bd0bc0d8500140a15d8b9511f0e24523f8c	304172	Brass/OldTrombone/Short/Trombone_Short_A#1_v3_5.wav
4270aaaff19a76c2b8bed43bf969952afc657282	181292	Brass/OldTrombone/Short/Trombone_Short_A#2_v1_1.wav
afe24b217ab7c783f722d3d7a885bda46c1b225c	193034	Brass/OldTrombone/Short/Trombone_Short_A#2_v1_2.wav
72ea1eda227806b1d8c24c88587dd76a6fe737fb	215084	Brass/OldTrombone/Short/Trombone_Short_A#2_v1_3.wav
9237d3f8853e0e65bc46b23ac62bd62dbd3bba05	215084	Brass/OldTrombone/Short/Trombone_Short_A#2_v1_4.wav
50d66851d0f3f20e1d595cd7036cd6920cf44554	291884	Brass/OldTrombone/Short/Trombone_Short_A#2_v2_1.wav
c1c436abeaf47e8e0182af22f949cdf482ce23c4	222014	Brass/OldTrombone/Short/Trombone_Short_A#2_v2_2.wav
18dc859f52672abc0b5c56d48a38890654925f9c	232718	Brass/OldTrombone/Short/Trombone_Short_A#2_v2_3.wav
686514c32ddc68d31621f7fc67ce7865233cbb7a	289424	Brass/OldTrombone/Short/Trombone_Short_A#2_v2_4.wav
c0d6ed6681a7d4a30e90147e73cf89adbed05d6a	113228	Brass/OldTrombone/Short/Trombone_Short_A#2_v3_1.wav
6cb1297539f6ff15d918faf077bb1dec9915cc41	134942	Brass/OldTrombone/Short/Trombone_Short_A#2_v3_2.wav
d8f76876ed3bcc1eb63f9c2eaae220c62c04ada7	103034	Brass/OldTrombone/Short/Trombone_Short_A#2_v3_3.wav
e5c2c2a52768943f5c03a936e969ef42bd9b68ac	102728	Brass/OldTrombone/Short/Trombone_Short_A#2_v3_4.wav
1cb62fcf5b01d73fc1dc8aebb0de1e9bc1e88caf	159788	Brass/OldTrombone/Short/Trombone_Short_A1_v1_1.wav
fa93555b42e51e38a45e8e9db2d07ba4a12b1a13	187436	Brass/OldTrombone/Short/Trombone_Short_A1_v1_2.wav
d4f1980a5bebc99f3b5611c49044a4b7383b1248	156716	Brass/OldTrombone/Short/Trombone_Short_A1_v1_3.wav
eafdb0b307347059f6b307e20e67f17b00b47d63	172076	Brass/OldTrombone/Short/Trombone_Short_A1_v1_4.wav
6723b6baa2b100fd30685c449902000bb32161a6	202796	Brass/OldTrombone/Short/Trombone_Short_A1_v2_1.wav
bf30f9cd4791c0174f392e1e4a7c9b33ce979ad6	233516	Brass/OldTrombone/Short/Trombone_Short_A1_v2_2.wav
dca39b82427cdf384c4029ae9963c115f29b1756	245642	Brass/OldTrombone/Short/Trombone_Short_A1_v2_3.wav
d5144b7aeb9509c6705a298d29ab4765faf7b6fd	269690	Brass/OldTrombone/Short/Trombone_Short_A1_v2_4.wav
5829dbec06e1db01eec43e96fafa4c0efba62052	234740	Brass/OldTrombone/Short/Trombone_Short_A1_v3_1.wav
9bd2a568950b27847972a968f4956b3a714c7c31	221228	Brass/OldTrombone/Short/Trombone_Short_A1_v3_2.wav
346deaa99724d3af3224be9e02e3b25e66dfcf37	217112	Brass/OldTrombone/Short/Trombone_Short_A1_v3_3.wav
ba9c9566a65db4db5d261dab7476e4d0d5741b5f	269546	Brass/OldTrombone/Short/Trombone_Short_A1_v3_4.wav
d8569ebc444892ed174f4da248edc29f57174c46	205784	Brass/OldTrombone/Short/Trombone_Short_A2_v1_1.wav
a734b5bd5e6ebdf4e556f21a7dceb5e6c1a0d2e8	181292	Brass/OldTrombone/Short/Trombone_Short_A2_v1_2.wav
c9c9024e7263f1ffff83870ba875ee90fa12bda3	181160	Brass/OldTrombone/Short/Trombone_Short_A2_v1_3.wav
5079dff655e9123a18d9367d84847e19ba905ea6	222950	Brass/OldTrombone/Short/Trombone_Short_A2_v1_4.wav
6422fc7b99ca68614292f2cb0ace85713a809f75	264236	Brass/OldTrombone/Short/Trombone_Short_A2_v2_1.wav
82321c96fba5490d631ec5841651b80ba3c43381	228614	Brass/OldTrombone/Short/Trombone_Short_A2_v2_2.wav
b2c8e0815d35539a6462ddbb4422f4f8aacc8ee4	239660	Brass/OldTrombone/Short/Trombone_Short_A2_v2_3.wav
1f7f238ceab5d003a018c01dd0c47615bdb4449f	291884	Brass/OldTrombone/Short/Trombone_Short_A2_v2_4.wav
3a21ccb12ec8546f738e2a8cc78b6df46a92433f	285740	Brass/OldTrombone/Short/Trombone_Short_A2_v3_1.wav
ec54373723afc98d887c61e78809ebb098302173	251660	Brass/OldTrombone/Short/Trombone_Short_A2_v3_2.wav
7631686e72a822e64b4747760b39f0a50e0c2754	282668	Brass/OldTrombone/Short/Trombone_Short_A2_v3_3.wav
0be60b713c076070a04982e7e2a308ca25f7f340	156716	Brass/OldTrombone/Short/Trombone_Short_A2_v3_4.wav
8e519bb068b534f04d5f99b913e5602e927c0967	147500	Brass/OldTrombone/Short/Trombone_Short_C2_v1_1.wav
05c903b81df7b3bd696e08ff126ca6ef9c65f578	157874	Brass/OldTrombone/Short/Trombone_Short_C2_v1_2.wav
19df271ffad892e7491a2d209c54d4cb65268580	133760	Brass/OldTrombone/Short/Trombone_Short_C2_v1_3.wav
6bc84e8348c74b14c6d2d32b18bfd4a53ac5defe	132140	Brass/OldTrombone/Short/Trombone_Short_C2_v1_4.wav
144ce4a1602c04b14d41c043d5376db8ff5eaa47	137444	Brass/OldTrombone/Short/Trombone_Short_C2_v2_1.wav
eb859dfa6bc750e9ba111c0ecf4c9fdc55ef655c	132140	Brass/OldTrombone/Short/Trombone_Short_C2_v2_2.wav
3fb54d6a74d1b3b97952deea70a87cdc5bfa1e2a	212012	Brass/OldTrombone/Short/Trombone_Short_C2_v2_3.wav
10f6411f40de7f9784fe01c95a12619b9cde8e58	184418	Brass/OldTrombone/Short/Trombone_Short_C2_v2_4.wav
2629d9303688420ce9d2236b8cf748c58a2dcdb0	95276	Brass/OldTrombone/Short/Trombone_Short_C2_v3_1.wav
5d9629c7fed2dee7e0ef82ead91cf05133a61c73	224576	Brass/OldTrombone/Short/Trombone_Short_C2_v3_2.wav
d126afe0342c9f0b3c6b72a1fc6fa7476f5e97b1	181292	Brass/OldTrombone/Short/Trombone_Short_C2_v3_3.wav
70ae6d1cebe5855b688c2a0fc4d4e75ac1466b29	172076	Brass/OldTrombone/Short/Trombone_Short_C2_v3_4.wav
6e7310e3b3a2081829c6d1a81025b40bf747d3ee	202796	Brass/OldTrombone/Short/Trombone_Short_C3_v1_1.wav
1604d7bd9fb8487150d3d5f7afbb601cedcdd35a	208982	Brass/OldTrombone/Short/Trombone_Short_C3_v1_2.wav
6312da4d5e98c5ea7c8d109273db361e65abdebd	208940	Brass/OldTrombone/Short/Trombone_Short_C3_v1_3.wav
b21e83e68593068fbf77e527e6a1cc4cc2da1d0f	188186	Brass/OldTrombone/Short/Trombone_Short_C3_v1_4.wav
3eb3f1db26416cc52f08add54b87a29fd4a57a8f	279596	Brass/OldTrombone/Short/Trombone_Short_C3_v2_1.wav
a11569f5aad97596c0c6dba5a64444fbd423cf82	261332	Brass/OldTrombone/Short/Trombone_Short_C3_v2_2.wav
26bc776eab371c581ea2820ff77d71645faaeceb	199724	Brass/OldTrombone/Short/Trombone_Short_C3_v2_3.wav
715cce3986c29159d085d7194070eac8d73b11a3	240752	Brass/OldTrombone/Short/Trombone_Short_C3_v2_4.wav
a4cbb6d2b2ca81e54ccbf2aa69d14b24c9e2d2d0	242570	Brass/OldTrombone/Short/Trombone_Short_C3_v2_5.wav
172812e5ec9be3893f0a6dc77e95bbed195bb719	275774	Brass/OldTrombone/Short/Trombone_Short_C3_v3_1.wav
7889535ac80874afdd449d4abfa18f2104c9a889	279596	Brass/OldTrombone/Short/Trombone_Short_C3_v3_2.wav
9c1908d1d843c063ed068fbb70462fbea99683c7	190676	Brass/OldTrombone/Short/Trombone_Short_C3_v3_3.wav
6f587a152166bfab04f39e6e3a12c46fabd4b156	166292	Brass/OldTrombone/Short/Trombone_Short_C3_v3_4.wav
f5ab74a31da16ac97dbf3977847b029b26d4d088	159788	Brass/OldTrombone/Short/Trombone_Short_D#2_v1_1.wav
13a189a0e3a4394d269d95afdada5621554baf48	141824	Brass/OldTrombone/Short/Trombone_Short_D#2_v1_2.wav
48db404fd4932904c683d91a8c6a0185262ae1ee	148196	Brass/OldTrombone/Short/Trombone_Short_D#2_v1_3.wav
db6e5cbd78e006b3930f668b2d2886584ff9b43a	141482	Brass/OldTrombone/Short/Trombone_Short_D#2_v1_4.wav
301793be42384ec5e5baf7c91873e551970fe08d	186092	Brass/OldTrombone/Short/Trombone_Short_D#2_v2_1.wav
6c51c99edadee9a88ec2d4f1d8a12bf8ea000a7a	215024	Brass/OldTrombone/Short/Trombone_Short_D#2_v2_2.wav
ce297d10dd4e9062d6c71df3cae3d247055b3f44	165932	Brass/OldTrombone/Short/Trombone_Short_D#2_v2_3.wav
16dc32c566ff1e90be9edcccf9a7ab6068e92083	190508	Brass/OldTrombone/Short/Trombone_Short_D#2_v2_4.wav
61a43e2c62d5de6fab207703169ce13160fa8ca6	150572	Brass/OldTrombone/Short/Trombone_Short_D#2_v3_1.wav
58f7f252cd27df28bcd6e15fbe01f7812724c30c	153500	Brass/OldTrombone/Short/Trombone_Short_D#2_v3_2.wav
a319141d2630ed0546fcb35445f41297999bcc31	156716	Brass/OldTrombone/Short/Trombone_Short_D#2_v3_3.wav
c1fe95f6c0790a0e90d0b687772f38b662a932fe	285740	Brass/OldTrombone/Short/Trombone_Short_D#2_v3_4.wav
0f90509030e83281e112c1df5d1797d2849c4115	159482	Brass/OldTrombone/Short/Trombone_Short_D#3_v1_1.wav
2c47c8d541dfee09e816dae7feff18bc22cec7a0	159614	Brass/OldTrombone/Short/Trombone_Short_D#3_v1_2.wav
24fe97a3d37583b9e70ae082e006601aa9dac517	138284	Brass/OldTrombone/Short/Trombone_Short_D#3_v1_3.wav
502e8d8b1915aaf9f95f9a3f50a4972cc3e6a2d1	213548	Brass/OldTrombone/Short/Trombone_Short_D#3_v1_4.wav
8536156ab8a5ea839f81c693f35f979674863923	223844	Brass/OldTrombone/Short/Trombone_Short_D#3_v1_5.wav
5149b3b67eb583f9689138cd44fcb25e76c1852b	310316	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_1.wav
a6808c0248dc3873c26c62b8005346003a6a1050	288812	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_2.wav
055897f84ba7ddfbbf221eaede86d882215dbafd	382214	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_3.wav
5e548f0d44df5932d8a457b6c777b82b940cdb23	258092	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_4.wav
ceeeca02856af492701a34def141dd8d4641ab62	282668	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_5.wav
a2f123ca457782c6738f51d0a664e3964bd1ca90	284234	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_6.wav
16343801fa24e32d4753b9f0080bc409afb69d37	307244	Brass/OldTrombone/Short/Trombone_Short_D#3_v2_7.wav
fe23e077425fc78027f906b1cdc069257ae3d3f2	249776	Brass/OldTrombone/Short/Trombone_Short_D#3_v3_1.wav
9a0a4cc9b5c128856aa8cbab82a7c04993b640cb	234698	Brass/OldTrombone/Short/Trombone_Short_D#3_v3_2.wav
edc05060ff91aec42f6487eedb17a1addd603a28	261458	Brass/OldTrombone/Short/Trombone_Short_D#3_v3_3.wav
3393ebb39894955b71707f9d39140f929654873b	282668	Brass/OldTrombone/Short/Trombone_Short_D#3_v3_4.wav
4bb29ffb480144fe928486df6ebff4376ce8c266	178418	Brass/OldTrombone/Short/Trombone_Short_D2_v1_1.wav
6fbab43b5478396539be656b9f798eac2f7dab34	156716	Brass/OldTrombone/Short/Trombone_Short_D2_v1_2.wav
66f6a8f8b6f2bac9c0352bcde39b9c29e2f6a4f2	162860	Brass/OldTrombone/Short/Trombone_Short_D2_v1_3.wav
5abd53c0e10a790f1742c0e71860849b7438d435	162782	Brass/OldTrombone/Short/Trombone_Short_D2_v1_4.wav
f8aa76a032b052f5d6133b3e9693b08c88ce1218	224300	Brass/OldTrombone/Short/Trombone_Short_D2_v2_1.wav
a06a84b55436e2cdcf872be0230af3ee8ba72c5c	302222	Brass/OldTrombone/Short/Trombone_Short_D2_v2_2.wav
e06d17ed25040f75d409d2cbcf9c305aeaf993c8	282668	Brass/OldTrombone/Short/Trombone_Short_D2_v2_3.wav
6552501d1a238b131467b28a2920f1c4615fc81e	313388	Brass/OldTrombone/Short/Trombone_Short_D2_v2_4.wav
a700217ee5bdba060f0ffd43993dfd30bd807c1f	251978	Brass/OldTrombone/Short/Trombone_Short_D2_v3_1.wav
33963f64dc41ed4288a7cbaada17668ad9b88e81	227372	Brass/OldTrombone/Short/Trombone_Short_D2_v3_2.wav
a6f8a5623f8074708f4048f67fa527201767e75b	227030	Brass/OldTrombone/Short/Trombone_Short_D2_v3_3.wav
67e506d73d9c92befe5098052dba1cbc395e4d0e	205868	Brass/OldTrombone/Short/Trombone_Short_D2_v3_4.wav
c13714eee6b97dbe133ceb3df8876d49d59f63cb	182960	Brass/OldTrombone/Short/Trombone_Short_D3_v1_1.wav
66e7a21f670b3223a193dcc6a1d1c1974205e00a	153002	Brass/OldTrombone/Short/Trombone_Short_D3_v1_2.wav
556e3b4c4b0390265618b35be58bff18868e7b69	199724	Brass/OldTrombone/Short/Trombone_Short_D3_v1_3.wav
2fbdf78f20762d39b98df1f1b2949149f9959f65	226922	Brass/OldTrombone/Short/Trombone_Short_D3_v1_4.wav
e42873aa07776e858a8f8cc2ea9d71a332a0bc4f	273452	Brass/OldTrombone/Short/Trombone_Short_D3_v2_1.wav
ad0419cfb47070a4deefa8a81538d54ef78c26ef	273452	Brass/OldTrombone/Short/Trombone_Short_D3_v2_2.wav
497c9c01fabab72badcbf5608658ab31b80dc010	267308	Brass/OldTrombone/Short/Trombone_Short_D3_v2_3.wav
d1ba160fed8f05ccc653e4bd1821ed719a390704	353552	Brass/OldTrombone/Short/Trombone_Short_D3_v2_4.wav
41b082f6081dd1990140681813d39e42bc9f3029	291884	Brass/OldTrombone/Short/Trombone_Short_D3_v3_1.wav
86083d92e7448662c365c4cf0467febb3d60a8b0	285530	Brass/OldTrombone/Short/Trombone_Short_D3_v3_2.wav
d1ad2a2a15219fa009db0acbf4572a8769384c45	276986	Brass/OldTrombone/Short/Trombone_Short_D3_v3_3.wav
dbf61649fb6c0125dd402b1ab44a5e3cae4aef05	181292	Brass/OldTrombone/Short/Trombone_Short_D3_v3_4.wav
ff3b306f83b4d1b3e94e41bbfbc5ef2f80ce386b	180908	Brass/OldTrombone/Short/Trombone_Short_F1_v1_1.wav
a7beb639bf5010ae0ce6304eef146deb09ff1c61	140444	Brass/OldTrombone/Short/Trombone_Short_F1_v1_2.wav
84c593132477447afc15db94940f857b12d1388d	144428	Brass/OldTrombone/Short/Trombone_Short_F1_v1_3.wav
bd32ce49af1ff64056eb6671dd7de889967dbb55	144428	Brass/OldTrombone/Short/Trombone_Short_F1_v1_4.wav
0be534ceac9e0549a147137c0f973791c67f9579	273452	Brass/OldTrombone/Short/Trombone_Short_F1_v2_1.wav
acc15da51992784a58a98de1e1941489efbd44be	273452	Brass/OldTrombone/Short/Trombone_Short_F1_v2_2.wav
db1644533e0c2f6f3598960179920f71f283747f	235748	Brass/OldTrombone/Short/Trombone_Short_F1_v2_3.wav
77f206ea9011c04be9f699d7a7bd31e69b5c1343	296204	Brass/OldTrombone/Short/Trombone_Short_F1_v2_4.wav
9494ce9bbe80c8a1d48f3fc33067b663db02b26d	253088	Brass/OldTrombone/Short/Trombone_Short_F1_v2_5.wav
dbecfdc7a106fa9ff58b7b34bbb52e672a85b5ce	218156	Brass/OldTrombone/Short/Trombone_Short_F1_v3_1.wav
e69d6fda71d710b9bc7cfe79830298fbeed6f70f	255020	Brass/OldTrombone/Short/Trombone_Short_F1_v3_2.wav
61960cac6bfc960e8ca22e1819b569bc9231da03	285740	Brass/OldTrombone/Short/Trombone_Short_F1_v3_3.wav
35abf6951c355958c0a719b7723ceae1efef7e27	271544	Brass/OldTrombone/Short/Trombone_Short_F1_v3_4.wav
531650f9757d4ea684a37a602bf55e43605408bf	216674	Brass/OldTrombone/Short/Trombone_Short_F1_v3_5.wav
9d0979c6411b5ebfa52f33c70e6038003a73a850	256400	Brass/OldTrombone/Short/Trombone_Short_F1_v3_6.wav
4282c7e2edc99512fb51486f5be2b2bfa52c5039	178220	Brass/OldTrombone/Short/Trombone_Short_F1_v3_7.wav
083e11485f341df5119f53e9063bfd31169ddecb	184346	Brass/OldTrombone/Short/Trombone_Short_F2_v1_1.wav
4c9d87e540c7c911551c3bc20b0d38d6351126d3	166382	Brass/OldTrombone/Short/Trombone_Short_F2_v1_2.wav
2ad96a77cb115e4372625456269bdc3b3611690c	169004	Brass/OldTrombone/Short/Trombone_Short_F2_v1_3.wav
8b5684edcc151c4600a72a544518fdc2c57dd620	165932	Brass/OldTrombone/Short/Trombone_Short_F2_v1_4.wav
b6f2261b9ddadb5760e13860089a56c5738ad7f4	237074	Brass/OldTrombone/Short/Trombone_Short_F2_v2_1.wav
e645799d3afb6f6eea0d2f880c1c66547d93da3f	215084	Brass/OldTrombone/Short/Trombone_Short_F2_v2_2.wav
7df1bc425a21276d61422662e0b35119a11fc501	210722	Brass/OldTrombone/Short/Trombone_Short_F2_v2_3.wav
0be51afa31f282932f225a18c90e54c8f366cd06	319532	Brass/OldTrombone/Short/Trombone_Short_F2_v2_4.wav
737c55dec7f28a192f456523bd7e3f2ccfe69397	291884	Brass/OldTrombone/Short/Trombone_Short_F2_v3_1.wav
ccf9dda6c5eb57d66d023a682dc3467f27b1fb6b	298028	Brass/OldTrombone/Short/Trombone_Short_F2_v3_2.wav
30400d0f3ba6862a78442a91ed1019b708495357	285254	Brass/OldTrombone/Short/Trombone_Short_F2_v3_3.wav
80486f5e55c50df543e48e1d931f23055c1a5586	321866	Brass/OldTrombone/Short/Trombone_Short_F2_v3_4.wav
02f63c293f7da2ecb5871c31e0666450a10f4920	230444	Brass/OldTrombone/Short/Trombone_Short_F3_v1_1.wav
cd4f4cefbad416b66cba6125fd5e74ad00725041	224300	Brass/OldTrombone/Short/Trombone_Short_F3_v1_2.wav
6dae9a0d68a3e3b090b5144265db8b5ec3e5ca86	192932	Brass/OldTrombone/Short/Trombone_Short_F3_v1_3.wav
f0ef2b67544c090d3e11db6f246607ec974ab55c	410750	Brass/OldTrombone/Short/Trombone_Short_F3_v1_4.wav
783d9e192de19c3be4eb46df9880b3bf0334cc1e	273452	Brass/OldTrombone/Short/Trombone_Short_F3_v2_1.wav
097480fedfd8949f306af784e871bb607eb6b451	301052	Brass/OldTrombone/Short/Trombone_Short_F3_v2_2.wav
87e8fbda099274dca8fc3eb5938a7154b2d3e772	290258	Brass/OldTrombone/Short/Trombone_Short_F3_v2_3.wav
5f9239220b5b7c572b91767a320389eb4084c337	272816	Brass/OldTrombone/Short/Trombone_Short_F3_v2_4.wav
10d60626338d379dacccbbe64efcb1c5d29a64c5	276782	Brass/OldTrombone/Short/Trombone_Short_F3_v3_1.wav
fc1886a7778314abd2bea74275bb99c718db651c	279596	Brass/OldTrombone/Short/Trombone_Short_F3_v3_2.wav
eb5cc0ddfa8fd9c35cec27cdeaf15e5db6fa6393	261164	Brass/OldTrombone/Short/Trombone_Short_F3_v3_3.wav
0929f883421b70bb59908e0ecb5b8b06a8810210	262388	Brass/OldTrombone/Short/Trombone_Short_F3_v3_4.wav
395d6bebba0410ca24606a24b27829f842439b1e	141560	Brass/OldTrombone/Short/Trombone_Short_G1_v1_1.wav
72d60ac7c992c341de2b76edf6c099e31413842a	175148	Brass/OldTrombone/Short/Trombone_Short_G1_v1_2.wav
94757ca65f4750e5a628de3e972409c736850afd	162860	Brass/OldTrombone/Short/Trombone_Short_G1_v1_3.wav
b126e22189039a10d4766c5a1df05db0ce08bb03	174854	Brass/OldTrombone/Short/Trombone_Short_G1_v1_4.wav
6fd762540b90a122b36d952770e09dbee0ceb1d6	246374	Brass/OldTrombone/Short/Trombone_Short_G1_v2_1.wav
193617e84f6eb5055daa1a0f7a8808fa959bb049	285740	Brass/OldTrombone/Short/Trombone_Short_G1_v2_2.wav
36d15637ce94f41aa3c749b6afa8ceeeef00c5c0	288812	Brass/OldTrombone/Short/Trombone_Short_G1_v2_3.wav
3af33a8d1a520fc62fc5447eeb74a78953275ae1	287216	Brass/OldTrombone/Short/Trombone_Short_G1_v2_4.wav
78fd3e8f005cae0a5019ab890403a6efff7f9f9b	242732	Brass/OldTrombone/Short/Trombone_Short_G1_v3_1.wav
f6bb5f50a04cb73998d4e42f2b0c8b331050172d	226496	Brass/OldTrombone/Short/Trombone_Short_G1_v3_2.wav
f3d0235b295e2765e4e8ec8d5946e8bd310d1699	237098	Brass/OldTrombone/Short/Trombone_Short_G1_v3_3.wav
9725c93a3c054485686e365bfeba753da22ff77c	232838	Brass/OldTrombone/Short/Trombone_Short_G1_v3_4.wav
559c431e172fb206fb9f3b1eae7692ce82d9d2cf	159788	Brass/OldTrombone/Short/Trombone_Short_G2_v1_1.wav
0203db13929074f8c2f95650767369a4f8459425	181292	Brass/OldTrombone/Short/Trombone_Short_G2_v1_2.wav
a2b2ee089c29ecf4a92424691e4ac3e7b6ac1558	178220	Brass/OldTrombone/Short/Trombone_Short_G2_v1_3.wav
db09d5675cf1b96543b5c7a7e74f7e57932d20d2	169214	Brass/OldTrombone/Short/Trombone_Short_G2_v1_4.wav
679b32af78e842deb2743748bd0ae829796f6b09	218156	Brass/OldTrombone/Short/Trombone_Short_G2_v2_1.wav
74c88f0c7184ce093b9b098c1ad76180f60346b1	233516	Brass/OldTrombone/Short/Trombone_Short_G2_v2_2.wav
be03e63c27231d4f790d526d4f4bac9751cc76a6	239660	Brass/OldTrombone/Short/Trombone_Short_G2_v2_3.wav
09d481e3090f295fed789d6db0a8c2310ed8eb93	305732	Brass/OldTrombone/Short/Trombone_Short_G2_v2_4.wav
45a7e7d1ed0a4d4b294e0fa8fd8272f23900191b	288812	Brass/OldTrombone/Short/Trombone_Short_G2_v3_1.wav
b1ecff47ee744355205df250b12f46a0c530dd79	183530	Brass/OldTrombone/Short/Trombone_Short_G2_v3_2.wav
d6ceeef7204f10dea0fd045d57bfbbc02c30506d	205868	Brass/OldTrombone/Short/Trombone_Short_G2_v3_3.wav
d8862ba9f9b765392c3494b35a2bfc02428472f0	245804	Brass/OldTrombone/Short/Trombone_Short_G2_v3_4.wav
6f2f84d03cd1dc8253ae69c7d9e8f2f85d8d42cc	1810628	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v1_1.wav
b003d8b9bc97e424bb8550eba369dd5285aef824	1864148	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v1_2.wav
0e5f785e268a9d75588374c231ea196bb2f58544	2863148	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v2_1.wav
3decf897bc4e3f3a6e3e563dd7d74751d0bc72c9	2252840	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v3_1.wav
490158afb2044dfdf4947d9b8fa44c15935f3558	2818946	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v3_2.wav
0eb11c3569bbefc9e9f50281aa9cc4a73eb84277	980012	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v4_1.wav
656915a2704eeacaceee09fd3ed49adf00c3756b	1566764	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v4_2.wav
a02682949f2645fb68826d0b51ce14f958774bdc	1050668	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v4_3.wav
2867cae3984ae872f9073d979d41425f87537d45	1530926	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v5_1.wav
fa978e27b70a3e0e06900dbc6e13e7dd06a776fd	878636	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v5_2.wav
8423a55fdec240749432aa2617c97ab7aab71d76	952364	Brass/OldTrombone/Sustain/Trombone_Sustain_A#1_v5_3.wav
25d79a3db4d3ae4528906868d6e24380ad9c2ac0	2173448	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v1_1.wav
d1b3f93569f765bf2d53476bedb17fbb1587a2e4	2115398	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v1_2.wav
700badc99b98166348bc262a535b011c48fa4028	2814242	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v2_1.wav
26fd4a28b99e7b83611bc798eeca6da126f3c183	2525228	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v3_1.wav
08f7e7e13fa7df8e7ccd05628757687726f116c1	1268114	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v4_1.wav
6b7c4211c7a5e6e6603de69a4773e34306de1b63	986156	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v4_2.wav
9d60331173df0831f38b2182600e28d6fbb4a7a6	967724	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v5_1.wav
1e86738db5c0d38f18316d4130396cb0ce6a5844	1142828	Brass/OldTrombone/Sustain/Trombone_Sustain_A#2_v5_2.wav
ca24b77b86ffaf7d224e9fa90decca154ac4d6f7	1947434	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v1_1.wav
b226241d84563abce1de6cb1cf5228614a58e155	2451500	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v1_2.wav
adde0f26cdc9f0a51a0a1b55fb19e42cd15d0d43	2597768	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v2_1.wav
a4cd383484b1e1d709fe957dbcaaa25b334ce9ad	2276696	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v3_1.wav
b8408b06810d89ba006600c99812d34d69aee66c	1069100	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v4_1.wav
d0be60b6d5620cd2f4192ca884026164813f3a54	915500	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v5_1.wav
07ecdea810fcc294018ba940ccc7ea8eb61fdbbe	948494	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v5_2.wav
1e06e3a561c17a565b3e350722a758540911ada8	844844	Brass/OldTrombone/Sustain/Trombone_Sustain_A1_v5_3.wav
1c7b53d777ee9aaf9ede551068625c2ebbda6c77	1815596	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v1_1.wav
621afdcac4ece5e4ffc033649d6b1775ee35b99d	2042924	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v1_2.wav
ce6b975667d36f2b39f1af1db683e5f79e366a77	3250220	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v2_1.wav
b0ef87d668285941a81ed034f5789be39018f72d	2251820	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v3_1.wav
858b9528181ec85fd480fc4de776a48604543248	1126730	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v4_1.wav
f07c63371b15fc62f74de941dbcbdc547ed41f86	1093676	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v4_2.wav
5d9477dcda4bb205ad672bb0e83e7bcadfaa5868	921644	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v5_1.wav
b86d9c772290db31cc11b7bbe16f0c66c968c959	791984	Brass/OldTrombone/Sustain/Trombone_Sustain_A2_v5_2.wav
7b2b333fe8a6ba68699de0c45b39e3ecafa4d113	1947926	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v1_1.wav
40cf35e34155b4b6cd98fb1c220908c7a24e224e	1517612	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v1_2.wav
66c4547c85418f0c532eb879f75cbe4f7454fcff	2473508	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v2_1.wav
501f81a556d38f94bf813e6479a764dc020b9a4a	2846936	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v3_1.wav
7b02fb41e96b2c5ff3cf9d8087693672b6d1897c	1195052	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v4_1.wav
47b07797101def948ff952cd586c823e75f46c4c	1112108	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v4_2.wav
389acdc738d756e9b07058323a902ad2c1d5c88d	1102286	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v5_1.wav
a2cbc3941e541fcd557a56a97ca12a3aceaee960	728108	Brass/OldTrombone/Sustain/Trombone_Sustain_C2_v5_2.wav
1bf807b8a36a8f0f3b7c1a5c4a090a00c3bc4a80	2224172	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v1_1.wav
1bbe57311bd1471d140f96c08e9beb98570c5048	2866628	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v1_2.wav
46994a9d9a818b97a79829db27f148bcacfc9ae6	3652946	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v2_1.wav
3339ee6c429d3fe8fe3878ac10abfefe2b55efeb	2544158	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v3_1.wav
b2b4b43a6bdf031444a9499a2f6125a6296d92c5	1130540	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v4_1.wav
755900888f020978c1ef310a9008d76c88839ddb	1095326	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v4_2.wav
b1426d3d5e37c41073e506ed410c57266a0b43dd	1050668	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v5_1.wav
eb97d25cb06bd5f8f9c13ee192943c5b0b02fffa	1066028	Brass/OldTrombone/Sustain/Trombone_Sustain_C3_v5_2.wav
3bc8660beabd40fa73035cbf954a154f697e4264	1776278	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v1_1.wav
337533a1802d0a6d42bdd8e38257430904820962	1591340	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v1_2.wav
47c8df2e4401a7ad8277dc7aff25332a691beb8a	2691116	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v2_1.wav
3e4ac77aaf740e2240584cc70670eb23e410c3f1	2334764	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v3_1.wav
c31cc363a494fdda0c4cc2826934373a4d79a417	1098386	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v4_1.wav
f9b92558f32d703acdd5b630549dfc4ade6fd55b	1094942	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v4_2.wav
fe3a502c9047026d45f64fb62c8682b0a79243bb	1166936	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v5_1.wav
eb5fb53e0ba0892f7f262ced1779358b69e0e7bf	900530	Brass/OldTrombone/Sustain/Trombone_Sustain_D#2_v5_2.wav
d7713b7ebbbe23ce0701d8b3d4ecc1912612057d	1935404	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v1_1.wav
b11bdd63ded7b27e88cfbdda1d7afa02e11a135b	2150630	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v1_2.wav
e223231dc33acd18ca5d4cd0ee71cb29cf178a71	3004460	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v2_1.wav
ebfad529b7356deb3cd3d4d9a4b9dab0153e528c	2746412	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v3_1.wav
367de12b0463fbde58506a93503a1c8fe862b689	1459244	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v4_1.wav
18ea66c37f0944c15cc71fcbb2bdccc6d9ddc4eb	1127468	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v4_2.wav
84deb254cd2ca9806808ee2c41168f9de7189f82	935792	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v5_1.wav
813f2c5960e66fbc51f8bcdef2bcb9f9252ffcf5	1163756	Brass/OldTrombone/Sustain/Trombone_Sustain_D#3_v5_2.wav
3c64d01b8010f781a66bb2777e355ab4bb0a304f	2021762	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v1_1.wav
ee9756fb81f2449e5108985f8a19d831b95bed4f	1703408	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v1_2.wav
16aa68d2cb2aaa54e922b4148dc2a2b392dc53e1	2432786	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v2_1.wav
e1e9a118561ae613ae65c34e98fdf68855e7154a	3161144	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v3_1.wav
2db98cd7a5a6a10052ba9703f36f513a680789c1	1132076	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v4_1.wav
d1264607267ff5caab9f69b286e89be4cb8931fc	1113014	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v4_2.wav
30510c8106df72b7b115d42719b6dd988969b52a	1084460	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v5_1.wav
b1fac175a99bd0c1ed4284092633862902b8a272	992300	Brass/OldTrombone/Sustain/Trombone_Sustain_D2_v5_2.wav
a8d20c3af95a48c48cc9cc7349b394fbb7df2896	1998296	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v1_1.wav
b540981c68ab3bc2984a5345082b7f760d74bbed	2362412	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v1_2.wav
81f1d0927654be50f63003d850d4010e7f6ad323	2917988	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v2_1.wav
4318238f5cb2a847808f76063fca4c8a35855a43	2544698	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v3_1.wav
e9fef2837c3a5ac43d2dd97650c71621af2b036f	1189160	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v4_1.wav
c2f409590ad9db2bb421a0b82d19cc150c99252c	1070114	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v4_2.wav
ca0e4009190be4cf1a36381dcbcedb8ef9fe5c18	1256492	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v5_1.wav
e896f942caac81f5cce3ca104c140525cc24c1fb	1335566	Brass/OldTrombone/Sustain/Trombone_Sustain_D3_v5_2.wav
54ce2fec612e3bbe3797acce9d1f3382b38c87e7	1826654	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v1_1.wav
a81566f569e208e88f44bad6546b4789ee9fb536	2224058	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v1_2.wav
20ef0ad365a3291ad4763de3f474439f5fd3495b	1976960	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v2_1.wav
5502b8252245f3399a277fe8be5405f0371c92fe	2021420	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v3_1.wav
618f08fbd566a366ac38a2216ca43bea53570bd5	1090604	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v4_1.wav
557c20557828b7a40b68d134f97268e588e5207b	988862	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v4_2.wav
d365662a75adf62bcdde7e98c921cb394618d37c	970796	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v5_1.wav
986b8ba3def62b04b37308211f7677e1b4f13d2c	986156	Brass/OldTrombone/Sustain/Trombone_Sustain_F1_v5_2.wav
557be09aeeabeab56fdfd672e281502cce4356c9	1795664	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v1_1.wav
1ea36d615f251820aaab10bc596bd4763a8dffe1	2374700	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v1_2.wav
c3c8eda2f65411468503c6d1850ecb144fcab161	2979884	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v2_1.wav
35350bc76226e93269fe34303b5bd7d16e6bc225	2734274	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v3_1.wav
6b3559d3d4e1823a60623e75c82f22d61cd7d4aa	1456172	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v4_1.wav
f8207d6f764c7dabf7e7de6f85e0dc14db709dbf	929726	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v4_2.wav
e9375d355eaaa0f59608658af1e34f11daa12a29	1559660	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v5_1.wav
d23f9ec8a9b06b7bb7734a589debf60d94ece33e	1215878	Brass/OldTrombone/Sustain/Trombone_Sustain_F2_v5_2.wav
7a88b5de6765daf6fb4d924fca28c56d0d33d6c9	2383916	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v1_1.wav
4c1ea26612270c4bdbf64c39a82b2824b898769a	2506796	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v1_2.wav
1bbfcc15260d3726e4a675e11514dc7a9ac09b7a	2177990	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v2_1.wav
7131eeddbca3dad0b703695ef36a907c08ea4599	2863148	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v3_1.wav
33cd820eeb6bbed915389db153edd8817aa1f347	1220228	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v4_1.wav
c8d408bbb0ddf52f0a5c90e90e7d030ced888f55	940910	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v4_2.wav
8dc0f99701bcce5271663b9fa7c869cab8e468aa	1167404	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v5_1.wav
0858401da706f428325c830d7ac7056a22cedb8b	1109036	Brass/OldTrombone/Sustain/Trombone_Sustain_F3_v5_2.wav
73a620ed718c986ff392113dd625d5541cb66b9f	1765598	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v1_1.wav
60329e6f72b15a378d435d21070746e18c4852a1	1987394	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v1_2.wav
ec7ec81f39c18ce43b236bd079fa284741b7787f	2717456	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v2_1.wav
195e4e45cb2e4ab1f67605480f100353c9374d6b	1996844	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v3_1.wav
971bbdf92463121d45f72dcf33ef612b1836d037	1657982	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v3_2.wav
b05ab701594ce09749747aa38224ef42cc963ef8	1232714	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v4_1.wav
519e55b48b9853a4b5170fd7ef26d645c33d1274	1010732	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v4_2.wav
31b48db5ad1fb53e0ddc6d82da4a1db4f30de101	855626	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v5_1.wav
2a6865e8069e3d115251629ce3d0b67bede0eecd	886604	Brass/OldTrombone/Sustain/Trombone_Sustain_G1_v5_2.wav
91a2c65148677a5c0a1dd1f11df26c91d48798f6	2270948	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v1_1.wav
491c4919fd872ce120e7bab3e41668bcda82ece2	2123558	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v1_2.wav
58996b7da93c0ed97e02bd7d7c583d2dea504629	2459480	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v2_1.wav
9d08f83cd1fcfcd0d128de50f3967fe0451189a7	2978054	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v3_1.wav
0d1f8e1900de5216141677dd51ec650d762de6d3	1410092	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v4_1.wav
700e065eaa420d51b2dbd5e417125cb742371dba	1102892	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v4_2.wav
64c92b978548e180c9f678016747e1367aada211	1295810	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v5_1.wav
3a92576d3e44c489db6b94ee29b69096d7f04e1f	1070870	Brass/OldTrombone/Sustain/Trombone_Sustain_G2_v5_2.wav
635062308c738e2ae43cf9c00a354706d285fab9	1873034	Brass/OldTrombone/Sustain/Trombone_Sustain_G3_v2_1.wav
5ec529c77a5d566942110a328e873c09eeb7f844	1827884	Brass/OldTrombone/Sustain/Trombone_Sustain_G3_v2_2.wav
3118efac04669dcc0fea07a2de363e49cd2c2902	1124396	Brass/OldTrombone/Sustain/Trombone_Sustain_G3_v5_1.wav
51ca116cd5038c38353be48238e4f824bb9cbcdc	1107212	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#1_v1_1.wav
ac1a0197742484a11dd131929c4f005988196f69	1757228	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#1_v1_2.wav
8c33443776164a8b259ab5ff1413b016fcc3d8f5	433100	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#1_v1_3.wav
fd13e95f2f46db49f4f9060e5c35f9d3b182b58d	1605530	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#2_v1_1.wav
b2b2c0e294567ddd43df3c165e40530ba6c3e3d1	559148	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#2_v1_2.wav
6eb7415b111b84d9bd86c3dc3793f7b3ce460cb1	457772	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A#2_v1_3.wav
003694c926583418d81a9cf817c413cb9c327741	2632226	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A2_v1_1.wav
72abe973ef593c0edf7028b6d050f9ce7f7b82d0	632060	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A2_v1_2.wav
32d7eba5374fe0eabbdc290278d2557f26cc2433	476102	Brass/OldTrombone/Vibrato/Trombone_Vibrato_A2_v1_3.wav
ccd675a09550e6303e9f067d2cda7b8f0a26ef4f	1729580	Brass/OldTrombone/Vibrato/Trombone_Vibrato_C2_v1_1.wav
64c4cfb11d70aff1447e7f3cfd8407870c56a320	412874	Brass/OldTrombone/Vibrato/Trombone_Vibrato_C2_v1_2.wav
4f9eb9d8aac45296a0f5a34e4ea0b48a1d7f0c0f	433196	Brass/OldTrombone/Vibrato/Trombone_Vibrato_C3_v1_1.wav
0f025988f49b9f355b4cfba7108ff7f766f466e8	1454948	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D#2_v1_1.wav
3ae5e7a42a863d2bc9f0660f5da34d13f2262d92	463736	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D#2_v1_2.wav
6a892f9884a204c21489ec23d8f486e774e844f1	476642	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D#3_v1_1.wav
9e038bfe3280cb3efe8e94ccf72cad88d5c851ea	1730918	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D2_v1_1.wav
4f801e1e1e361fee468bc64aed244262c66c06bc	493322	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D2_v1_2.wav
a3788b5311ea05e30a5943c6ce6a72a0d486b14d	428612	Brass/OldTrombone/Vibrato/Trombone_Vibrato_D3_v1_1.wav
b90090072b3b88f7e8df8324669f3b54d5e6e342	2223464	Brass/OldTrombone/Vibrato/Trombone_Vibrato_F2_v1_1.wav
fe2e94e25802642b1d88d57fffaad475c28d7b8d	482552	Brass/OldTrombone/Vibrato/Trombone_Vibrato_F2_v1_2.wav
eed9ca8d673a2de3af1e7faa6db6de3c0f23eb3a	542588	Brass/OldTrombone/Vibrato/Trombone_Vibrato_F3_v1_1.wav
d645167c87024729eda454bb13a98d2871b26e4b	1718954	Brass/OldTrombone/Vibrato/Trombone_Vibrato_G2_v1_1.wav
0763a2508aa7be732134fdd34ded40bc811a5ee2	519458	Brass/OldTrombone/Vibrato/Trombone_Vibrato_G2_v1_2.wav
8937a788f22f3abd6c8b3d17d3924b47ae08d32f	170308	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v1_rr1.wav
626b72a06c8f16e7b405c05c4d9d5f525d631b65	180488	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v1_rr2.wav
8fd5f3092b2d9d88e51a1e3e423525ee4c0d6ede	210728	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v2_rr1.wav
cee76883dd41d147ac4de73b5d38758029dd8ccc	177660	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v2_rr2.wav
95673324beff9f3303d5ae3fe16b73e6e5501c2b	170680	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v3_rr1.wav
72ff8d0ebff690c764e6ef355c5036ae0acce5ab	303352	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v3_rr2.wav
72c262cae03320cea616854e6e9a7edd87c03445	185504	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v4_rr1.wav
9f35ceb2fc078fca63f93ec75413e6b504884c31	197632	Brass/Tenor Trombone/stac/tenortbn_stac_A#0_v4_rr2.wav
be9d933594ffc7e8883c613b527413682a8440f1	156432	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v1_rr1.wav
69e3c0348d2520f20fd25c7ca361021f78a29dcb	263624	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v1_rr2.wav
b489cd5449d3d082220faf517c005822808d0b4b	208332	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v2_rr1.wav
71e190a8060be44609af48f42bac7ddcd47850bc	290660	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v2_rr2.wav
79b0f7b1417faddc46890bb92508e52021d5da03	274064	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v3_rr1.wav
0c049f2b38424f1e7cddd1bb2773b7923efff2fb	215868	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v3_rr2.wav
9947fab6818aebb2977c473e964088638b02ff14	230512	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v4_rr1.wav
d323f7ba3db673b459f94b23175e9305a5a2995d	248472	Brass/Tenor Trombone/stac/tenortbn_stac_A#1_v4_rr2.wav
14fe341ff5e398a3230f76fe91ab6d9f6dbc8211	196392	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v1_rr1.wav
22bebbb1d39a81e3d753912ebe2f936ef9768038	299128	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v1_rr2.wav
ef7315518f9ea88e4b8195f7659f83fc7a6f6b08	179448	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v2_rr1.wav
d61ee7e58ab90ceec1f1bfdbaf5c0bab6f912ed8	295160	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v2_rr2.wav
ce149164e8a227ffbe3adfbed37181223dbe05d2	303796	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v3_rr1.wav
56fd03961972f3b2a8c894cbe9256b376ca1eb0c	342228	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v3_rr2.wav
df7df76b2dc43e31e2848b5942b91ffcc4da6548	276676	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v4_r2.wav
8d68825cf75741d32d75bd182130bb6ebb0bf3e9	358016	Brass/Tenor Trombone/stac/tenortbn_stac_A#2_v4_rr1.wav
b40fe1e2b7bf70663fd7435e6b4e9634a66a955a	260432	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v1_rr1.wav
a09f2b65aaaa0a3a1af410dc990f2e8376ccaa8a	174980	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v1_rr2.wav
5bda44b54bb60e7e1e681319928394b47a5eef5a	262148	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v2_rr1.wav
203a5ba1ab630d194c4cd28f2f584572b94c31f7	195532	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v2_rr2.wav
edeb1555e4d30c6e981c03a982a7d9149c3d79fb	314000	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v3_rr1.wav
f321ddf3d08d458faeef57da0c445ea3f8674bbd	238404	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v3_rr2.wav
3806b91e69df67b6c065fe80fd629df65b5391d4	328948	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v4_rr1.wav
688419e623c8022563d8b1880e2ab5fc4aa93bf9	347676	Brass/Tenor Trombone/stac/tenortbn_stac_D3_v4_rr2.wav
609aad6d7ef959889bc778c49cb76e257fbc9d86	206824	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v1_rr1.wav
76f9d9b968070f008fc44d8708c9495fcb811f23	220484	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v1_rr2.wav
93aec9029a704da43e0ad75a97fe25692f567094	234584	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v2_rr1.wav
f214d71c40e7a392015d88349c24d3e7709585cd	318040	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v2_rr2.wav
f103568b26e144a4a284f76e1902bd4a5ed754bb	259980	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v3_rr1.wav
b79bb400b9d39638fdbdfff4771bc1ec6ca83b51	214312	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v3_rr2.wav
2a88b80622277b5a4739445a7945cdc7a95123b8	323208	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v4_rr1.wav
0f778971b23d1c279757fc918fb822959294868e	207796	Brass/Tenor Trombone/stac/tenortbn_stac_F1_v4_rr2.wav
9286c22ff7fa3cea82617611f83189a170930d8d	180332	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v1_rr1.wav
e04d0180b6758368018cdac8de3c8884a0359b54	274384	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v1_rr2.wav
7fb521ee3cc17335cc454359f8801d7211598c84	164096	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v2_rr1.wav
2b2813053dcabeb7ef0f794a1c9b950adf0db15f	189624	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v2_rr2.wav
15d871a42884a9a6c8300021790e94a38a9c297b	177232	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v3_rr1.wav
00a9f623324538a93e90e2bdfc5c24b8b27cb06d	175100	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v3_rr2.wav
1ccb564b7564df62ac16af6947e1216489730941	270120	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v4_rr1.wav
86b845ae3d94c6e8213b61364a37c318904efc00	256564	Brass/Tenor Trombone/stac/tenortbn_stac_F2_v4_rr2.wav
7117430dfa725072c048ffab44998e685d81bd91	207184	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v1_rr1.wav
1adac947367a59bc188842e8b645a805f03f1e4e	186184	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v1_rr2.wav
6413045836a20da7a60cf5a0ce67efb44fe55e27	185392	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v2_rr1.wav
5e568a1abbb8469c8e2ad7d7deeb3621da086d4f	199272	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v2_rr2.wav
a1257ab3aa44b2e2464d82624087b3eb36783838	198704	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v3_rr1.wav
019eb003bcf58fa164cfdcf47316748b72cdaa7a	188292	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v3_rr2.wav
eca22d71889ee09f22e91af77b4a1dd8d6305758	353884	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v4_rr1.wav
6544d23257b3106d0f5aff57c2bf66906229997f	349876	Brass/Tenor Trombone/stac/tenortbn_stac_F3_v4_rr2.wav
adf430c94439820bb8876f7208b8f1756eb101c4	847440	Brass/Tenor Trombone/sus/tenortbn_sus_A#0_v1_1.wav
e81b27ce12cc7921533136f7c822ad66bde17b48	735596	Brass/Tenor Trombone/sus/tenortbn_sus_A#0_v2_1.wav
bebc48d3e9e0a15c375bfb331d8c0034d2bf3d52	3153736	Brass/Tenor Trombone/sus/tenortbn_sus_A#1_v1_1.wav
bfed422b95827132a8cd27cdf5f6bc3073dbc293	1658240	Brass/Tenor Trombone/sus/tenortbn_sus_A#1_v2_1.wav
52f58161c3944d30fb5598144697650b29224947	930872	Brass/Tenor Trombone/sus/tenortbn_sus_A#1_v3_1.wav
ecf7830fd218e877e6c761ba755e57c3cad81ac5	1313124	Brass/Tenor Trombone/sus/tenortbn_sus_C#1_v1_1.wav
232b246c39891a738c246a41685a2ed5a7c7470d	790124	Brass/Tenor Trombone/sus/tenortbn_sus_C#1_v2_1.wav
4388462bb1234613e754ad798404cc6b3e0fa792	3507148	Brass/Tenor Trombone/sus/tenortbn_sus_C#3_v1_1.wav
8e546c8995c15c63c856099030ae45c5abbc8924	1899776	Brass/Tenor Trombone/sus/tenortbn_sus_C#3_v2_1.wav
dfb869ad2e91b4fca51c017c7517c1bbf9958ce6	1373392	Brass/Tenor Trombone/sus/tenortbn_sus_C#3_v3_1.wav
b61096af88a303b6acc983e8a6aa22c83f3a8233	3920128	Brass/Tenor Trombone/sus/tenortbn_sus_C3_v1_1.wav
dbb030c2fdcfddf56ec0cbd1cc9cc2c03eb3aa33	1612016	Brass/Tenor Trombone/sus/tenortbn_sus_C3_v2_1.wav
a91b32be153b69d65c46f5be1e38310c70353661	1351140	Brass/Tenor Trombone/sus/tenortbn_sus_C3_v3_1.wav
3ada83e7586270bb31bd388a0c8236adcc4aa5a4	2080020	Brass/Tenor Trombone/sus/tenortbn_sus_D#1_v1_1.wav
1ed2a84fb7bb34ab7cb80dd9e60adedf3e544a2b	1166532	Brass/Tenor Trombone/sus/tenortbn_sus_D#1_v2_1.wav
f40c52cd3f82d755429815e79e1541554ea5b48d	881860	Brass/Tenor Trombone/sus/tenortbn_sus_D#1_v3_1.wav
a40cbae87dab599f03cce9319cfcdac5b90293d7	4283492	Brass/Tenor Trombone/sus/tenortbn_sus_D#3_v1_1.wav
f328088a8745a2c01d1d39c78db9a65599f86bca	2429760	Brass/Tenor Trombone/sus/tenortbn_sus_D#3_v2_1.wav
cb97ac413666687d63624c704e832b4196e0ddd6	1239208	Brass/Tenor Trombone/sus/tenortbn_sus_D#3_v3_1.wav
2721e50862bd57ada8245162917fc048e03b061a	2733168	Brass/Tenor Trombone/sus/tenortbn_sus_D2_v1_1.wav
879dbfba0ad741de2c7b34688ce7a6c763b54da2	1733144	Brass/Tenor Trombone/sus/tenortbn_sus_D2_v2_1.wav
eef36ce79c6497eacde16aca18edbfbd0418e837	1162132	Brass/Tenor Trombone/sus/tenortbn_sus_D2_v3_1.wav
c9214a98d0743da8a396db3fdfa3c9cbdd07b5ce	2281664	Brass/Tenor Trombone/sus/tenortbn_sus_F1_v1_1.wav
baabbbd2f72b8e34259cef60bde4b6c2f1fd554c	1400820	Brass/Tenor Trombone/sus/tenortbn_sus_F1_v2_1.wav
81a07a374fad649fb6d2589cea8756b0af3fc8f2	1197948	Brass/Tenor Trombone/sus/tenortbn_sus_F1_v3_1.wav
7f98be760c0092deabe3026562d783b6473772bf	3612792	Brass/Tenor Trombone/sus/tenortbn_sus_F2_v1_1.wav
34359f397938e10a675d5906f21cd90392cad15b	1752628	Brass/Tenor Trombone/sus/tenortbn_sus_F2_v2_1.wav
f6c1025383f62db27083c3cb78d5046d748ada4c	1107668	Brass/Tenor Trombone/sus/tenortbn_sus_F2_v3_1.wav
4c6cd39dc8a64bf7517308616a6390cce1e190e5	4557044	Brass/Tenor Trombone/sus/tenortbn_sus_F3_v1_1.wav
aad935618350cdffb0af783043d3b63e00b6092a	2127892	Brass/Tenor Trombone/sus/tenortbn_sus_F3_v2_1.wav
c6164474bad88e9d7718358a669ba076d825fff7	1299872	Brass/Tenor Trombone/sus/tenortbn_sus_F3_v3_1.wav
d75276cacc60d0dd723360b27a45d263b1d3c803	890576	Brass/Tenor Trombone/vib/tenortbn_vib_A#1_v1_1.wav
fbf3af52bfb43269f3ed6b9bd1d9c3caa8cc9c83	1031644	Brass/Tenor Trombone/vib/tenortbn_vib_A#2_v1_1.wav
e317a0bd1ddd1bb29a74a46ea48d0ee83fa81ec6	925568	Brass/Tenor Trombone/vib/tenortbn_vib_C2_v1_1.wav
12fc2be5cfc4c36b15d35dc037b6f0deb287a257	970108	Brass/Tenor Trombone/vib/tenortbn_vib_C3_v1_1.wav
f5f3ec888aa9bfba6923c4c867ee05445d1abfc8	1052124	Brass/Tenor Trombone/vib/tenortbn_vib_D#2_v1_1.wav
58eda2a6f51f70dbda0b8cb2935642b9c806f060	998944	Brass/Tenor Trombone/vib/tenortbn_vib_D#3_v1_1.wav
7bd8d603e324ab3b0f9f36a336241b664c9f2f41	961348	Brass/Tenor Trombone/vib/tenortbn_vib_D3_v1_1.wav
0622467ea271d1c7cc3cfdbc0a7adef3760cb41d	897380	Brass/Tenor Trombone/vib/tenortbn_vib_F1_v1_1.wav
90e2e551f6638702ad3bd81cd98522438db0216c	1311620	Brass/Tenor Trombone/vib/tenortbn_vib_F2_v1_1.wav
457f46e2152abc5ac241d47ae105c3c3ded7ff0d	934056	Brass/Tenor Trombone/vib/tenortbn_vib_G#1_v1_1.wav
55c0392d54f46a4acddb9f7e665a8731696703c7	1079056	Brass/Tenor Trombone/vib/tenortbn_vib_G#2_v1_1.wav
bdb103636849245ae16199df0266ef1f5bb3661c	981484	Brass/Tenor Trombone/vib/tenortbn_vib_G#2_v1_2.wav
8c07d36b12377e768b3a4e8d03de8f4d913239c9	943416	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A#2_v1_rr1.wav
f56faa2b68ad2d8423b051820ce6104afaa1526c	1054124	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A#2_v3_rr1.wav
c315e277948b8305d5acbb9c0555a546d30c4525	1386848	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A#3_v1_rr1.wav
501b6c74ec9dd3d76c01bab747b12117ccc54e2c	1312048	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A#3_v3_rr1.wav
c4e1f6cf2081af12dbd2f57c85b1882b5575a0d4	1438656	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A4_v1_rr1.wav
9391555a51d531dd298e7afb0ae8b6026043cf0e	895552	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_A4_v3_rr1.wav
03bbd1cd153bf117a93d5d49b0c8eaa1f05476bc	1132648	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_C3_v1_rr1.wav
3a9526c98636a9b629c99493fc9f493ad1ab27a4	1059092	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_C3_v3_rr1.wav
153fb63335248e4aaaf69f4f8a5ee1153f2bcfc8	953588	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_D#3_v1_rr1.wav
1327865c91e16194188b70ab794076649e44b80b	944328	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_D#3_v3_rr1.wav
678536700d07c4f1f641e59560620be20afb045a	1608288	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_D4_v1_rr1.wav
4f7d4d7e3464a930b79e976676e305deba4eb55b	1239300	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_D4_v3_rr1.wav
9d0e7c7cdbddd5030e0086d377e5782bc693fa85	1326540	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_F4_v1_rr1.wav
566757e99d7aa371cec3c4f8081dc1378c43f056	1222556	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_F4_v3_rr1.wav
3f2579627d5bc4d2411d40ce5e210ada07fc46a2	932212	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_G#3_v1_rr1.wav
f7820867c8299e237d3fd423c7febcc49c604cb8	1047524	Brass/Trumpet/harmonM-sus/Sum_SHTrumpet_harmonM-sus_G#3_v3_rr1.wav
bf0e95a8fd3e63f12d208a946bfcd659b407e1bc	201336	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v1_rr1.wav
199c5ac074304d2a3b0dc95a3b10cae790913396	199784	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v1_rr2.wav
2da16b369ecc935ce024f1250afc4fb2dc151eb6	218460	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v2_rr1.wav
eed06e0833c95cf381ec231b1d737e2eba82d14f	236496	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v2_rr2.wav
b7f76652558f4b2bc8065424e9e8b119859deb8d	270432	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v3_rr1.wav
df3b1287a88e26172ef1c5d83f0b12a08cf30e07	263516	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A#3_v3_rr2.wav
f37fbc8a9bec8ac95a28b359ae13f2db9d1259e5	132836	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v1_rr1.wav
1958d00def0a6e62ae72f959c1dd7773591e167d	147328	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v1_rr2.wav
24bd1d129ebf8af4b218699193be85f2d4fc0471	166660	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v2_rr1.wav
e1ade182454040684d8689235d7182d268973bc7	170764	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v2_rr2.wav
3096788299a4fdbef104a517b885d0105b7cf9ac	266432	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v3_rr1.wav
7411f2aa7ddf090f97d7477e737b70f7a8bbea9a	274396	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A2_v3_rr2.wav
4a7e8e27138b468aa8c4bdff2d14d29a73a4fdcc	261468	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v1_rr1.wav
33e4fb87dff994f4c98c5a49ecc06e91e1591cbf	215684	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v1_rr2.wav
e756e2573b1112d1c0a182ffedb71237006e8ff9	213260	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v2_rr1.wav
c0822dbc84bbecbf671165b3731b8afeccadf088	220680	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v2_rr2.wav
756e786aeabfe7b27f1b66c212ce824d5608de4e	238432	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v3_rr1.wav
816cb43dc8f09ad900246dd00a4880a3d62c310c	258296	Brass/Trumpet/stac/Sum_SHTrumpet_stac_A4_v3_rr2.wav
73bc75a68458df9dac5946665c206be58e4f4899	184244	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v1_rr1.wav
c326617e07521b04cb6df3c4cdbc040e48fcfc74	166180	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v1_rr2.wav
ab8da5c0a735702b45b8c4dada74f74abf816218	201220	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v2_rr1.wav
2e3fa81623f9d20872f3b6aab25fc423e8ea6636	206236	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v2_rr2.wav
2f50c4afc81b078ba9d67d75212d398b5115bfe6	214984	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v3_rr1.wav
a1aaf39ce40739defd53021d08e00f8f3540bd2a	233160	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C3_v3_rr2.wav
234aa7a8f29ad31675b83baaff1c135fa190c04c	292552	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v1_rr1.wav
4277f766095fe63c2348352ef9d61f83b9165366	241188	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v1_rr2.wav
864e7856744bed4c94c9d2e50b74c02b0e5d4817	156828	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v2_rr1.wav
b5b2dcabc2a1f07a81b3605f8299f3244fb865dd	262760	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v2_rr2.wav
059a10515dc4ed409dfea126cff0e0a1b46cd3a7	253728	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v3_rr1.wav
371b3c89b59fa63405e0e1e8909ae473104a3049	299412	Brass/Trumpet/stac/Sum_SHTrumpet_stac_C5_v3_rr2.wav
0daa5f3026acbb9d2e71d1e93ce7af262e211875	185364	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v1_rr1.wav
e54f1ee5338150b5ae9eb23f21adb28b1f13f427	188972	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v1_rr2.wav
a88c16c3a48afb44991c1b2d99fb1394195161f7	227856	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v2_rr1.wav
2087047717d10850a622600ca73ac34799653413	223108	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v2_rr2.wav
77d17d832af6f646de8b2cb2e2793f87e939076f	258380	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v3_rr1.wav
427677a8e7fe48b551ef171c64cfb1414a49550b	246320	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D#3_v3_rr2.wav
9362f406faf92752f69f81a3e64924850f4cb829	194672	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v1_rr1.wav
7e804b845c8db49962a83a30a30f971270f9fd3f	190316	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v1_rr2.wav
80d482935d4b79a80938c30dc6f083bfe206e9be	235968	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v2_rr1.wav
282b1bf9c727c8a755daaedcd546e9fe887a6ba8	205900	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v2_rr2.wav
f1fe8074459f0c37f6212f296f299ff4416da09c	309472	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v3_rr1.wav
87e437363c9893fbbe10a70cf9edec17bce2907f	254176	Brass/Trumpet/stac/Sum_SHTrumpet_stac_D4_v3_rr2.wav
e9f946ca06becd252fd6429ae3818c7ab215a915	153232	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v1_rr1.wav
5df204d937199917741b314de99c0b660c386c47	154136	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v1_rr2.wav
b157118ffe94338901f32ff69944dfe63be915c4	190468	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v2_rr1.wav
13ec72eb3c733b1b0a1be84d7ac76e958f7d23b4	172032	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v2_rr2.wav
845cbbe1d7ecaa358fba272dd1aea6cec12b6ad5	189328	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v3_rr1.wav
22e498b1af165faaf2ac794d7e72221a9f820056	163492	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F2_v3_rr2.wav
5265c95f043605ea4ade1d1d87f21382567519e4	208348	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v1_rr1.wav
b84b438a07e076a04fa239405afb4a0a3551da3b	228760	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v1_rr2.wav
403be9ea239d244971f7bc0130a8756c88d28640	237684	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v2_rr1.wav
48a91912f81a27d4a474a360703ff3d8c4612280	237112	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v2_rr2.wav
5b5082d93eade6e6b4307b6e0ab75fe4e27501e4	250784	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v3_rr1.wav
3e1d8c464a54b7a070d0ef7380a408fd06c5e0c9	247036	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F3_v3_rr2.wav
53a406f4412eccb96f537ad3ade778aec190af3f	212348	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v1_rr1.wav
7f646ed719647ffd08b30bf20d5a84fce8910ca6	242816	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v1_rr2.wav
2cde793a0c0b3e1657ec07b7dc03395eb39d1c84	244372	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v2_rr1.wav
01719dfe7beb254f6f16dccb8d56a906c41316c4	240208	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v2_rr2.wav
0c64406f6cfacac35e83670215fe84988eb2862d	270884	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v3_rr1.wav
e8363c0ab182b9eae55c3d79f855f67ca585b08f	266712	Brass/Trumpet/stac/Sum_SHTrumpet_stac_F4_v3_rr2.wav
daadc87e3855aed3fd479ab3bd998a9ac144670a	225752	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v1_rr1.wav
166a4fab909fc5def73d35f5c2c90e8243fa6e16	215936	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v1_rr2.wav
0b6142ebe63a7f86763391286ef44ec66f26ac7c	210292	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v2_rr1.wav
6ff7612abefebbfe086f87a843d89492b3c08d78	202652	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v2_rr2.wav
53ef5d48ac2c8263da2f6e70f73302e84e520227	226840	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v3_rr1.wav
3e581ffda8f01a633c045f7181474368f100d11f	254172	Brass/Trumpet/stac/Sum_SHTrumpet_stac_G3_v3_rr2.wav
ce2458601901f9eebd7c1fcb1eefe186cef3b2ef	1598176	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A#2_v1_rr1.wav
a0f42b26ba04a6ca0aca33bd1fe5ff02b7c0efb4	1091744	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A#2_v3_rr1.wav
463570882c895842e08f450837b53eb3e93f5080	1762772	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A#3_v1_rr1.wav
a43365376086015ef25bb0c73a622ba2dc2d9b82	1587048	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A#3_v3_rr1.wav
02eaaf077e2b21b1d20f6a3870cd7763229c2f1e	1615544	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A4_v1_rr1.wav
420cce95d3e3a60c56242c931b605c63bf2858e5	1294152	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_A4_v3_rr1.wav
93640d10bda368bddebcebef80815924203508e8	1570728	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_C3_v1_rr1.wav
bb3c6729338636cad866683ee187299c4c043d80	1239120	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_C3_v3_rr1.wav
fc10d92360e9d30c1241754fc33ca754657f024a	1634484	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_D3_v1_rr1.wav
fd7b0821e97c618d32bd65b5583a90b9b2f2017f	1698620	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_D3_v3_rr1.wav
8bd01ea443806a8b7fd3a19661ffeaa125a81fa0	1618760	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_D4_v1_rr1.wav
5a063a3589a8dd94fc17cf56c9eab9883109f5bc	1335680	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_D4_v3_rr1.wav
fb694b5a500aaa3d3acb16b04024bb0f2f6f9b66	1661876	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_F4_v1_rr1.wav
9bcc1cfb3b0c77c091c6d62e38a17e8b7a89bef9	1336624	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_F4_v3_rr1.wav
503ec6e37d1f563a85c2e93d03cb3e877d2b553a	1709908	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_G3_v1_rr1.wav
8b3be474037b6443329ecd598ebd3fed9eedc5b5	1693184	Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_G3_v3_rr1.wav
685f2d59ac73190c90384112d889083bc37a33c0	3398084	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A#3_v1_rr1.wav
f6b2753da2ae19e4748a91b0ed412decf3973fda	1667240	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A#3_v3_rr1.wav
59f4b5eadb7907b9656c5251869efa435a485c15	2100400	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A2_v1_rr1.wav
85310d01faf50dbd83ed4a65ac7bed50d97904e1	1041256	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A2_v3_rr1.wav
544285c24f712f098254f0f4677cb96e9c272081	2528080	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A4_v1_rr1.wav
bbdc0773c636c611b953ed1383f8cf1eb6b53b38	1730412	Brass/Trumpet/sus/Sum_SHTrumpet_sus_A4_v3_rr1.wav
efc0c148e06d6cf1b2c5e65efc568635e4fac38f	2677040	Brass/Trumpet/sus/Sum_SHTrumpet_sus_C3_v1_rr1.wav
d5490467cf68db010843924b975fd71edfc41273	1234136	Brass/Trumpet/sus/Sum_SHTrumpet_sus_C3_v3_rr1.wav
bff7f04cb34938be10dca3793e3bdae722f88aa2	2568220	Brass/Trumpet/sus/Sum_SHTrumpet_sus_C5_v1_rr1.wav
9e43868b7c7e47a8ee107c68c6072756ef0f6bc1	1339832	Brass/Trumpet/sus/Sum_SHTrumpet_sus_C5_v3_rr1.wav
939984455c785033eaef8d951bb3888666ce29cb	2757848	Brass/Trumpet/sus/Sum_SHTrumpet_sus_D#3_v1_rr1.wav
0b2c29a0d8744377dd839065be025a47b7bde77e	1654796	Brass/Trumpet/sus/Sum_SHTrumpet_sus_D#3_v3_rr1.wav
5270a6927aa41b90f804df59b9888449aa01a2bb	2878200	Brass/Trumpet/sus/Sum_SHTrumpet_sus_D4_v1_rr1.wav
815560ece9f2e8d0ad6a33ba24a014345ea59814	1422408	Brass/Trumpet/sus/Sum_SHTrumpet_sus_D4_v3_rr1.wav
31229c3ab9801808ee11cd278d11247b1c2ef9aa	2204420	Brass/Trumpet/sus/Sum_SHTrumpet_sus_F2_v1_rr1.wav
ee1895af491c7c332439dae630de17e1a83a4abd	980856	Brass/Trumpet/sus/Sum_SHTrumpet_sus_F2_v3_rr1.wav
c14125cf6f506ed3a5d495fee4130381d050b109	2442252	Brass/Trumpet/sus/Sum_SHTrumpet_sus_F4_v1_rr1.wav
cb508c5bf2e3c21dc3441194499fc6d0e7344f4b	1269372	Brass/Trumpet/sus/Sum_SHTrumpet_sus_F4_v3_rr1.wav
129e67aa9df78209517b461e38d8d1176a0e2861	3010072	Brass/Trumpet/sus/Sum_SHTrumpet_sus_G3_v1_rr1.wav
a301819024fe8d1fb8cdf86f9b5d0d8121c8c073	1638452	Brass/Trumpet/sus/Sum_SHTrumpet_sus_G3_v3_rr1.wav
95a9cfcd1d74f641464840f7db150bc4e6050970	1122252	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A#3_v1_rr1.wav
165691debf78d3fc3135a8c20a36cb00244fe604	926408	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A#3_v2_rr1.wav
469357481da1f36ef27f7da01e2e28afffaf451a	825976	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A2_v1_rr1.wav
c1426b74117537c0d900ee0f1a50abe9f80b826d	764780	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A2_v2_rr1.wav
51b9d3469da022896d379bd65931b5bb8aac8807	1249260	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A4_v1_rr1.wav
b114ad315de41c67c290cf1fd94e6b7bbc30ba8e	960964	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_A4_v2_rr1.wav
c824ff5e042cf2c032a471af74873e9ded31c3c7	811752	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_C3_v1_rr1.wav
316ddd83d62f71464691f55e695c9911baa74fde	824692	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_C3_v2_rr1.wav
a25b35a4a77babd99940089f0a27177e411ee1e6	1094804	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_C5_v1_rr1.wav
3647dd075a81747d559061dc15a0617e68c592da	1307068	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_C5_v2_rr1.wav
42505ac38151f9c9d1079b2a265c3dfcfcb86b17	1209520	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_D#3_v1_rr1.wav
02b6e138b28395422cf5e17ed63b274dc6e11b20	875568	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_D#3_v2_rr1.wav
add78913445e51e8e02b0bb4c24811c0cc5cb44a	994124	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_D4_v1_rr1.wav
471319f79fe64718967d3692c5b353b79aff2d81	912916	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_D4_v2_rr1.wav
a5856816674701e7ebb4e2044c28a9b27dd097a1	757128	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F2_v1_rr1.wav
a743ef5eb3b3363767d3c0d101a08ba698575b43	1048748	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F2_v2_rr1.wav
e5ec4e1cf7446cc9bdc1503b808f95e29c641130	977788	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F3_v1_rr1.wav
8d59a188e8e978e02aea926b0473af239cd72476	805084	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F3_v2_rr1.wav
7862ff26859605c3889416416edbbaca7fd5b1b7	1007616	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F4_v1_rr1.wav
7efbcf69d646e70f8ea35df190235b4ad85290eb	990092	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_F4_v2_rr1.wav
e7a06d5a23c4294d347f2048a49d595873e37b98	1269840	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_G3_v1_rr1.wav
5fd67b87a2480ec65e1f5645147f47b516afee73	854568	Brass/Trumpet/susvib/Sum_SHTrumpet_susvib_G3_v2_rr1.wav
7c22ee9e89d51c19e2930695746fa8835c35b5a4	138724	Brass/Tuba/stac/Tuba3_stac_A#0_v1_rr1_Sum.wav
6aebba2034867dbf351ba819f8b0d47a5f59a037	140460	Brass/Tuba/stac/Tuba3_stac_A#0_v1_rr2_Sum.wav
3d372755696ab7ae8733a0b6a11f8ae41e4ab5ce	160644	Brass/Tuba/stac/Tuba3_stac_A#0_v1_rr3_Sum.wav
5eb4e4daee898d7dd77115122f2b3e774c3abcac	199344	Brass/Tuba/stac/Tuba3_stac_A#0_v1_rr4_Sum.wav
a9165d8b01971e32a3185b50052d0cf34741e625	152280	Brass/Tuba/stac/Tuba3_stac_A#0_v2_rr1_Sum.wav
208f679bd7760d68a5c5dc396024122c3686fb83	134768	Brass/Tuba/stac/Tuba3_stac_A#0_v2_rr2_Sum.wav
70812126dc697dfe0f6837a485c115c07dbd638f	138668	Brass/Tuba/stac/Tuba3_stac_A#0_v2_rr3_Sum.wav
c5b28a256c0f0cf63522a7d395f12f98f63c4e2b	130636	Brass/Tuba/stac/Tuba3_stac_A#0_v2_rr4_Sum.wav
c55df0bc76a884932369b2feebbfae1d0d9ff7d5	108712	Brass/Tuba/stac/Tuba3_stac_A#1_v1_rr1_Sum.wav
86358cdb41323cc288171bb0707333481ab33c28	116448	Brass/Tuba/stac/Tuba3_stac_A#1_v1_rr2_Sum.wav
eb4b45fccfd783908e31a0adeb71153d9bef6c7c	109124	Brass/Tuba/stac/Tuba3_stac_A#1_v1_rr3_Sum.wav
b59bd238c219a7ea1048ba226604fcaf57d28bb1	107712	Brass/Tuba/stac/Tuba3_stac_A#1_v1_rr4_Sum.wav
6f9f8d7fdba8779629970e0d86da143aa08c712e	167612	Brass/Tuba/stac/Tuba3_stac_A#1_v2_rr1_Sum.wav
f9cd9ddaf2dec7d23060ac268c4913e63306b193	185664	Brass/Tuba/stac/Tuba3_stac_A#1_v2_rr2_Sum.wav
ccd37e6e9289545bc0e81ccf4289552885163681	150672	Brass/Tuba/stac/Tuba3_stac_A#1_v2_rr3_Sum.wav
677194bbc25372f1aae6360b9804f19dfa4b742d	146564	Brass/Tuba/stac/Tuba3_stac_A#1_v2_rr4_Sum.wav
cb59b84d99d0140d00ff29e5548bfc83cecb688d	132356	Brass/Tuba/stac/Tuba3_stac_A#2_v1_rr1_Sum.wav
cebcdb351a754aced1d519cacf8fd52411d5db15	184596	Brass/Tuba/stac/Tuba3_stac_A#2_v1_rr2_Sum.wav
f15c6feae5049e534b962b906713f5e0b6dbb842	128752	Brass/Tuba/stac/Tuba3_stac_A#2_v1_rr3_Sum.wav
595c830ba9f1a4b09c3b173a4b3fa69bef054665	138888	Brass/Tuba/stac/Tuba3_stac_A#2_v1_rr4_Sum.wav
6e010be66e35c4a7b1786651cf43a53c0fa71b03	137144	Brass/Tuba/stac/Tuba3_stac_A#2_v2_rr1_Sum.wav
ed320bda30a823e1e732375bfc232aa6d01c9d72	135928	Brass/Tuba/stac/Tuba3_stac_A#2_v2_rr2_Sum.wav
7fa5436ef134c1b3560ddc7de7e02c30136afc46	150036	Brass/Tuba/stac/Tuba3_stac_A#2_v2_rr3_Sum.wav
e2d8d4326461b1ffcb5a4b46a8caf2470e4af03c	136548	Brass/Tuba/stac/Tuba3_stac_A#2_v2_rr4_Sum.wav
d66d2cd35d8937b1eee12773a0c1da3de9b4e4e2	192424	Brass/Tuba/stac/Tuba3_stac_D#1_v1_rr1_Sum.wav
1d989b5ac1639d4c75b73eaa7f07e38a36dd57f7	108908	Brass/Tuba/stac/Tuba3_stac_D#1_v1_rr2_Sum.wav
0057468932632473300e01a87efbfe8285566b72	102520	Brass/Tuba/stac/Tuba3_stac_D#1_v1_rr3_Sum.wav
f86ceb2836476fff92b913c2953e583c996c1790	117888	Brass/Tuba/stac/Tuba3_stac_D#1_v1_rr4_Sum.wav
950438ecb7217d5a4a6d0c8af6d814a92ab5be0e	227256	Brass/Tuba/stac/Tuba3_stac_D#1_v2_rr1_Sum.wav
5a2c37217f7cdb9125142ab5b05dcd41a20e5be2	166056	Brass/Tuba/stac/Tuba3_stac_D#1_v2_rr2_Sum.wav
aa54df144b4bc892fe68cf6fd8519d60898b5362	173064	Brass/Tuba/stac/Tuba3_stac_D#1_v2_rr3_Sum.wav
a3d2dce8d8334444818a2c7403f0964ea3aa5122	158208	Brass/Tuba/stac/Tuba3_stac_D#1_v2_rr4_Sum.wav
acb7dfa38c0b28c0861c81d5ba39cc62dff10d8b	112364	Brass/Tuba/stac/Tuba3_stac_D2_v1_rr1_Sum.wav
35ba93540d47843324241a07706abacdacd5ea6b	125732	Brass/Tuba/stac/Tuba3_stac_D2_v1_rr2_Sum.wav
3910accd1dfeb1b104adad1ec2003adda18eecdf	120696	Brass/Tuba/stac/Tuba3_stac_D2_v1_rr3_Sum.wav
d40b01368cdb308895fa70837a2dd12e48811259	182904	Brass/Tuba/stac/Tuba3_stac_D2_v1_rr4_Sum.wav
e7dd012d9016e608fad58edccb085bba73621a33	125584	Brass/Tuba/stac/Tuba3_stac_D2_v2_rr1_Sum.wav
1ad34440024d83f6f157ef48b11eb025759ed92b	127884	Brass/Tuba/stac/Tuba3_stac_D2_v2_rr2_Sum.wav
afce238e76bb892386b1e01b28f189c913469852	129944	Brass/Tuba/stac/Tuba3_stac_D2_v2_rr3_Sum.wav
5f0bdab9f64fb9a1bfc9119b95469c24d391cbf5	122360	Brass/Tuba/stac/Tuba3_stac_D2_v2_rr4_Sum.wav
473e4c38bfa355a81ec0e5dc32ffd8e410e57685	101976	Brass/Tuba/stac/Tuba3_stac_D3_v1_rr1_Sum.wav
15e9b5504e8aaeefc39e6aca64fd397d65cb4bd8	183004	Brass/Tuba/stac/Tuba3_stac_D3_v1_rr2_Sum.wav
a4fe0f057b4ac41387bc42d4d05671d96c7786dd	103548	Brass/Tuba/stac/Tuba3_stac_D3_v1_rr3_Sum.wav
bbc908dea58926fb3d4cd6086099ad13f2eed359	168296	Brass/Tuba/stac/Tuba3_stac_D3_v1_rr4_Sum.wav
0e8fc0ae58311384c5c7caaca5ad98561d6d38c6	164920	Brass/Tuba/stac/Tuba3_stac_D3_v2_rr1_Sum.wav
f57f4f3091230086dcea90f50893b840d8774658	172440	Brass/Tuba/stac/Tuba3_stac_D3_v2_rr2_Sum.wav
b9d1d615626b0891a361fb5b6c26de6cbb3cc754	113368	Brass/Tuba/stac/Tuba3_stac_D3_v2_rr3_Sum.wav
88b69826fcd02f6c61f0bd76d4d499bfdb1cd972	133956	Brass/Tuba/stac/Tuba3_stac_D3_v2_rr4_Sum.wav
7fed15dfb84f947c91f5af42357730c3c3814cd8	146752	Brass/Tuba/stac/Tuba3_stac_F1_v1_rr1_Sum.wav
50dd08f2c697fe7d8919f62f8881b2053bff97c2	151648	Brass/Tuba/stac/Tuba3_stac_F1_v1_rr2_Sum.wav
f2eab297c859188643405eadbf19ebf470144c42	145788	Brass/Tuba/stac/Tuba3_stac_F1_v1_rr3_Sum.wav
5813a1942b1f7be98f58f75d6307208723d9ebe6	193256	Brass/Tuba/stac/Tuba3_stac_F1_v1_rr4_Sum.wav
ee1eace963e4bceaa70c84b6a0f6cbd67cfacb21	169920	Brass/Tuba/stac/Tuba3_stac_F1_v2_rr1_Sum.wav
3e2525a304ec4894d7adb477d2e8134d46b6a3b1	146916	Brass/Tuba/stac/Tuba3_stac_F1_v2_rr2_Sum.wav
30ccff6f19012dc772f805beb172f0dd7fabf2e6	215428	Brass/Tuba/stac/Tuba3_stac_F1_v2_rr3_Sum.wav
5e3664e122ad9321309f2c4476ff9de4444c908b	167888	Brass/Tuba/stac/Tuba3_stac_F1_v2_rr4_Sum.wav
26caa2ef6070cdc02df9b63a12abeceab7091099	112620	Brass/Tuba/stac/Tuba3_stac_F2_v1_rr1_Sum.wav
62aa72ff55121007112354b5b2bc9444d8793a91	106388	Brass/Tuba/stac/Tuba3_stac_F2_v1_rr2_Sum.wav
183c9dbfbe1dca134c768d6032281a3786e97dad	105828	Brass/Tuba/stac/Tuba3_stac_F2_v1_rr3_Sum.wav
84acd34a0f1758e8e98de223f95a46f67b39a647	120192	Brass/Tuba/stac/Tuba3_stac_F2_v1_rr4_Sum.wav
99f3b8910804b525fcd179c98554a2a4d9e66abb	174564	Brass/Tuba/stac/Tuba3_stac_F2_v2_rr1_Sum.wav
2810975d146076a48cef57b20af86cf350cc4f05	145616	Brass/Tuba/stac/Tuba3_stac_F2_v2_rr2_Sum.wav
3eb5962e9a77933318eae621e4d57aa141bc509f	148516	Brass/Tuba/stac/Tuba3_stac_F2_v2_rr3_Sum.wav
243e79ab51b1c72649cb9716f41c9c27132d9d5b	217192	Brass/Tuba/stac/Tuba3_stac_F2_v2_rr4_Sum.wav
fd6140ff19959967e9b333df7701ffe8da4e104e	1416512	Brass/Tuba/sus/Tuba3_sus_A#0_v1_rr1_Mid.wav
3a917152f57e9348c9dbbfaa3e072647bd76c5f7	1313980	Brass/Tuba/sus/Tuba3_sus_A#0_v2_rr1_Mid.wav
3157184d97b6811922900c6810cc808889aa5a90	712404	Brass/Tuba/sus/Tuba3_sus_A#0_v3_rr1_Mid.wav
157be46107bde96c8e821d57035ed7c037d61dfd	1750600	Brass/Tuba/sus/Tuba3_sus_A#1_v1_rr1_Mid.wav
64aaad3a1c8853c6b13138d496cba6e3e21b7276	1423172	Brass/Tuba/sus/Tuba3_sus_A#1_v2_rr1_Mid.wav
4ad920dc5600f8d5cafa85cc2ac20d000e8603c5	764660	Brass/Tuba/sus/Tuba3_sus_A#1_v3_rr1_Mid.wav
f740a33917689351ca9c9c120712ed28338810c0	1264196	Brass/Tuba/sus/Tuba3_sus_A#2_v1_rr1_Mid.wav
917db331de98546d72391faa46f6453375778397	1726720	Brass/Tuba/sus/Tuba3_sus_A#2_v2_rr1_Mid.wav
4221387eb2611cc6bf3d373ddf8a1ad5ff986a61	973392	Brass/Tuba/sus/Tuba3_sus_A#2_v3_rr1_Mid.wav
8d33af67acb2eb42166b206e957cd398761acc14	1388496	Brass/Tuba/sus/Tuba3_sus_D#1_v1_rr1_Mid.wav
05b0d63ed94c2e597e954e94560b9ee8e7734769	1125736	Brass/Tuba/sus/Tuba3_sus_D#1_v2_rr1_Mid.wav
d46fa53c16a3add22369c3c07cc965eaaf583d71	608532	Brass/Tuba/sus/Tuba3_sus_D#1_v3_rr1_Mid.wav
63d67bccd8075dae3f0e31deea03eefc27bd5fea	2237900	Brass/Tuba/sus/Tuba3_sus_D2_v1_rr1_Mid.wav
7a41908c8cfefea0f379f67857639f067f27879d	2161496	Brass/Tuba/sus/Tuba3_sus_D2_v2_rr1_Mid.wav
b44af5227c2021660757a4893398febc2897f582	803804	Brass/Tuba/sus/Tuba3_sus_D2_v3_rr1_Mid.wav
0376412b204d1bdb841d36bf4d9a1030f6b9cda0	1692716	Brass/Tuba/sus/Tuba3_sus_D3_v1_rr1_Mid.wav
37e4efffdbe853674f4e351c2b8bf74d1b11df42	701860	Brass/Tuba/sus/Tuba3_sus_F0_v1_rr1_Mid.wav
7963372deeb1e42a93f832bfd38f0691b1f8bfc1	1712028	Brass/Tuba/sus/Tuba3_sus_F1_v1_rr1_Mid.wav
f27dc8f1744b21398611c102dbfea93f16ef5683	1166700	Brass/Tuba/sus/Tuba3_sus_F1_v2_rr1_Mid.wav
73a0b9f07af11d3e2404a652e0d66c3a7c8aebab	569140	Brass/Tuba/sus/Tuba3_sus_F1_v3_rr1_Mid.wav
ae229d0882e242b64e4b3318bb5262dd8a69e199	3020752	Brass/Tuba/sus/Tuba3_sus_F2_v1_rr1_Mid.wav
21cb8dd2903fb4dc30911222417ca4168cc003c7	2065304	Brass/Tuba/sus/Tuba3_sus_F2_v2_rr1_Mid.wav
81cf9852f41b351a49ab2831f7cbb73fd283de3b	639552	Brass/Tuba/sus/Tuba3_sus_F2_v3_rr1_Mid.wav
2eac444e214af3e1997741ce5cb316b101d9cbeb	17250	CelloEns-KS.sfz
5f1b075f5adfecab3556f14a3d45890b1b7c1bfb	5637	CelloEnsPizz.sfz
5f60a7a6eb7ed8de53e60dd8145453691cb881b3	5584	CelloEnsSpic.sfz
dac0009b38effd46d19311bc5243d64be8bd1350	1617	CelloEnsSusVib-Quiet.sfz
9b34afd020314d1bfa01d5578c9b30aae9cdc603	2933	CelloEnsSusVib.sfz
263ae2dd32d6058c441d1ad4071f3d8c4fc888d0	2677	CelloEnsTrem.sfz
a0c47aa12498526ef421eb8b4c8f4258ab0b8bd7	11758	Clarinet-KS.sfz
a3dc0f0a7b304ac368a4d91d3bf7d4490e07a1e5	7495	ClarinetStac.sfz
9a8156465662cfe9c8dcf193e51e56657d036b6a	4053	ClarinetSus.sfz
063434784c7b4e7509ee0a5c02fc6d6d587f66da	18514	Contrabass-KS.sfz
b5a986aeb14818e1187de7ef7777d02c102c88d2	4696	ContrabassPizz.sfz
cf1aedaa09421a95c2b6b1abf07aa9900eb6efe1	4914	ContrabassSpic.sfz
0c84c96305e9e5d98d808ac5bd97c9e418433b1a	3296	ContrabassSusNV.sfz
2012f5460552b8f7d7381556326b71728a185ba5	1653	ContrabassSusVB-Quiet.sfz
dcea252f7f3cf2b598c3f4ab33c5a1056a17f899	3105	ContrabassSusVB.sfz
2c296a6c2164d94413c9fb5fc48235000d6b2c30	1983	ContrabassTrem.sfz
2233869b508697d0aa28762020ba9ce6656aee0b	2003	FHornMute.sfz
2ff9d9018f95e0ade0afb608e049b6e180e7617d	6263	FHornStac.sfz
8bf03e466eab3294d607b9056a229e0c9970a8d5	3250	FHornSus.sfz
56b0490e53b1b9fde9ba591d29d9052d98fed976	11392	Flute-KS.sfz
806386b65ef4f05e6a8eb66c63f42b61bce21a28	1712	FluteExpVib.sfz
5c245e5f2ecec74635986d1a1df4b071435eddb6	5546	FluteStac.sfz
804ff4f34e4be7b4f7c0b238314e80884aeadc2d	2246	FluteSusNV.sfz
abffbb200f9c2b736dd2afd20b4bb457b1cafce2	1605	FluteSusVib.sfz
766691e39502532cad2f85295168e30e6899cc5c	25687	GM-StylePerc.sfz
c9b7f41492d6df5bf0534e579b7a82891771f24a	790	Glockenspiel.sfz
31ff8d88f5e13e930d22dc1c4c95b6cfc42268a8	2475	Harp.sfz
64c35bb4f24615597882c92d4ee14f9a64d7e22e	2538	How To Install.txt
dd8d26d062b2ff776cd1cf191a791e559537565f	212	Keys/Organ/Info.txt
0f3273e6fd11feafc1ac940a21a4e3758e2d44c9	2230702	Keys/Organ/Loud/Rode_Man3Open_01.wav
80e7f33d97f47ef540f5e178e2b272b1be26715b	2206402	Keys/Organ/Loud/Rode_Man3Open_04.wav
fca6a7ac9c081fd2ecb7eab6319bd0d4f6762877	2234062	Keys/Organ/Loud/Rode_Man3Open_07.wav
67dbbbdb6f3040b8a0a03d3a52cdbd17358dcb9c	2207738	Keys/Organ/Loud/Rode_Man3Open_10.wav
0d68a094fbfbce26e0334c6286106c7aa3f468b8	2169390	Keys/Organ/Loud/Rode_Man3Open_13.wav
b9dcd8ff9b7e85a76816e148691c248afe8d1fad	2190914	Keys/Organ/Loud/Rode_Man3Open_16.wav
7f08f09b1afba404569f415040767aea84fe7038	2197326	Keys/Organ/Loud/Rode_Man3Open_19.wav
6bfaaa9813b18d839af8d025496ee3350f651470	2164554	Keys/Organ/Loud/Rode_Man3Open_22.wav
66755890efd10ee015f7972de4e3cd7c22ee3a69	2180642	Keys/Organ/Loud/Rode_Man3Open_25.wav
c77465be14701669cd9c7b33441ce94033837fd7	2159210	Keys/Organ/Loud/Rode_Man3Open_28.wav
b5573c0e706b03087e7f5d68087f0bbebffe44e2	2167714	Keys/Organ/Loud/Rode_Man3Open_31.wav
c71f73bc8a4245b05ab1b708bdb3c59d8a374731	2188610	Keys/Organ/Loud/Rode_Man3Open_34.wav
e1edb88fdb776827136e0c72cd37c1ea5f931cec	2187714	Keys/Organ/Loud/Rode_Man3Open_37.wav
2bb490a70b3ab81cc683329e6670d27e3232d7df	2138830	Keys/Organ/Loud/Rode_Man3Open_40.wav
1d5ef04f7b98a6d61dd4dc3932e7800b0f7d6aea	2119798	Keys/Organ/Loud/Rode_Man3Open_43.wav
d40f13a91325566d22347d68f551e7c2f8826d23	2129178	Keys/Organ/Loud/Rode_Man3Open_46.wav
0acea8ad636b504e970fbe6df4c434ad24fce7f3	2135622	Keys/Organ/Loud/Rode_Man3Open_49.wav
bfcab183037cf39bbf3e0c26266360b24f020b16	2117706	Keys/Organ/Loud/Rode_Man3Open_52.wav
b945af66d23632766a9662204976a99e5234d5c4	2121458	Keys/Organ/Loud/Rode_Man3Open_55.wav
e78c667910dc55b03fdcf363b9fc19fa861ef1a9	2143830	Keys/Organ/Loud/Rode_Man3Open_58.wav
a8313968e2d65d70934f1c58a4bb221bc80300e6	2099290	Keys/Organ/Loud/Rode_Man3Open_61.wav
d3147aad0d6540faf4776dcffe3a025b979be0ad	2429630	Keys/Organ/Loud/Rode_Pedal_01.wav
cf4106157d60f10778d1c44e887d4542354104af	2274842	Keys/Organ/Loud/Rode_Pedal_04.wav
53d95e89e0b0846be913865757ad9d7bde80ae91	2251954	Keys/Organ/Loud/Rode_Pedal_07.wav
422ec42821bce2771be260c7ead3bd7507a1f550	2258742	Keys/Organ/Loud/Rode_Pedal_10.wav
37d6290b8fc00af5717b406ec2926c0c6785061a	2241098	Keys/Organ/Loud/Rode_Pedal_13.wav
5421734a0876e2b486199034e9e5162c5f88c558	2239598	Keys/Organ/Loud/Rode_Pedal_16.wav
43da5afde73b4cb5d4476bad7070a3f85fe6996b	2263186	Keys/Organ/Loud/Rode_Pedal_19.wav
d913b48a16c5cb0e9eed50624dfa8459ef8739e7	2236590	Keys/Organ/Loud/Rode_Pedal_22.wav
8ada3b9bd1afc3dcce89593426a3eb715bbe5c9e	2242134	Keys/Organ/Loud/Rode_Pedal_25.wav
a1927621f0b070fffb66b9a3f64eeb2d025f5329	2194378	Keys/Organ/Loud/Rode_Pedal_28.wav
075dde813d5c8077fb22f0dfa56c0a39b5b15d83	2237926	Keys/Organ/Loud/Rode_Pedal_31.wav
674ed832a1540ba7c881fa6e8a584c4a324bdcc4	2037594	Keys/Organ/Quiet/NT5_Man3Quiet_122_rr1.wav
b697496f455adf7b1bbfbfe581836ad3970e200f	2052106	Keys/Organ/Quiet/NT5_Man3Quiet_125_rr1.wav
a10aa0b3fd0916b79eb8d402e69bb4477eaeac56	2144350	Keys/Organ/Quiet/NT5_Man3Quiet_128_rr1.wav
ede6c4c835357b7c2b66dac41cadd4d84f834a0a	2041310	Keys/Organ/Quiet/NT5_Man3Quiet_131_rr1.wav
2dc720c4f80f912ede3f3ac138b1f40e0215c450	2202602	Keys/Organ/Quiet/NT5_Man3Quiet_134_rr1.wav
001486038f749e61e625306d0a3a1166245e24fe	2289266	Keys/Organ/Quiet/NT5_Man3Quiet_137_rr1.wav
91c47ef85751aba62d6c8fb4477b19c727b9ebe2	2139942	Keys/Organ/Quiet/NT5_Man3Quiet_140_rr1.wav
56bb9953ff29a3d00d37a838389c4a94994fb0b3	2181262	Keys/Organ/Quiet/NT5_Man3Quiet_143_rr1.wav
862175f3f2ad7da84ba00509bbc63b1e72227d1a	2140890	Keys/Organ/Quiet/NT5_Man3Quiet_146_rr1.wav
298180793d259610f646b9a0a629254cb80ddfb5	2257726	Keys/Organ/Quiet/NT5_Man3Quiet_149_rr1.wav
ec0d00048c2187e2e09a3fb6f9a1a289cabb722b	2163146	Keys/Organ/Quiet/NT5_Man3Quiet_152_rr1.wav
a1c9457c57bbe4dc31ed11df59e71ab0c1e3cd0a	2141122	Keys/Organ/Quiet/NT5_Man3Quiet_155_rr1.wav
aaf898acca4946752d6ef5ddde411638fa28784d	2143034	Keys/Organ/Quiet/NT5_Man3Quiet_158_rr1.wav
62eebf2adaf965a6d73f29b3c9e2c37140b760d7	2149910	Keys/Organ/Quiet/NT5_Man3Quiet_161_rr1.wav
086356ba6c497000ab3ad5746bfe322ce68821c1	2127098	Keys/Organ/Quiet/NT5_Man3Quiet_164_rr1.wav
596cb805b62793ab61ca809983592131dac8ad70	2168318	Keys/Organ/Quiet/NT5_Man3Quiet_167_rr1.wav
9c70ecaec5c14162da761be5c089fad1075db374	2165234	Keys/Organ/Quiet/NT5_Man3Quiet_170_rr1.wav
b9cf9a97cccb82c4fcea183dd016aa9b951f5a62	2120150	Keys/Organ/Quiet/NT5_Man3Quiet_173_rr1.wav
0d2722382f3f31520f74b01d4e060fbb78435306	2069298	Keys/Organ/Quiet/NT5_Man3Quiet_176_rr1.wav
7a52a4f1288e1f6a7e595b176ee4b462aecf487e	2016978	Keys/Organ/Quiet/NT5_Man3Quiet_179_rr1.wav
4b75ea114f83eebe6fb21d4efe49a83a8f56ae01	2115962	Keys/Organ/Quiet/NT5_Man3Quiet_182_rr1.wav
1c29e3343718510e48c02a8f67b32ea426ebd529	2162458	Keys/Organ/Quiet/NT5_PedalQuiet_064_rr1.wav
27d14cf8ec96a79f923f0f4d330259e4202a5cb6	2114314	Keys/Organ/Quiet/NT5_PedalQuiet_067_rr1.wav
e7d1e967a431659277c0585ce35df5db8a01b765	2088882	Keys/Organ/Quiet/NT5_PedalQuiet_070_rr1.wav
fdd52307f65096355f41cc53c411376a8e771cf4	2061006	Keys/Organ/Quiet/NT5_PedalQuiet_073_rr1.wav
597262f717fbafa5edae2688aad00be9167d4a62	2140418	Keys/Organ/Quiet/NT5_PedalQuiet_076_rr1.wav
e02a5575a989c37d0f425c4c6780197af73050e9	2132342	Keys/Organ/Quiet/NT5_PedalQuiet_079_rr1.wav
1fb4fa1cf510b09d0ab538949b96fa1991e39fad	2096974	Keys/Organ/Quiet/NT5_PedalQuiet_082_rr1.wav
a19e1099bee8a2f1fc8f1f774c1145e6877262d8	2124458	Keys/Organ/Quiet/NT5_PedalQuiet_085_rr1.wav
cedb6e7ec8cba8903d490010bd0289604963a971	2159830	Keys/Organ/Quiet/NT5_PedalQuiet_088_rr1.wav
cd77c5ba1bbf96ac4f8afb604351455d063b4ed0	2099410	Keys/Organ/Quiet/NT5_PedalQuiet_091_rr1.wav
3755f75f6ab3f955fdb1a46112dce1d47c414eb2	2110954	Keys/Organ/Quiet/NT5_PedalQuiet_094_rr1.wav
5dba45445595148da5545ca83e889862d6fd3f56	6557114	Keys/Organ/Rode_Blower.wav
4474559e1093fb36316b90641690348e73562c53	89	Keys/Upright Nr1/Notes.txt
0c9987efda27e50babf86ed50fb335d90a96fd3d	3130978	Keys/Upright Nr1/UR1_C1_f_RR1.wav
f5f80eefd769a4b990c10322e7c93100e54f808b	3915528	Keys/Upright Nr1/UR1_C1_f_RR2.wav
d61c9698c4c1cf306b7e440ead630a6f3495680e	3392398	Keys/Upright Nr1/UR1_C1_mf_RR2.wav
cb70a3d508163e4035600cfe287e191960be76db	1331494	Keys/Upright Nr1/UR1_C1_pp_RR1.wav
345b0946181a427bb30a25730162b8c4c42c16e3	2038540	Keys/Upright Nr1/UR1_C1_pp_RR2.wav
84cd2353a68dbe43054e9edea7537c7abbceb96a	3811820	Keys/Upright Nr1/UR1_C2_f_RR1.wav
d26d4053963aee3b7f44845e2c1e5f4453470179	3751096	Keys/Upright Nr1/UR1_C2_f_RR2.wav
67c55237469793ee90fa9dd6457fd51a714f9fe1	2384234	Keys/Upright Nr1/UR1_C2_mf_RR1.wav
0b91a52c2f733f540f58e7416b96e5595bac74c0	3334902	Keys/Upright Nr1/UR1_C2_mf_RR2.wav
aad159499f633ad8f5b5f1679ffd00e8c9077085	1866674	Keys/Upright Nr1/UR1_C2_pp_RR1.wav
dacaecf9ac8913b176970684a5767557a4b7adb9	3518256	Keys/Upright Nr1/UR1_C3_f_RR1.wav
6e38823eb4928da19488391dca7601f5b87f120c	3604186	Keys/Upright Nr1/UR1_C3_f_RR2.wav
622047ce32400cd99c0193f245955e3572d85a1b	2150126	Keys/Upright Nr1/UR1_C3_mf_RR1.wav
32d8a3bcade4393952cb50bef37d8dc0eb09423e	3308386	Keys/Upright Nr1/UR1_C3_mf_RR2.wav
b9b046afcfb96255f219242cf1eaaa96c6c18435	1252962	Keys/Upright Nr1/UR1_C3_pp_RR1.wav
3605a4a7b601c273c6874dcaf4c937f21d66d1a5	1978814	Keys/Upright Nr1/UR1_C3_pp_RR2.wav
d76c049063c299b9e78587cab7600882b3de0b58	3262386	Keys/Upright Nr1/UR1_C4_f_RR1.wav
b6d78cbe89d497199d3b6f90b4badd5a8d3d88c4	3104238	Keys/Upright Nr1/UR1_C4_f_RR2.wav
99c511c4d2d3fd91b68cdf530fa043e2b03f076f	2495426	Keys/Upright Nr1/UR1_C4_mf_RR1.wav
53c637f052c5b4ddc5d975d494963fbb57b370fb	2601474	Keys/Upright Nr1/UR1_C4_mf_RR2.wav
a5a8d82859df78cfd1c4ffdedd1b9b8ac209d6d4	1948154	Keys/Upright Nr1/UR1_C4_pp_RR1.wav
7bf1428e674ebf683fc54d8cc460b539eca751e2	1175854	Keys/Upright Nr1/UR1_C4_pp_RR2.wav
aca4969e3bd81b18eae2a45ad41aee1d4c4a192d	1910466	Keys/Upright Nr1/UR1_C5_f_RR1.wav
541fc4b1b01c68642c4c3c798f948673e962f996	2461478	Keys/Upright Nr1/UR1_C5_f_RR2.wav
b0079bd7ec568998e65df839d5387fb56e264b7d	1905930	Keys/Upright Nr1/UR1_C5_mf_RR1.wav
6d052b5ff3f278fdc5763baa28e50e52bdb90533	1917910	Keys/Upright Nr1/UR1_C5_mf_RR2.wav
b18f8dd3cfc2115befe960866a646d80c5c078ee	1573878	Keys/Upright Nr1/UR1_C5_pp_RR1.wav
4c172e4285c39997bc86d066a23779b0d610eafc	1680558	Keys/Upright Nr1/UR1_C5_pp_RR2.wav
96a2005cbe74a9ccc5ac6f9ee554c5caeff65041	1184214	Keys/Upright Nr1/UR1_C6_f_RR1.wav
c7919d8e4c5a1f8faacd5d08f5bd7bb77856e9f0	1239644	Keys/Upright Nr1/UR1_C6_f_RR2.wav
2c3af039f8bcf9ead897dbb46f158fe6330088dd	1018802	Keys/Upright Nr1/UR1_C6_mf_RR1.wav
58b056f2da0b1ed5e0eabe74f9954e76d407d594	1152126	Keys/Upright Nr1/UR1_C6_mf_RR2.wav
baaa90c2bb98c0b070013aec41a953803e0adf08	1019544	Keys/Upright Nr1/UR1_C6_pp_RR1.wav
74c966e1d4dd4e7c99898f93afae0b9ed80eefbf	987228	Keys/Upright Nr1/UR1_C6_pp_RR2.wav
fad2dd6a4d9da48b3dcee5ec6383821b51128fc7	670740	Keys/Upright Nr1/UR1_C7_f_RR1.wav
9da3cb40203d57fa1324dd4f7809ca8fe633bf89	712028	Keys/Upright Nr1/UR1_C7_f_RR2.wav
bdadd24805e085c03f6f6323dd03b464dc5a9181	469466	Keys/Upright Nr1/UR1_C7_mf_RR1.wav
b46925ef19ae1cad7e08c4e9970f0fd43795436d	577034	Keys/Upright Nr1/UR1_C7_mf_RR2.wav
4c9525e1f9dd3686aa185230c303ad7fb6208371	502340	Keys/Upright Nr1/UR1_C7_pp_RR1.wav
c3ddf3ad2a6501dd4b178ec0f7e7aece6d799e37	544560	Keys/Upright Nr1/UR1_C7_pp_RR2.wav
4a53e29e43e7732d126908af820cfe1cdfdaeed2	3626534	Keys/Upright Nr1/UR1_G1_f_RR2.wav
1aca0fb64ba6c1bb477f4c46bb3a6dddf84d09f3	3191510	Keys/Upright Nr1/UR1_G1_mf_RR1.wav
2e374f75ddd77f93e319b74cfaefaf9a7d207da2	3117554	Keys/Upright Nr1/UR1_G1_mf_RR2.wav
24e7b92825f7fd78f74a6b1e62b303681d77078b	1363468	Keys/Upright Nr1/UR1_G1_pp_RR1.wav
e6fb7235a285c7ca0837c938bbfc5c430211d42a	3562426	Keys/Upright Nr1/UR1_G2_f_RR1.wav
dd147cd60acc63f5df8db18eda7a7a9437b1fdf6	4121650	Keys/Upright Nr1/UR1_G2_f_RR2.wav
7afcc4d73739bbc52ed313a0f21dae36970039b2	2429878	Keys/Upright Nr1/UR1_G2_mf_RR1.wav
85227145b6f1e208db96fefd7276c6743b137999	3614038	Keys/Upright Nr1/UR1_G2_mf_RR2.wav
06820c56e752e1e6a5f7dbe0da3bc87c9ff461a5	2302416	Keys/Upright Nr1/UR1_G2_pp_RR1.wav
0af3651b302695ed7a1ae4194f970f100c6b19ef	3996466	Keys/Upright Nr1/UR1_G3_f_RR1.wav
dfc30af7005eb230f79ee6552e891dc8f20f5984	3890306	Keys/Upright Nr1/UR1_G3_f_RR2.wav
85581601bc6c00f010fdffc7ac24ea53c4a19147	2602206	Keys/Upright Nr1/UR1_G3_mf_RR1.wav
220f0911622aaa1147176d287850cdac98bbe7ce	3785062	Keys/Upright Nr1/UR1_G3_mf_RR2.wav
33c8b7e4ecd74b38ce5d31b4ce610a01ff6dde9f	1805230	Keys/Upright Nr1/UR1_G3_pp_RR1.wav
e6e46d7f2408f049be45046a9491533a516440ba	2436286	Keys/Upright Nr1/UR1_G3_pp_RR2.wav
2df24b4e3a2e36591c8849bc6bd6b80a3412503d	2362410	Keys/Upright Nr1/UR1_G4_f_RR1.wav
7c812c4ae7ddec6912d792b32ae50bc5220740a8	2355630	Keys/Upright Nr1/UR1_G4_f_RR2.wav
b6727511ac816dd81e2e4f2dcc4d1c7b3349efcd	2240934	Keys/Upright Nr1/UR1_G4_mf_RR1.wav
4462ae852b9db9a5f4d235a8ff6475e43807678f	1854386	Keys/Upright Nr1/UR1_G4_mf_RR2.wav
d4f2fb2465ddb686035519575bdd29e684ae40f6	1840722	Keys/Upright Nr1/UR1_G4_pp_RR1.wav
a75d4b80defb68e3c88515156ebb13edaa9501d6	1680314	Keys/Upright Nr1/UR1_G4_pp_RR2.wav
da4a4d93ea16e8de93b63b4ca58a287ed0aa69f1	1538602	Keys/Upright Nr1/UR1_G5_f_RR1.wav
3325d2584bc5cb18c75369df6d5963bfff4f1b3c	1496310	Keys/Upright Nr1/UR1_G5_f_RR2.wav
b6e139fb26fa6b67ca931c5db8ad60d8beb075a8	1665486	Keys/Upright Nr1/UR1_G5_mf_RR1.wav
008654a4d88862d186796549b6f0e3f4e216211c	1468242	Keys/Upright Nr1/UR1_G5_mf_RR2.wav
d11b161a1d509ecb76953ceac32b246855268148	1531990	Keys/Upright Nr1/UR1_G5_pp_RR1.wav
dcad2002a7eda654a7e161cd1c6f99bae56c97b4	1181794	Keys/Upright Nr1/UR1_G5_pp_RR2.wav
63fc4bb1222dd4beab69adfe52077c2165ce2496	810946	Keys/Upright Nr1/UR1_G6_f_RR1.wav
6a3d8b0c7633c4f44a26b7ee5865bad2b8d10e4b	786374	Keys/Upright Nr1/UR1_G6_f_RR2.wav
81108c59a76bee0a6e890e0e110e42edd1d29aa2	860698	Keys/Upright Nr1/UR1_G6_mf_RR1.wav
1b00fb9ac0c4f067b67ea6b3588bc5254c036360	930886	Keys/Upright Nr1/UR1_G6_mf_RR2.wav
8ae8714bc743e33b428d9bed372557567f5f2564	623248	Keys/Upright Nr1/UR1_G6_pp_RR1.wav
a7c995535d9f2beba953f58272d65c81854c04a4	547342	Keys/Upright Nr1/UR1_G6_pp_RR2.wav
4bae0651e83e975c9719f7bfe2fd86a9bbb3a062	502066	Keys/Upright Nr1/UR1_G7_f_RR1.wav
0aef8cbaecefccca74645f185728a96069e8bdd6	450206	Keys/Upright Nr1/UR1_G7_f_RR2.wav
ccd334879367a96ef88f239a05a6b14167055eb1	369990	Keys/Upright Nr1/UR1_G7_mf_RR1.wav
37c98a8cd45ebf13a81453160a42350e6c51ba1a	446034	Keys/Upright Nr1/UR1_G7_mf_RR2.wav
cf38fbb2328816d7b32584667c9d189e2414e0ee	297872	Keys/Upright Nr1/UR1_G7_pp_RR1.wav
f8b5f0ba4360fa141da1509f3cf093363143bcaa	500414	Keys/Upright Nr1/UR1_G7_pp_RR2.wav
088d6fa7eaf935e2fce9ecd8b59aa08b3011e109	220	Keys/Upright Piano/Info.txt
e59ab607be6408ba065ba80f34f315c62548f879	338	Keys/Upright Piano/MappingChart.txt
3b4e10ccdd8a06971564b1d936f2516a761e7f6f	4105066	Keys/Upright Piano/Player_dyn1_rr1_000.wav
42f56b6b301fdeddce7f7076e34c4f5a03e0fea4	4109632	Keys/Upright Piano/Player_dyn1_rr1_002.wav
7cb8841df46d247a0ed9a33976277902595359a6	4128814	Keys/Upright Piano/Player_dyn1_rr1_004.wav
10e0e1c3ec485c50bf12f7e2400e8aa9364f2bc9	4063450	Keys/Upright Piano/Player_dyn1_rr1_006.wav
cb2e89a7749fc4b979512aa5da883059cd3f6ad7	5470924	Keys/Upright Piano/Player_dyn1_rr1_008.wav
2b3b3f25903ed087eb334d985a0b25f4bbd510d4	5770636	Keys/Upright Piano/Player_dyn1_rr1_010.wav
5942615eb10199382e44c0e052ebb7885b167f53	3870382	Keys/Upright Piano/Player_dyn1_rr1_012.wav
30127aa63c8342a363b9a13b8052a3428d3bb046	2270980	Keys/Upright Piano/Player_dyn1_rr1_014.wav
480e9d56f8cfaefde9be4a7f9bde2b01ac3d100f	3546940	Keys/Upright Piano/Player_dyn1_rr1_016.wav
90745e10b1d8774db29a9817a218277102cd998b	3002200	Keys/Upright Piano/Player_dyn1_rr1_018.wav
084b3f131592beecd311b309e6c5f42190653f4f	3134164	Keys/Upright Piano/Player_dyn1_rr1_020.wav
a4238a2d033e560225a1b3d9d3fa1eef9c21ac50	4126858	Keys/Upright Piano/Player_dyn1_rr1_022.wav
6350b1cf0a614fe0920ad212e807d4575fcf71bd	2222998	Keys/Upright Piano/Player_dyn1_rr1_024.wav
9a6cd6b879752f747e136ee001e7f1b78b40dc9c	3558112	Keys/Upright Piano/Player_dyn1_rr1_026.wav
c371f48ff5e5a675a0d91d0e7060e79322adfc2e	1935304	Keys/Upright Piano/Player_dyn1_rr1_028.wav
91b0fa42ec94ba1cbda1c466ae0614a59ae927e6	3120676	Keys/Upright Piano/Player_dyn1_rr1_030.wav
8ac49b49803f59cf0a712261a9e06a54edd2e6eb	1746142	Keys/Upright Piano/Player_dyn1_rr1_032.wav
629c13e5725eda851b051c525d6fe53ad5226a66	1303534	Keys/Upright Piano/Player_dyn1_rr1_034.wav
ba909286b3eefe713c484953a12bb4b2b201d4ad	1304218	Keys/Upright Piano/Player_dyn1_rr1_036.wav
18a8573978f46906530206c2b54e35750d007b70	915352	Keys/Upright Piano/Player_dyn1_rr1_038.wav
a11b447a61033b762cf757a0c3001ca99dfb1ecb	642772	Keys/Upright Piano/Player_dyn1_rr1_040.wav
b875022548b6281012e78434a784b418b67ded12	571294	Keys/Upright Piano/Player_dyn1_rr1_042.wav
b38476be1ca8cf4571d7ae71b2c562692ddc37d3	377608	Keys/Upright Piano/Player_dyn1_rr1_044.wav
6506b03a6d64c8c9b6d0050d6217bf0e65f6e364	4500238	Keys/Upright Piano/Player_dyn2_rr1_000.wav
a038b982ae1dacdb01c7e7168ae32675d32caa6d	6074254	Keys/Upright Piano/Player_dyn2_rr1_002.wav
00abb8cca2df2b97fd3d945c4fdef29259081e17	5625058	Keys/Upright Piano/Player_dyn2_rr1_004.wav
fe626910074423b0c2d9165c18468d52b2e50d2c	4936726	Keys/Upright Piano/Player_dyn2_rr1_006.wav
ab13066d1f089f86fed417c7b887d6104e573574	6862312	Keys/Upright Piano/Player_dyn2_rr1_008.wav
4e6a1acfd958682e1f3dc2ba9d42b33b73de0a98	7572904	Keys/Upright Piano/Player_dyn2_rr1_010.wav
fd035ea95dc49897c9be8627b8124b73c56221db	6306106	Keys/Upright Piano/Player_dyn2_rr1_012.wav
2f341c6fca30ac8a6ae977cf97e93538f6c1e75b	6180628	Keys/Upright Piano/Player_dyn2_rr1_014.wav
a2fc6927cb562424c17b213e4cb47353d65e9cc5	4643212	Keys/Upright Piano/Player_dyn2_rr1_016.wav
c8da939be405e5f6dd7b13b99aedfef76d5c56aa	5748202	Keys/Upright Piano/Player_dyn2_rr1_018.wav
e6027651b23024f343a8eb7823f32b49742a35fe	4346848	Keys/Upright Piano/Player_dyn2_rr1_020.wav
521353ee671854c74478c330df9195d17261193c	4476550	Keys/Upright Piano/Player_dyn2_rr1_022.wav
77f7bc50e751c377f8e3db7c88c14861395d1288	3204940	Keys/Upright Piano/Player_dyn2_rr1_024.wav
946de9950a88c228d6f764e6789efb7d0147cffa	2656870	Keys/Upright Piano/Player_dyn2_rr1_026.wav
3a9f1381ca8a1a35ac4acdbf0d954e6aeb507dea	3008866	Keys/Upright Piano/Player_dyn2_rr1_028.wav
bbc718ed37a516d761b10c4ededd14243b2ba64f	3144364	Keys/Upright Piano/Player_dyn2_rr1_030.wav
e49d0ae70c0419e9e7dfa1a6ae94acd2731b4291	2888572	Keys/Upright Piano/Player_dyn2_rr1_032.wav
48078281fd0dd839c18f0eaec19f90fb97223a35	2605408	Keys/Upright Piano/Player_dyn2_rr1_034.wav
b539c687d7f6055868ea1e3b4bac868a8ed18e21	2254930	Keys/Upright Piano/Player_dyn2_rr1_036.wav
8e410d3c45ec1dce8ff6d7ef1ffd4a2640b2a12f	1425370	Keys/Upright Piano/Player_dyn2_rr1_038.wav
7bc2a9a79148886286c946ce155b6651020ec5f7	667948	Keys/Upright Piano/Player_dyn2_rr1_040.wav
e4a96a87b47956e4d7db505b756f1f148394c30c	633034	Keys/Upright Piano/Player_dyn2_rr1_042.wav
6a629d05c65f076b4b01602b67392d9f3b699261	581164	Keys/Upright Piano/Player_dyn2_rr1_044.wav
27d53546a018acfdfd0c178bf44f0d6656d029a8	6918652	Keys/Upright Piano/Player_dyn3_rr1_000.wav
a24be261484daddfc8d1f59e9c4cffe3c5664af6	6462502	Keys/Upright Piano/Player_dyn3_rr1_002.wav
d996ff2f2dca27156d735ff799564caabb742027	6156106	Keys/Upright Piano/Player_dyn3_rr1_004.wav
54bc5bb4bc2c81e278e50b2541d5a5fb9ff65766	6210712	Keys/Upright Piano/Player_dyn3_rr1_006.wav
83838d0d84e6d96598b75f443ed221ec3cb3bbb0	7063150	Keys/Upright Piano/Player_dyn3_rr1_008.wav
250458c14cb7a095de719efdbd2728bdc3f5e9ed	6946702	Keys/Upright Piano/Player_dyn3_rr1_010.wav
e0c5fec5cc73ee8c2532c34e3385c0f5a5a3c4e0	6153220	Keys/Upright Piano/Player_dyn3_rr1_012.wav
8a860137884587939f37e8ee874081b0f535b155	5030746	Keys/Upright Piano/Player_dyn3_rr1_014.wav
48282e602945bd593f5c7d59b7ae7d1c98ca3b73	5759260	Keys/Upright Piano/Player_dyn3_rr1_016.wav
399fff7fadc9ca2c167e09dea39c2af0f8b2c386	5608348	Keys/Upright Piano/Player_dyn3_rr1_018.wav
ce3179aa6ec23de9ecd80dc5cffe2a2519ed916b	5212972	Keys/Upright Piano/Player_dyn3_rr1_020.wav
28ddbc265f8666c5032994cbb89dca46ff8c89a0	4898926	Keys/Upright Piano/Player_dyn3_rr1_022.wav
f223d77b03f9ea0874ccdf9fd5d75349e0d76391	4721116	Keys/Upright Piano/Player_dyn3_rr1_024.wav
09d29d228fdd4b1761a82f31f303e31e846bc8b0	3849658	Keys/Upright Piano/Player_dyn3_rr1_026.wav
cf1c463a5bcd85150d3ffd737a8a544d0c70c5a8	2854090	Keys/Upright Piano/Player_dyn3_rr1_028.wav
f782f10cef31ce25f78d4307aad0e81109a272c0	3738850	Keys/Upright Piano/Player_dyn3_rr1_030.wav
df159dfb166f8c52f3765fd1803c773f37f658df	3372646	Keys/Upright Piano/Player_dyn3_rr1_032.wav
4ccc1d8ab98069d20c38b0197a5e80853becb415	2808244	Keys/Upright Piano/Player_dyn3_rr1_034.wav
3eb2377f6868155b5161eab2fc013d626440e7e4	1487410	Keys/Upright Piano/Player_dyn3_rr1_036.wav
6d513d818874be2b46a1e3d59de78af080f5ed29	927712	Keys/Upright Piano/Player_dyn3_rr1_038.wav
0b836190186e816eca5c9b0bbc3cdbd3a7fd416e	725854	Keys/Upright Piano/Player_dyn3_rr1_040.wav
c0a670664148ec327664f9525b32c7b445bc029e	472108	Keys/Upright Piano/Player_dyn3_rr1_042.wav
8941d2933abd39db561777213c47eeb393d6c0ab	615094	Keys/Upright Piano/Player_dyn3_rr1_044.wav
670154e3538863b2d9891fd5483160fbdfc89164	6555	LICENSE
814cac0141c965feaad2150b61165f78ae007b49	1370	Marimba.sfz
d0abd73d7343d605696a6078d2b746ed33ad7041	6160	OboeStac.sfz
c0849ced2187f34435e7d6f33b2a1c2f2e3a6af2	2105	OboeSusNV.sfz
b6fa683b2f8a525305adea2d17ccea6b27a5b8e9	2112	OboeSusVib.sfz
adc6c67f31bd618d6cbe3c1c8be5db137c2482d9	2352	OrganLoud.sfz
18532d38f3f5881f98c3425dcfac48998de78d47	1279	OrganLoudPedal.sfz
4f4dece58649f5e85fe4506dfae6d74ab6c9c4f9	2504	OrganQuiet.sfz
c5aba1eb3094bf6450c3124cd99b70f7d74f12a6	1414	OrganQuietPedal.sfz
d1036ec300d539baad7dd5c22defa2097e17a20d	297488	Percussion/Anvil_Hit1_v1_Sum.wav
56d7a08cb2b065d37e1942e0997ac5bbeab87ce2	267524	Percussion/Anvil_Hit1_v2_Sum.wav
6f6d95fad62e97a40970ed0ea278c1dae7b31fe2	410320	Percussion/Anvil_Hit1_v3_Sum.wav
2bd179131d6b00e99f018210fe62c7443b4f4bd5	264580	Percussion/BDrumNewhit_v1_rr1_Sum.wav
d9d4aa64beb8c8cef2b8014050314c21919fb2f2	224916	Percussion/BDrumNewhit_v1_rr2_Sum.wav
90e36064984ad741962e2f033e286bc16758b46c	281616	Percussion/BDrumNewhit_v2_rr1_Sum.wav
eb9b718cd1b75df824f30ae07405ba0a111f1be7	302396	Percussion/BDrumNewhit_v2_rr2_Sum.wav
5f068b40b13f887c170d574b916dd21927f545ca	367124	Percussion/BDrumNewhit_v3_rr1_Sum.wav
92756223015f024e235dc8a0543118cf048b7e82	354580	Percussion/BDrumNewhit_v3_rr2_Sum.wav
2c50b244be4321074ce64fffcf87f8f570634f6e	539748	Percussion/BDrumNewhit_v4_rr1_Sum.wav
14c3376b3c396c8447415cb3b32aeca053322948	514224	Percussion/BDrumNewhit_v4_rr2_Sum.wav
6a3b5a0fdc56be45b6188c026b2221c31ba8ecb4	588092	Percussion/BDrumNewhit_v5_rr1_Sum.wav
cb6a7fc6201c4466ab5ea2a0bc62359a04d2ca37	614388	Percussion/BDrumNewhit_v5_rr2_Sum.wav
0bd3b2ebbebffcd253eb9b061b24677278d0b34a	947896	Percussion/BDrumNewhit_v6_rr1_Sum.wav
c8745b65f57dfd91c6421ecea49b45ac7ef0358f	933528	Percussion/BDrumNewhit_v6_rr2_Sum.wav
93ebf3571cef69c65ba1acba1d746e5bfa6c7db8	1105152	Percussion/BDrumNewhit_v7_rr1_Sum.wav
b76f283f9fffd4ad4d32689424e8562292021791	993988	Percussion/BDrumNewhit_v7_rr2_Sum.wav
4ae81aa1cee673cd7be162419b752301669a3d2d	805132	Percussion/BellTree_Stroke1_v1_Sum.wav
92c5d79bf9d21722752e84aa44e6fa50cd0af5d8	905432	Percussion/BellTree_Stroke2_v1_Sum.wav
f53deb613b09d777629df6738e0345c8783da573	1041236	Percussion/BellTree_Stroke3_v1_Sum.wav
47f3a1baab171b8465482664f518f632c8be0479	1050456	Percussion/BellTree_Stroke4_v1_Sum.wav
7a36432bb2abf6515f84d4e31f63b3c41deed911	301744	Percussion/BrakeDrum1_Hammer_v1_Sum.wav
5b69929583bd9a249c58d96d90f915985d4a1481	282756	Percussion/BrakeDrum1_Hammer_v2_Sum.wav
4131356c1cf673b71a60db39b5d6c24763f4bf06	299416	Percussion/BrakeDrum1_Hammer_v3_Sum.wav
e5a416a1a5a1b85fb57fc2c3035895a540368586	199848	Percussion/Claves1_Hit_v1_rr1_Sum.wav
5595faedc516092d8de80c3f0ddfcda79f5574c5	181976	Percussion/Claves1_Hit_v1_rr2_Sum.wav
64d31c2fa742947d83a431c266b7a18644e8d3e1	191812	Percussion/Claves1_Hit_v2_rr1_Sum.wav
9e52456881fcac88e9ff0fb69f7e3125afae0df2	187072	Percussion/Claves1_Hit_v2_rr2_Sum.wav
4d98b9b093c3ff659d4e5e6b07293199e1ab734f	228764	Percussion/Claves1_Hit_v3_rr1_Sum.wav
c2fff7edd6d9741509bae74e59b3300fceadb4c2	267012	Percussion/Claves1_Hit_v3_rr2_Sum.wav
16a927b7771ee7a512d6d6c4906aa3086bc867f2	185024	Percussion/Conga-HitN_v1_rr1_Sum.wav
669aa5ba4ab9ed96ec9632bbfff90e9e7a069744	116928	Percussion/Conga-HitN_v1_rr2_Sum.wav
9a0630a1212d56e838c98f87a8c6a68e9b4e9b9c	140012	Percussion/Conga-HitN_v2_rr1_Sum.wav
3e4fd53fc0836f0b1609b64ef090f3ed8ceecb91	131952	Percussion/Conga-HitN_v2_rr2_Sum.wav
54484187ce3db3ea58ea04e22b1afd573499230d	231124	Percussion/Conga-HitN_v3_rr1_Sum.wav
961882f2c14007f608154f482438a1eda6af6e33	178648	Percussion/Conga-HitN_v3_rr2_Sum.wav
9f3b3b8b77a96ee7b931b58968d7de4cf7ff537a	70220	Percussion/Conga-Tap1_v1_rr1_Sum.wav
0e21a502df60db672f356d90239bc071969f77e1	78116	Percussion/Conga-Tap1_v1_rr2_Sum.wav
6205a473cb35519aa78e0c38a51a53373bc2070b	141332	Percussion/Cowbell1_Hit_v1_rr1_Sum.wav
b008a5ec7abfb3e2bf35649126be89f969c89da0	137672	Percussion/Cowbell1_Hit_v1_rr2_Sum.wav
87aee4c818fc1f2030a49885fc1f24ae9f51ab06	199568	Percussion/Cowbell1_Hit_v2_rr1_Sum.wav
defbcb7b7c8f7da7d3f10429655e8a2a028a2628	177084	Percussion/Cowbell1_Hit_v2_rr2_Sum.wav
cb5e2673f32a8caf99d29ed8f35ba816a6403cd8	204528	Percussion/Cowbell1_Hit_v3_rr1_Sum.wav
061071d09fedcfc23e9666bc6de0438d2d01072e	197780	Percussion/Cowbell1_Hit_v3_rr2_Sum.wav
f1a70fd503d05df922a7a550c95c955117bb4371	195080	Percussion/Cowbell1_Hit_v4_rr1_Sum.wav
22c8d57a5c47152b10cc429a596ef315736a831a	190696	Percussion/Cowbell1_Hit_v4_rr2_Sum.wav
db079c70946137f543820b6a6ac023d0afaac47c	1271310	Percussion/Glock/glock_medium_C5.wav
c02ff721d10eb3551372806653368f45ea5dc367	1271310	Percussion/Glock/glock_medium_C6.wav
a0f4aff9ef7d73e49a16f4054ead1369a78572b0	492418	Percussion/Glock/glock_medium_C7.wav
a7d9ca6c68e4c56327d83f0653ee3e16e4810265	1271310	Percussion/Glock/glock_medium_G4.wav
dbaf80bc3975016095de3a611a202b581931311c	1226714	Percussion/Glock/glock_medium_G5.wav
e95738492bdc207b11ad32891a9a1ea090b6719e	843122	Percussion/Glock/glock_medium_G6.wav
3f2519d062438e3fc0c9b459f74cf9d2225ed149	267144	Percussion/Guiro-Fast_v1_Sum.wav
40e8806804d0dccc04f2b71cebd1d87f39fbd3f4	234316	Percussion/Guiro-Hit_v1_rr1_Sum.wav
69b162b538d75e8a3a4bf39c316acad9cd57556c	240040	Percussion/Guiro-Hit_v1_rr2_Sum.wav
13fdab8adc18f71313cf54ee0975e9f41a85acd2	331892	Percussion/Guiro-M_v1_Sum.wav
963791df3a781630cef63dbc4e6238aec40b7259	465236	Percussion/Guiro-Slow_v1_Sum.wav
4adbb9907e3ae60aaeb3b386e79f6afc58cfeeb5	262508	Percussion/LogDrumHi_MedM_v1_rr1_Sum.wav
80072cae50bdf1a7f0c691dc41a3e4c067713054	282404	Percussion/LogDrumHi_MedM_v1_rr2_Sum.wav
3a48d67c5a28429eb5bca9f4a51151a50770b0b1	272684	Percussion/LogDrumHi_MedM_v2_rr1_Sum.wav
8a0e61a2f880891775745791b6c72b567bd9b56c	260408	Percussion/LogDrumHi_MedM_v2_rr2_Sum.wav
a035863ca280bcced67a1a9519bd1a1bd0d21395	267984	Percussion/LogDrumHi_MedM_v3_rr1_Sum.wav
a6d7057447d2bffbdfd74ee1b08a6f1f00cb35ed	275784	Percussion/LogDrumHi_MedM_v3_rr2_Sum.wav
a926252a2093a6ee0630b50276e4c24087ddbf25	198684	Percussion/LogDrumLo_MedM_v1_rr1_Sum.wav
ebdbb82ac115fd696c71e890f7cfdb1a991e7556	215520	Percussion/LogDrumLo_MedM_v1_rr2_Sum.wav
5141b97b980c5316cfafe49768ec059d2a43cc2f	249240	Percussion/LogDrumLo_MedM_v2_rr1_Sum.wav
14dfb88486fdb22347ccec10ccb63173077ca25a	233724	Percussion/LogDrumLo_MedM_v2_rr2_Sum.wav
45df3307b66e64ce44c6d5a622f1009f61baca14	220864	Percussion/LogDrumLo_MedM_v3_rr1_Sum.wav
b9d34cc3569e5eb798b7c3c2ccfcbf302374f47f	234580	Percussion/LogDrumLo_MedM_v3_rr2_Sum.wav
e3b63f301191c679cea1eaa61a99d3baa9c3fbfe	1585778	Percussion/Marimba/Marimba_hit_Outrigger_B2_loud_01.wav
cf36d9cae6614613c17069accbaa46594846c113	694454	Percussion/Marimba/Marimba_hit_Outrigger_B4_loud_01.wav
155e036d3aa04fba9d3389e2cdf3accec9842e01	2236004	Percussion/Marimba/Marimba_hit_Outrigger_C2_loud_01.wav
fe3ec22b99ed4afdd007d0107d925669e7e1d4c9	1016564	Percussion/Marimba/Marimba_hit_Outrigger_C4_loud_01.wav
aa3b9670477cf7d6825cb9e6e3c9446acffa95ee	472142	Percussion/Marimba/Marimba_hit_Outrigger_C6_loud_01.wav
cc5b73c4c0b50ca64a0c484f17d37e825957de50	972392	Percussion/Marimba/Marimba_hit_Outrigger_F1_loud_01.wav
646d1490ead56eaf0db10c96ac352c80d3275736	1589876	Percussion/Marimba/Marimba_hit_Outrigger_F3_loud_01.wav
fadca10c6d332115fa9f586cc37245a008a8a859	551306	Percussion/Marimba/Marimba_hit_Outrigger_F5_loud_01.wav
b73a4b8febfdeb8e86ab13edabd1e663caebd378	1855448	Percussion/Marimba/Marimba_hit_Outrigger_G2_loud_01.wav
3c6ea81532f6924112581140e8f530e6cc45739d	800102	Percussion/Marimba/Marimba_hit_Outrigger_G4_loud_01.wav
6a49e37ad77c6c70286ae8cebc36c9a910eefbd7	117192	Percussion/Quinto-HitN_v1_rr1_Sum.wav
a1048bfbe061c24f531da0ec0a5a71158d021736	163996	Percussion/Quinto-HitN_v1_rr2_Sum.wav
707a380589cf542f53c665702a2e8d9a0e28cf79	141228	Percussion/Quinto-HitN_v2_rr1_Sum.wav
8077224a71270cb2c87b7647ee26e2f48fab80bf	155968	Percussion/Quinto-HitN_v2_rr2_Sum.wav
48363460308e5862c36aa0054d2e8cbed7e03476	207412	Percussion/Quinto-HitN_v3_rr1_Sum.wav
3e87a0fa520b9edd6dc3ce572c91648b5ffe89e6	157200	Percussion/Quinto-HitN_v3_rr2_Sum.wav
610c4e92eda908e31aa4db09121983aba7414e42	118436	Percussion/Quinto-Tap1_v1_rr1_Sum.wav
c52994b5874222a1a7197aef46dfab4876ee9344	116432	Percussion/Quinto-Tap1_v1_rr2_Sum.wav
7ff4faad0baea73e15d013edd8e05f3e18bd1150	278780	Percussion/Ratchet1-Crank_v1_rr1_Sum.wav
e59ddebd25031f132878d15157a0062320da3b11	295132	Percussion/Ratchet1-Crank_v1_rr2_Sum.wav
bf9341625590fd1583eda308ecb49ae4eed61b37	1247400	Percussion/Ratchet1-Fast_v1_rr1_Sum.wav
3a5f6054b1f232797ffc9e2ba6548fc5ae62fd3e	1579076	Percussion/Ratchet1-Slow_v1_rr1_Sum.wav
205c71fd44f04877c09f8dff4f7d2ec080380891	441104	Percussion/Sleighbells_Hit_v1_rr1_Mid.wav
d1ba80da4166150cf77d1a84062fbe2238fd4aa4	434528	Percussion/Sleighbells_Hit_v1_rr2_Mid.wav
0c81018f93ce433876c4d1e488fadd821b0d92ea	237194	Percussion/Snare2-HitNS_v1_rr1_Sum.wav
df545b00d3a0a2ff03bdf1498026d5a5bd7e0a5b	248600	Percussion/Snare2-HitNS_v1_rr2_Sum.wav
cec57ac1754fafec7a55e041afe815c4976dfcf2	243176	Percussion/Snare2-HitNS_v3_rr1_Sum.wav
114268eebacae9498974eba4172ee3cb1eedb71a	241844	Percussion/Snare2-HitNS_v3_rr2_Sum.wav
a0168bb64d2c075717920758ea52269a5df44de4	252338	Percussion/Snare2-HitNS_v5_rr1_Sum.wav
a3e21d7a07fdaf36145062e09426c79548c8c59c	222602	Percussion/Snare2-HitNS_v5_rr2_Sum.wav
e4755499367a76fbe9420eb31bb340f4f2de96e0	294740	Percussion/Snare2-HitNS_v6_rr1_Sum.wav
402324c839bcd91ae4e873162a6b9f3e3789d781	319184	Percussion/Snare2-HitNS_v6_rr2_Sum.wav
5e7829bdbca881d0124b5cae4b55733dc190cd8b	338762	Percussion/Snare2-HitSN_v1_rr1_Sum.wav
2cb682331309d6434e4eb0042ae8cdfc9f06a7f2	319736	Percussion/Snare2-HitSN_v1_rr2_Sum.wav
42b9e96ed8cc11399b12fffa7977c8e41e9c586a	457934	Percussion/Snare2-HitSN_v3_rr1_Sum.wav
df0031afe7073164604fe48982ddeb0b9dd88704	346874	Percussion/Snare2-HitSN_v3_rr2_Sum.wav
102f740d546c8f147847ea4243b7c75b6eaa3119	360722	Percussion/Snare2-HitSN_v5_rr1_Sum.wav
b449ea581cb7bb5722e7e0a07df342e2c1bd0de4	383162	Percussion/Snare2-HitSN_v5_rr2_Sum.wav
2d1c3921045d4c2d6148a9a16e764e2bfdfc6cd7	407198	Percussion/Snare2-HitSN_v7_rr1_Sum.wav
87d4aee035e4ac29ebca2787048594c059509962	387608	Percussion/Snare2-HitSN_v7_rr2_Sum.wav
c39c5e8c2acff7e954a5446603c310e238efc70d	442280	Percussion/Snare2-HitSN_v9_rr1_Sum.wav
f6564fe9bd3d498859c84e0395c3f0d97443a061	408902	Percussion/Snare2-HitSN_v9_rr2_Sum.wav
e98f1e9748f56361cca47f2f1acff1204c2fbe70	1815794	Percussion/Snare2-rollNS_v1_rr1_Sum.wav
7a94316d1c132600fe7ae05781752563e110126f	1691048	Percussion/Snare2-rollNS_v3_rr1_Sum.wav
e7934ed1018ca1cc42a24a9e7f4d4314892d2cc5	1848200	Percussion/Snare2-rollNS_v5_rr1_Sum.wav
b734eddeac719a80ce7e2964a5f6ea195e0a6d55	3104474	Percussion/Snare2-rollSN_v1_rr1_Sum.wav
7b35bdb92a6bab4856d2c3a84fce494a2d2d3e30	2946962	Percussion/Snare2-rollSN_v3_rr1_Sum.wav
bc8079c24dc9202c9603d4b5f5426e8ca68a2048	2515142	Percussion/Snare2-rollSN_v5_rr1_Sum.wav
74b15112b6aae19ca1989868b139931180777ede	268514	Percussion/Snare2-taps_v1_rr1_Sum.wav
05e92f0e10c293f685fec26088aefc7da745ece7	276758	Percussion/Snare2-taps_v1_rr2_Sum.wav
2ea5af3a1b5bb2df13923ec5e08eb982e347efbd	191420	Percussion/Snare2-taps_v2_rr1_Sum.wav
4c297219ddbefce33ae4ac19aa6024e9af1b3630	334838	Percussion/Snare2-taps_v2_rr2_Sum.wav
b14a77cfd9d9bc438e9acff4cb2c8b4e2910bd0b	287510	Percussion/Snare2-taps_v3_rr1_Sum.wav
93b9cd0b41811c1e91adbcc70329c26c5606207d	260180	Percussion/Snare2-taps_v3_rr2_Sum.wav
5d862a832bb62c53ff06348a542b0d0ef6a783f3	370508	Percussion/Snare2-taps_v4_rr1_Sum.wav
4d15b1f02121faefdfaa662a818fc2be7cf62a63	281900	Percussion/Snare2-taps_v4_rr2_Sum.wav
76efa7c6770b43a670a2cdde701ec26486af9c46	3377124	Percussion/TB_hit_C4_v4_rr1.wav
fe75a4f8ae5be638b5bb5fc575fd526674aac5a6	7439660	Percussion/TB_hit_C5_v4_rr1.wav
5415ea3d805fb047a21ef1f5dd380678df3682fd	2336976	Percussion/TB_hit_F5_v3_rr1.wav
5360b27e9e160acea82a4e705381007b0845b06c	2873324	Percussion/TB_hit_G4_v4_rr1.wav
fbddb1e497d238e85b5c5646ed2c435767ae4385	338496	Percussion/Tamb1-Hit_v1_rr1_Sum.wav
a9077c258202b6ae4065a33b93478814079065ef	290840	Percussion/Tamb1-Hit_v1_rr2_Sum.wav
de276008d59c05d274d56457931781263380f8f2	293256	Percussion/Tamb1-Hit_v2_rr1_Sum.wav
e446f1fa39898b778aae62f99e8ed51a031f6834	303536	Percussion/Tamb1-Hit_v2_rr2_Sum.wav
35e0d59936e59600e4d18b9968e4668e57014c07	1849956	Percussion/Tamb1-Roll_v1_rr1_Sum.wav
42cd417e2ddb111f3cfc47a325c8bf32fe42265a	1857924	Percussion/Tamb1-Roll_v2_rr1_Sum.wav
1831851e4cfd5d43d438ae452351a673f6aba9a1	1711720	Percussion/Tamb1-Roll_v3_rr1_Sum.wav
81fe6eb985f6aa698843375933a326f6a8134876	258948	Percussion/Tamb1-Shake_v1_rr1_Sum.wav
5257373afa17a8f8565c1df68ca511cf13935de4	237792	Percussion/Tamb1-Shake_v1_rr2_Sum.wav
a587ab55a495a0d19144d03d524031a2a16e4a57	5196524	Percussion/Timpani/Rolls/Timpani1_Roll_v3_rr1_Sum.wav
63efbcb5542a4477c4d53379583d4c7907daf90e	4263936	Percussion/Timpani/Rolls/Timpani1_Roll_v5_rr1_Sum.wav
52d693f5dd22311ffcc608ab78c7baa0d404310f	4404508	Percussion/Timpani/Rolls/Timpani2_Roll_v3_rr1_Sum.wav
7e504e4da16ba9c85b2aa7c8656d31138be5eac9	4587896	Percussion/Timpani/Rolls/Timpani2_Roll_v5_rr1_Sum.wav
89d70965a543aaf65003eaecd2668373d0f3ad6e	4340208	Percussion/Timpani/Rolls/Timpani3_Roll_v3_rr1_Sum.wav
135a2ecf726a055521fbd7fe3ea5e3a97ee47e54	3662952	Percussion/Timpani/Rolls/Timpani3_Roll_v5_rr1_Sum.wav
e0ddaca9930c5b4a184b649dcfcec265f4abfd47	3064788	Percussion/Timpani/Rolls/Timpani4_Roll_v3_rr1_Sum.wav
15ee54706de8db65b8eb7e5737a5996a4f69bda8	3570220	Percussion/Timpani/Rolls/Timpani4_Roll_v5_rr1_Sum.wav
10af1f1f0206b8099ea70db38895ed6e18a4ec88	3143844	Percussion/Timpani/Rolls/Timpani5_Roll_v3_rr1_Sum.wav
6edd78469dbff041770d9701a77196dd497218e9	2967320	Percussion/Timpani/Rolls/Timpani5_Roll_v4_rr1_Sum.wav
77c36162c32a539649022e5917e0aa764a9c081b	559976	Percussion/Timpani/Timpani1_Hit_v1_rr1_Sum.wav
525877a1eead2c5f3034b446631341f63b9ece92	542456	Percussion/Timpani/Timpani1_Hit_v1_rr2_Sum.wav
86d8e078c8820d49fd15124fe037cbd667ae8fa2	1602676	Percussion/Timpani/Timpani1_Hit_v3_rr1_Sum.wav
3e681d3622b0a6e73eef4c0411312969656f5f2c	2026620	Percussion/Timpani/Timpani1_Hit_v3_rr2_Sum.wav
0cf89f0c95be1cc91c8dea45d747bf924219b3e2	1150296	Percussion/Timpani/Timpani2_Hit_v1_rr1_Sum.wav
91f805e9cb2491d4fe897a4e1a6226974b6acdd5	1325164	Percussion/Timpani/Timpani2_Hit_v1_rr2_Sum.wav
23f38123671e904b64b45c694deec814daff98ce	1895164	Percussion/Timpani/Timpani2_Hit_v3_rr1_Sum.wav
3e2b66cceb028c6d4894d50a521cdb98f3ab01c3	1816436	Percussion/Timpani/Timpani2_Hit_v3_rr2_Sum.wav
9ea50b2bf3a7c6d438e939e348a698d93f30f1f3	1638140	Percussion/Timpani/Timpani2_Hit_v4_rr1_Sum.wav
31908758783ecec5d24643310fbca5057764ae77	1805072	Percussion/Timpani/Timpani2_Hit_v4_rr2_Sum.wav
afeffb8bc93738852c91a1fbef8f8619039f5da6	929172	Percussion/Timpani/Timpani3_Hit_v1_rr1_Sum.wav
331354ea98dc9ae7d39380b253c1ba1b1ff1ba94	1434376	Percussion/Timpani/Timpani3_Hit_v1_rr2_Sum.wav
1996b4911a0c0a0d6f8ef7e5efd823fbcc7612ff	1608252	Percussion/Timpani/Timpani3_Hit_v3_rr1_Sum.wav
f1289188398845fdd9263bf4e0808b1722e11229	1474164	Percussion/Timpani/Timpani3_Hit_v3_rr2_Sum.wav
020341b6f206e571211e240e544f2bc314215553	1813928	Percussion/Timpani/Timpani3_Hit_v4_rr1_Sum.wav
f724d0f32e5ee8dc0ed7231707843f92ab0cde0f	1844480	Percussion/Timpani/Timpani3_Hit_v4_rr2_Sum.wav
62d1f1ce105698df2395e2d46a8158eaaa01deb7	1183312	Percussion/Timpani/Timpani4_Hit_v1_rr1_Sum.wav
cbf9eeae44051eaf9900eff7802bf7ed6cd025f2	751128	Percussion/Timpani/Timpani4_Hit_v1_rr2_Sum.wav
198b2582307137805b0fccef4e7eb71a4398e953	1012976	Percussion/Timpani/Timpani4_Hit_v3_rr1_Sum.wav
f6b877fdbaf6ff5236d3a9eb2f2c6781becfe155	1278328	Percussion/Timpani/Timpani4_Hit_v3_rr2_Sum.wav
e677f48530d9715c1e8ebbd35e1795de9e7ea207	1599356	Percussion/Timpani/Timpani4_Hit_v4_rr1_Sum.wav
9188167f8360c03538b757fa5c7801d39355323f	1765536	Percussion/Timpani/Timpani4_Hit_v4_rr2_Sum.wav
dd17dd4aea5781b0761a6461e16459a66f057354	327568	Percussion/Timpani/Timpani5_Hit_v1_rr1_Sum.wav
18fce5347cb112c40026c885a808f0d5383bc1b3	262192	Percussion/Timpani/Timpani5_Hit_v1_rr2_Sum.wav
52b8d8441ff31e3870572cdbba0ae317c201bfe9	1036528	Percussion/Timpani/Timpani5_Hit_v3_rr1_Sum.wav
4f2eeb4ba6dc3547684c5d36106e5a0d9b97eba5	986304	Percussion/Timpani/Timpani5_Hit_v3_rr2_Sum.wav
5de0226ebb7e3b4a343b23e71517147aa5102f2e	1213880	Percussion/Timpani/Timpani5_Hit_v4_rr1_Sum.wav
c9bc3ccf75025ad7f907d833a1d1d417a945a5b3	1141072	Percussion/Timpani/Timpani5_Hit_v4_rr2_Sum.wav
e7e6c32d6910c46b270af65c875321d299bbd014	144464	Percussion/Triangle3-HitFM_v1_rr1_Sum.wav
84d50a81d3d9cb47010b456a0c2e383bc13804ae	149440	Percussion/Triangle3-HitFM_v1_rr2_Sum.wav
b87e2319630ba9e94e04fe619cea400ca04028d2	151872	Percussion/Triangle3-HitFM_v2_rr1_Sum.wav
91e6d8f389c9529524def378709cfd6e438a12e5	214420	Percussion/Triangle3-HitFM_v2_rr2_Sum.wav
29e1072c90f16d54475bc68c07e86eddb1a4809c	266320	Percussion/Triangle3-HitM_v1_rr1_Sum.wav
cb334a1b9c2542a2917febf47b2f3ae2a285a643	256964	Percussion/Triangle3-HitM_v1_rr2_Sum.wav
71c85cf983af922220fc91bfea289a6b0a6cb922	223540	Percussion/Triangle3-HitM_v2_rr1_Sum.wav
e6e5b96b2000459f6227d02ae022088dbab5a1ef	218404	Percussion/Triangle3-HitM_v2_rr2_Sum.wav
d65c289803375e669cf73aefec295a6fa22c7d51	1482680	Percussion/Triangle3-Hit_v1_rr1_Sum.wav
f5b9c03b11423e8473438dc312769c65d71e9dfe	1251436	Percussion/Triangle3-Hit_v1_rr2_Sum.wav
d10404330f27f4611b4ea5a3dd87c5fe8d877a25	2098660	Percussion/Triangle3-Hit_v2_rr1_Sum.wav
2709e6fc6a55c35a0d3f9438103f7525cb856d92	1857796	Percussion/Triangle3-Hit_v2_rr2_Sum.wav
78357eb727c1930665db0b5f61ad69fe81e721c0	6946852	Percussion/Triangle3-Roll_v2_rr1_Sum.wav
3cf72070b1708e8686e205571469d9ba6cd2d135	289516	Percussion/Triangle6-HitFM_v1_rr1_Sum.wav
602602276aac4c25f3ec8461fa80110c771be29e	179016	Percussion/Triangle6-HitFM_v1_rr2_Sum.wav
98c6987bd730a0c1941406f427592174d3d5f115	179828	Percussion/Triangle6-HitFM_v2_rr1_Sum.wav
e25bcf4676235b69b62f417f685d047f42b08a8c	170492	Percussion/Triangle6-HitFM_v2_rr2_Sum.wav
cddcb0e888d79d1152aa2242fa8bebd29618b60f	226940	Percussion/Triangle6-HitM_v1_rr1_Sum.wav
0f711583ba8f16a28ba6b2c5529c6cb68aab8a18	180072	Percussion/Triangle6-HitM_v1_rr2_Sum.wav
831740fd20fc81985744255912afd17688eb4d27	189804	Percussion/Triangle6-HitM_v2_rr1_Sum.wav
9b202202a8b7b8795cf5c2b348391fe1f11082fe	182436	Percussion/Triangle6-HitM_v2_rr2_Sum.wav
301d5f4d46a8894b6ca74fd0b7675ad003428d47	286328	Percussion/Triangle6-Hit_v1_rr1_Sum.wav
d7656983cbd590493494c2bd8dbe72845eab4bff	473052	Percussion/Triangle6-Hit_v1_rr2_Sum.wav
e400b815b70b7138a0ca059e5cf752afa3ea489b	421700	Percussion/Triangle6-Hit_v2_rr1_Sum.wav
370781a9e647c5bd3e9d6ccd78f2cbf9cd1ce4c2	376700	Percussion/Triangle6-Hit_v2_rr2_Sum.wav
4e75fdf4b07d874a234165521c876b4da8bc6fc4	4052780	Percussion/Triangle6-Roll_v2_rr1_Sum.wav
27be5474b92270d079d8a7323b99ae5b41b530f2	124652	Percussion/Tumba-HitN_v1_rr1_Sum.wav
9c83c8c30ea107c53414a4988b65997c1670aee6	123428	Percussion/Tumba-HitN_v1_rr2_Sum.wav
8f54617d22b01eae35d3374b8eb662c0d3c6a284	149288	Percussion/Tumba-HitN_v2_rr1_Sum.wav
0616640b03e7884ce67a73d031ddeeb27e419a2b	126616	Percussion/Tumba-HitN_v2_rr2_Sum.wav
5fafad3fe5a0047c692b9af14333335f29e9e3db	129160	Percussion/Tumba-HitN_v3_rr1_Sum.wav
c6e4fd93daca6b8e4c34e65da2c94bf44b8fe2cc	120668	Percussion/Tumba-HitN_v3_rr2_Sum.wav
8ce0ffbb53503af161bbedb39797b025b9e7059c	89768	Percussion/Tumba-Tap1_v1_rr1_Sum.wav
8de599ee7b5787194c6a9a4305d6d8e6233dd6df	87012	Percussion/Tumba-Tap1_v1_rr2_Sum.wav
af5c4ea6431fc38aa5049cd202dde9e58102e6b7	897126	Percussion/Xylo/Xylo_Medium_C4_ff_01_far.wav
f8bd2232bc174009e2a4e1a531e879e8cbd74199	504372	Percussion/Xylo/Xylo_Medium_C5_ff_01_far.wav
b947a33529eb125a762090fc368b1942a4e3aa72	393930	Percussion/Xylo/Xylo_Medium_C6_ff_01_far.wav
d44013498ae967ea9998cb03bac8b59f461865ed	306732	Percussion/Xylo/Xylo_Medium_C7_ff_01_far.wav
0ebb689b682277fdbcde0a3c76b9b1e197ef29fa	963174	Percussion/Xylo/Xylo_Medium_G3_ff_01_far.wav
dd8e753fbd1a67efa83049e7b226ddabc5644720	669186	Percussion/Xylo/Xylo_Medium_G4_ff_01_far.wav
7183664e7583871c9221e3b0c40a324a265706f7	432828	Percussion/Xylo/Xylo_Medium_G5_ff_01_far.wav
911cb8efac1a84a05d071a04ff35d6b3b087e313	371682	Percussion/Xylo/Xylo_Medium_G6_ff_01_far.wav
39205852f19e3f52862a6493db86b73a3acad8b2	568832	Percussion/alien1_ff.wav
c70827adf04224b15b5032535ae31f95ae99e647	609460	Percussion/alien1_pp.wav
96373ea0240fb56686e1876c0080ecfa32f0aeb3	550364	Percussion/alien2_f.wav
a1d125cc70f36f5e06c5165783a5c77e681daa1f	904702	Percussion/alien3_f.wav
01557129aaecf0cea4fc6fe4552facce18543956	813882	Percussion/bassdrum_rub1_v1.wav
5cc885750b233e211890144caf21fc878146aca0	1974098	Percussion/bassdrum_rub2_v1.wav
022b7d822397e9b2a8a445bfdeab1a427def2055	1707150	Percussion/bassdrum_rub3_v1.wav
d2202ea8a1c18c0baec92dc7ebac4513d8c984b7	1295130	Percussion/bassdrum_rub4_v1.wav
2c25cd11c6f8d8c1dbec501fd1c693aa6739c1fa	1772758	Percussion/cymbal-crash1_ff_rr1.wav
00eecfab16c3bab05a5b84b8671316b76013da0a	2344542	Percussion/cymbal-crash1_ff_rr2.wav
32bdfa92238d510fcd2cbe0f390e3540060146a1	1495666	Percussion/cymbal-crash1_mf_rr1.wav
a932ee40e4c87c70637d6e5da5b63d117bf59ce1	1703922	Percussion/cymbal-crash1_mf_rr2.wav
41338062a3c8c9510959464334b38bbdcdfd1677	1253390	Percussion/cymbal-crash1_mp_rr1.wav
b1d1bef7ed3bc13409354542640c76019971b8a2	1416522	Percussion/cymbal-crash1_mp_rr2.wav
0cb2c3c0cd7dd5d7c642781f0011730debc7336b	1646510	Percussion/cymbal-crash1_pp_rr1.wav
c20e2bdb7dfc0d808c7d259f66a3127d262ba4b2	1508818	Percussion/cymbal-crash1_pp_rr2.wav
3ee85753be6fec03f97da3e67206ac502902f772	335222	Percussion/cymbal-crashshort_v1.wav
fb946327a07e2ab62722c981a09f25f81f7c2be7	5433094	Percussion/gongHit_f.wav
2c188f201871e088c649fbf5701f8ae2d7fa2c73	4822774	Percussion/gongHit_fff.wav
6e90170966e0955ff362264468e4e8db3f921837	5998418	Percussion/gongHit_mf.wav
f0cb216bfd67097784a19e303c0ae48e45eea58b	5190066	Percussion/gongHit_p.wav
77c8f7da3ff9865dd3be1ffb5e010b47b0d41f1b	1687894	Percussion/gongscrape_mf.wav
f4fb6510b5564b6ebbab12dada93b58484b537be	937078	Percussion/gongscrape_pp.wav
75e969385f977894570710348400f52fc4cf0bb5	2873478	Percussion/susCymb1-bow-1.wav
18e65afc77a932183e3eccab7f72bcaa76abfd7b	465474	Percussion/susCymb1-bow-2.wav
fa55b466875ed2c90f2a77786c641445c3bb41a2	2021598	Percussion/susCymb1-bow-3.wav
7b506ff5a718b05714d7d8a50c9964aa3363e3a6	1372438	Percussion/susCymb1-bow-4.wav
f1f88a207d2e40c7a7409d26de99c68acebbc00b	2991302	Percussion/susCymb1-cresc-Long_v1.wav
0e1de2b7a87d8873f177e123c6bb74436a236c0c	2291710	Percussion/susCymb1-cresc-Median_v1.wav
02778411d215601a2de99ac1a7210cc9a5eb32e6	2121550	Percussion/susCymb1-cresc-Short_v1.wav
103cfc469b1ef5533e5d2f3e458241dfd0043345	748994	Percussion/susCymb1-hit-bell_fff.wav
3eee09cfd9268cf7a5b867ae08ea1e7df8735bb9	1279550	Percussion/susCymb1-hit-bell_mf.wav
1d07e2596fd7efc7d9117cf64ef2afb3ea4ef488	1300206	Percussion/susCymb1-hit-bell_pp.wav
106a43a794c18fc88b4257c2b67a0bbcecf94607	2046894	Percussion/susCymb1-hit_f_rr1.wav
512840ed3e0cdb1d4781c4e89553b4c356576a9d	1973930	Percussion/susCymb1-hit_f_rr2.wav
b073dd7e3a6f871e0d550fc55d829a7158570a45	2285114	Percussion/susCymb1-hit_fff_rr1.wav
2a4d9cfbd594f9f61b58433f431c2663537a1d66	2505682	Percussion/susCymb1-hit_fff_rr2.wav
1a66cc768a4595533aab424baf00fddfa316cfb9	1981318	Percussion/susCymb1-hit_mp_rr1.wav
30baee15b122e70615ccea373b76678ddb3d7f9d	2341806	Percussion/susCymb1-hit_mp_rr2.wav
c5cf725246c8d8c6550a7f5948d7eeafbcf9c2ea	1844706	Percussion/susCymb1-hit_pp_rr1.wav
e3b97f828ad9ea190ec86b56543c4ae67de867ef	2233986	Percussion/susCymb1-hit_pp_rr2.wav
4529eca8c2b92f1b377b1eb0f55985152b245642	1213358	Percussion/susCymb1-hitstick_f_rr1.wav
0c6f31588f8567564503f8bdd398bd4eb991391e	1598894	Percussion/susCymb1-hitstick_f_rr2.wav
b7cf8e1d670cfffdf3b470d75fdd31663a700ca9	2055786	Percussion/susCymb1-hitstick_fff_rr1.wav
fee20fcfda7d6e5094a457dceb138e912cb6e185	1975606	Percussion/susCymb1-hitstick_fff_rr2.wav
22733b4388f26829d94de380711792f7a56ab4da	1399926	Percussion/susCymb1-hitstick_mp_rr1.wav
35dd0248163a1c21d397d068a0b37c3b63d0ef76	1550114	Percussion/susCymb1-hitstick_mp_rr2.wav
012211003ea58fa9075c356592ead89e937ab96b	1152978	Percussion/susCymb1-hitstick_pp_rr1.wav
e467abd94445d3350b9d4f653922dfb6e757e39d	1126182	Percussion/susCymb1-hitstick_pp_rr2.wav
8c32d4c14ae56c40b9bc603c753d7552260fc914	1332450	Percussion/susCymb1-scrape1_v1.wav
c91f100b66d4a6d388f2883bd01d455166afce00	1609258	Percussion/susCymb1-scrape2_v1.wav
2e2cd080df174cbed3fd14143f84e65c23c71d9a	407200	Percussion/timp-snare_f.wav
7e90766c21155d69563750a9c5950acddc01eeb7	234300	Percussion/timpsnare_mf.wav
6bb17921f3179da4a1bdf6b3abd9b1373a0f111c	133904	Percussion/timpsnare_pp.wav
dafe17bc6cccb0df4e9d1984cf0fde5131ae64c9	139484	Percussion/timpsnare_ppp.wav
fc11547809ee0fa2a31ed5065ab6bd8ba6faa786	78128	Percussion/timpsnaretenor_f.wav
b2d8b45a2b5b2a532d9f0117e4faf0bbd9ae35d1	200832	Percussion/timpsnaretenor_ff.wav
a4cd82b604aa6e9479aa21fb732abd590792deaa	206408	Percussion/timpsnaretenor_fff.wav
54c501f0aefdda2a210ed430f348184bd5bef2c7	295648	Percussion/vibraring_v1_rr1.wav
fd380c40c40a718b5617878f96af13c82226f2bf	423932	Percussion/vibraring_v1_rr2.wav
5a22c0560678c4d3805e46e10a9c17093ed1212c	322184	Percussion/zap1_v1.wav
66be1571432c93eab37d7ed5d2f8adeff36f1e75	362448	Percussion/zap2_v1.wav
ec71a10d16adc5192a7f631858038b1faebf681e	432000	Percussion/zap3_v1.wav
ea6ac9e837bce74fe301ad610b6a538985a491a0	424684	Percussion/zap4_v1.wav
0976f12c64c8939ac6e395834a6c74347722835e	727	PiccoloStac.sfz
0ead0f7c1430703bd3d914730c7550b88c63a3d5	720	PiccoloSus.sfz
b7a1941bcb77561148bd6abea2dfceb6e2edf9c2	1883	Readme.txt
2ae7d22de9a87ee6c902819c91a74bcd9cdfb9ab	18637	SViolin-KS.sfz
b1830d900cfe50aabc2a31d5fd0c821831c1002a	4973	SViolinPizz.sfz
a04d077361f034474a32b71504edc1c987655400	6754	SViolinSpic.sfz
490f1bee2146468b66456889a664a0081d2350b8	3126	SViolinTrem.sfz
fb3d0013c6da16aca9659b5e5a6dac384ba5c289	1788	SViolinVib-Quiet.sfz
62f7c4503996bd8b16c8268fdb8c4f0ced793660	3366	SViolinVib.sfz
3e1fec71b531697030215d70a51889260324a225	763418	Strings/Cello Section/pizzT/pizzT_A2_v1_RR1.wav
2f0d3adf6cad8227f6c340d71a9b5597dfa6f319	714926	Strings/Cello Section/pizzT/pizzT_A2_v1_RR2.wav
72e0f0d5d328ff59c7b0227a451c1a226b892265	748484	Strings/Cello Section/pizzT/pizzT_A2_v2_RR1.wav
fa1956ce30140cf95d335c16a5d8986b53751c8e	757718	Strings/Cello Section/pizzT/pizzT_A2_v2_RR2.wav
a77d940699042d211e6e329d2331d95ca76842c8	890366	Strings/Cello Section/pizzT/pizzT_B1_v1_RR1.wav
2ac3786f8de7fa92086cf2620d4acf0be60c0ae9	1005728	Strings/Cello Section/pizzT/pizzT_B1_v1_RR2.wav
4a241c20bb2cb76be13837019363537e85851f40	1058144	Strings/Cello Section/pizzT/pizzT_B1_v2_RR1.wav
7792131afbc5bdc2e2e85ca070954a72239ef523	851390	Strings/Cello Section/pizzT/pizzT_B1_v2_RR2.wav
9beeb61bac3f90a6031fc44df73203dca0128518	637034	Strings/Cello Section/pizzT/pizzT_B3_v1_RR1.wav
c2336fd8d3a7f7d9267b0ec5124d6b7c2295522f	462368	Strings/Cello Section/pizzT/pizzT_B3_v1_RR2.wav
37e30848e2c86eeb1a7fd6f704fc33b23c4afa4b	528038	Strings/Cello Section/pizzT/pizzT_B3_v2_RR1.wav
344e9c73227fb784fa182a14ad266c4ba9bf5398	498176	Strings/Cello Section/pizzT/pizzT_B3_v2_RR2.wav
c075a85b166054bbb9d1f900393a76f05f10a8b1	829634	Strings/Cello Section/pizzT/pizzT_C1_v1_RR1.wav
ab41bf7563e84434f5babc50dda270e92fdb89d2	858296	Strings/Cello Section/pizzT/pizzT_C1_v1_RR2.wav
e863415fcc1daf43bb56c7ad2990774f66c1cb98	981176	Strings/Cello Section/pizzT/pizzT_C1_v2_RR1.wav
a6030389c8d46bdbfdcb9954de2db56972743873	886544	Strings/Cello Section/pizzT/pizzT_C1_v2_RR2.wav
0e8a8a7eadd8ea2b5f009f70fd4b1c2e325ec137	704396	Strings/Cello Section/pizzT/pizzT_C3_v1_RR1.wav
5f02b7ab2afbf1825bfef67c4b24516fa2136c0c	668192	Strings/Cello Section/pizzT/pizzT_C3_v1_RR2.wav
a0a21bf7abdff541715f3c49df50ca0a3b5ef0f7	762122	Strings/Cello Section/pizzT/pizzT_C3_v2_RR1.wav
0f4fb38d9ece8c7ce5f2176b184c7695ff715540	717008	Strings/Cello Section/pizzT/pizzT_C3_v2_RR2.wav
602ef076ef3e60774a7a9d99450fbceaa7f4d24b	723014	Strings/Cello Section/pizzT/pizzT_D2_v1_RR1.wav
896b65e4cff10b895f49ecf50d3eb12bde14f341	769676	Strings/Cello Section/pizzT/pizzT_D2_v1_RR2.wav
55891f1ec98c1742b27e0b7565c0ef2f027e9bbc	770222	Strings/Cello Section/pizzT/pizzT_D2_v2_RR1.wav
15d9901c6962456d98fa7e435e485df07bd39e3e	686930	Strings/Cello Section/pizzT/pizzT_D2_v2_RR2.wav
d431933dfc477cab274a7ba5e17bbad5ab68f768	246806	Strings/Cello Section/pizzT/pizzT_D4_v1_RR1.wav
1f45b6a4eff699b0104c9ad0461f1cb493f93926	443942	Strings/Cello Section/pizzT/pizzT_D4_v1_RR2.wav
d8b97e0669415235b2d28ed65f247430264cc847	345608	Strings/Cello Section/pizzT/pizzT_D4_v2_RR1.wav
c4e580cdb994d107d7cc292e0c69e4cc7d7556b4	264272	Strings/Cello Section/pizzT/pizzT_D4_v2_RR2.wav
9678586affff8ef2973ef9da03259ba0132d1b67	842720	Strings/Cello Section/pizzT/pizzT_E1_v1_RR1.wav
9a4a5b9bd741c22fbd2646eed0bf48f839c8445d	688292	Strings/Cello Section/pizzT/pizzT_E1_v1_RR2.wav
7e8f2ebee318b74e00763e877c7da474511e3341	826130	Strings/Cello Section/pizzT/pizzT_E1_v2_RR1.wav
0031262b33fb7a612eab5f7e42b7737600275eca	1005260	Strings/Cello Section/pizzT/pizzT_E1_v2_RR2.wav
e25e4b7b69df776d59a8e66ce3c3203f02ca3b59	512792	Strings/Cello Section/pizzT/pizzT_E3_v1_RR1.wav
a24e7e2f05f7aa3073c8ef0f641eadf33a1f7fed	550814	Strings/Cello Section/pizzT/pizzT_E3_v1_RR2.wav
81e7e715c82c068767246b948aa5720bdacd61ba	613436	Strings/Cello Section/pizzT/pizzT_E3_v2_RR1.wav
3079bc3db63fa205a7e7beef171611877d1abc8b	642656	Strings/Cello Section/pizzT/pizzT_E3_v2_RR2.wav
65b06f53a4d2c449f38b30a22aeea6bf1ce814af	662600	Strings/Cello Section/pizzT/pizzT_F2_v1_RR1.wav
69b5bd25c32e439c69df8ce0623d767bcc98fd08	446198	Strings/Cello Section/pizzT/pizzT_F2_v1_RR2.wav
20c6e50e4f6e6d4e677a66989de22ebe44af9707	479312	Strings/Cello Section/pizzT/pizzT_F2_v2_RR1.wav
d172b1efd4ed288c0be128c1360583756a5d04bd	537716	Strings/Cello Section/pizzT/pizzT_F2_v2_RR2.wav
24895de3e0d59db4ba2f2905777d1d4cb1f3242f	231038	Strings/Cello Section/pizzT/pizzT_F4_v1_RR1.wav
ece05cdbcb43e57d592e819806fe323395b68666	241640	Strings/Cello Section/pizzT/pizzT_F4_v1_RR2.wav
5a5d41fbab07b45e1c15f8332ad3a9be98d9087c	267632	Strings/Cello Section/pizzT/pizzT_F4_v2_RR1.wav
3103fe64aa82efa50834f8060e6f869c70e74786	346466	Strings/Cello Section/pizzT/pizzT_F4_v2_RR2.wav
7a2e62d4053cf9d0260ededbe1b97b1963cdd1e0	852008	Strings/Cello Section/pizzT/pizzT_G1_v1_RR1.wav
1f424612f211f3360db750f4f1cbd5c7c25b6812	718130	Strings/Cello Section/pizzT/pizzT_G1_v1_RR2.wav
9e6b7510899020e0deffdf7cd84ebc207057ec27	884180	Strings/Cello Section/pizzT/pizzT_G1_v2_RR1.wav
dc1935483eda7148f8db4cc3b62d0f6dce23a4d6	977798	Strings/Cello Section/pizzT/pizzT_G1_v2_RR2.wav
3e51a603e5395b476a41ebdcf91e2b6902fe5bfd	746396	Strings/Cello Section/pizzT/pizzT_G3_v1_RR1.wav
11b3dbf3c78e4ba6138d74a7001731d26f448a65	719588	Strings/Cello Section/pizzT/pizzT_G3_v1_RR2.wav
2aee48b5212697b6c897260d25c3ad31f6b8e8aa	720596	Strings/Cello Section/pizzT/pizzT_G3_v2_RR1.wav
b9ff26a22c79a87e0967bea0a871c9c4dfd12b69	762104	Strings/Cello Section/pizzT/pizzT_G3_v2_RR2.wav
01ed4d069a05a5077d0744c08db9af7c152702a6	421418	Strings/Cello Section/spic/spic_A2_v1_RR1.wav
5ab7f2a2748a9c2c5544339393e04e2a15a12405	356546	Strings/Cello Section/spic/spic_A2_v1_RR2.wav
6023bf05728d62289c152b3deb52f0e194dbf146	893588	Strings/Cello Section/spic/spic_A2_v2_RR1.wav
6cf453f636aec69acaf3a67540560a6fb1b3a0c3	871292	Strings/Cello Section/spic/spic_A2_v2_RR2.wav
fdecb0155c8203ab685159463ed1bd64f853e98f	460220	Strings/Cello Section/spic/spic_B1_v1_RR1.wav
6e4aec99a9c0d7ae0304e9074f9892fd038c28e1	503720	Strings/Cello Section/spic/spic_B1_v1_RR2.wav
7ea6d7230a2c6c29cd6750c9ff3357edb6621ee5	476396	Strings/Cello Section/spic/spic_B1_v2_RR1.wav
3e68292dfe615f66e42cb2da40486beec4675e80	527474	Strings/Cello Section/spic/spic_B1_v2_RR2.wav
5ad1734300412278953e53b4003cb46c6dd2c81c	404822	Strings/Cello Section/spic/spic_B3_v1_RR1.wav
c5710589c9a29deb66f170d97893bca670c34ab0	368342	Strings/Cello Section/spic/spic_B3_v1_RR2.wav
15154d7fc1daef5b3a64ae37fe131a07c0264d92	606824	Strings/Cello Section/spic/spic_B3_v2_RR1.wav
aee9180f6955adcbb3a616772a53ef898824cb81	595766	Strings/Cello Section/spic/spic_B3_v2_RR2.wav
6a4fa67a26dd26715083cfd79967695edac31e06	825956	Strings/Cello Section/spic/spic_C1_v1_RR1.wav
4a586d8c0a6238a46b5d349316add9f2a02c03e9	851288	Strings/Cello Section/spic/spic_C1_v1_RR2.wav
a8bd5d4e51a6c38c7ce1949cd1b50850eecb51e6	853964	Strings/Cello Section/spic/spic_C1_v2_RR1.wav
4ac53906d49989bb98b5c0deb549e1f2c33c9dea	926798	Strings/Cello Section/spic/spic_C1_v2_RR2.wav
cc9f933429d125d89238c28baa48ff64819563d0	399308	Strings/Cello Section/spic/spic_C3_v1_RR1.wav
d2ca393681c67a3f8de9a6a332ae253396f50350	443348	Strings/Cello Section/spic/spic_C3_v1_RR2.wav
44110289cbce539a41aabc50f6d48a665f563198	536360	Strings/Cello Section/spic/spic_C3_v2_RR1.wav
ca63b74ef7bff88e4ed632f6032ead210f562079	764744	Strings/Cello Section/spic/spic_C3_v2_RR2.wav
d5424a07cdfa0213020f9d9b042baf25adca8e93	394016	Strings/Cello Section/spic/spic_D2_v1_RR1.wav
2257d013d9bef0761c28418069e69a95b7601486	371936	Strings/Cello Section/spic/spic_D2_v1_RR2.wav
feaa6ecee38e4b5dd478aaf88c2cb1264cc45c4c	896108	Strings/Cello Section/spic/spic_D2_v2_RR1.wav
7566f8e267570edcdcf2e1b8069b4e30baaef610	783068	Strings/Cello Section/spic/spic_D2_v2_RR2.wav
ce1cadfcdfe3929b5990b51f3b5afa446d5c3df6	344240	Strings/Cello Section/spic/spic_D4_v1_RR1.wav
f75159a874b88ba43971ccea9acd9ee61859faf6	410558	Strings/Cello Section/spic/spic_D4_v1_RR2.wav
d5eb423d25f48568b93920bc173d1c46b14c59be	437876	Strings/Cello Section/spic/spic_D4_v2_RR1.wav
3de3959626e350483ab308ee73d1e522bf3cc619	401546	Strings/Cello Section/spic/spic_D4_v2_RR2.wav
3f0d96a12f2113b45e8d0233f6b46cb8a6990098	302264	Strings/Cello Section/spic/spic_E1_v1_RR1.wav
f03bd7f7287388076a058a48db359dc527c94497	359180	Strings/Cello Section/spic/spic_E1_v1_RR2.wav
9d40bd22e27a51218e404019a2b5920529cb2015	459140	Strings/Cello Section/spic/spic_E1_v2_RR1.wav
aa826bae797c1c9b5a4191859fd65321c93949c0	494612	Strings/Cello Section/spic/spic_E1_v2_RR2.wav
4d3a8ed35407f94b2681cb63edb88bb54ffef3c7	358880	Strings/Cello Section/spic/spic_E3_v1_RR1.wav
74f6d2222e5e0a673852d22c34c70f15c84d785f	309428	Strings/Cello Section/spic/spic_E3_v1_RR2.wav
fd37800c131511727ba9f633b14e3d6ddd9bd472	480080	Strings/Cello Section/spic/spic_E3_v2_RR1.wav
8053f186261fb4247bdc5932c9cc932ca01ab7af	600680	Strings/Cello Section/spic/spic_E3_v2_RR2.wav
0e2f2654ecdedcf68f9c1b87985025fac5443a9d	286550	Strings/Cello Section/spic/spic_F2_v1_RR1.wav
b3a928c5183452964d7924dce232e30d671354f5	297674	Strings/Cello Section/spic/spic_F2_v1_RR2.wav
3c0258c27207d83e8f932c732c74534b077e3c08	339830	Strings/Cello Section/spic/spic_F2_v2_RR1.wav
a383e1f075923e4452286f07b4c1a2aae7b9a0b7	399308	Strings/Cello Section/spic/spic_F2_v2_RR2.wav
495455b4beaceb03b3b6a82581dbba80e1f55084	207674	Strings/Cello Section/spic/spic_F4_v1_RR1.wav
48cd5dc529137258bb24ddce10830aac476c5168	233954	Strings/Cello Section/spic/spic_F4_v1_RR2.wav
a35d1c7ef09388d1e047f89c6410aa8b320a8ef0	204488	Strings/Cello Section/spic/spic_F4_v2_RR1.wav
109c3ea50bc7d1be36dc9f034aa3f09ca7a121cb	356792	Strings/Cello Section/spic/spic_F4_v2_RR2.wav
48331d770d78700e7681f681e99876531a07ce99	567434	Strings/Cello Section/spic/spic_G1_v1_RR1.wav
dc77aef2b1562bbf2e7cbf7ce886fe94b32647d3	495434	Strings/Cello Section/spic/spic_G1_v1_RR2.wav
373cf1dd9138334460fe9c108e31a3a257d22497	856028	Strings/Cello Section/spic/spic_G1_v2_RR1.wav
e09e531c9a46ac44547c6c040dc7073c12e8c3d3	755624	Strings/Cello Section/spic/spic_G1_v2_RR2.wav
f206574780f7e1661c050244a36a198de0cff4b4	359354	Strings/Cello Section/spic/spic_G3_v1_RR1.wav
ea163e3f86478b12c06ddab17b9fab7e5845110a	392348	Strings/Cello Section/spic/spic_G3_v1_RR2.wav
6b4769050f1e77567fd60c15d7318e96b5ebbef1	400208	Strings/Cello Section/spic/spic_G3_v2_RR1.wav
10fb31cd9f4829f11a0e1747dfd8e0dd47dfb81e	515834	Strings/Cello Section/spic/spic_G3_v2_RR2.wav
76df6b474aff133b2ac9d96bf2466cb6fd865c72	2336738	Strings/Cello Section/susvib/susvib_A2_v1_1.wav
ad696c6ad3cbacb37b6d9cf4f26da4a54521e7ce	3082676	Strings/Cello Section/susvib/susvib_A2_v3_1.wav
d6a4a2d1a688c6ccb4e1e1a56b878c9c93df468b	2372492	Strings/Cello Section/susvib/susvib_B1_v1_1.wav
56c81412c60a2b04b8556dfa26a7e0127357c5cb	3372962	Strings/Cello Section/susvib/susvib_B1_v3_1.wav
16d846690d7c4d385f3cfc8f1fe25873d6bd5b01	1690082	Strings/Cello Section/susvib/susvib_B3_v1_1.wav
3b1685e657db57bd71c979da8c2d9d35d2d0d197	2865086	Strings/Cello Section/susvib/susvib_B3_v3_1.wav
ff87d1ae488d87189f33a0d18550d3bcde012f3d	2347376	Strings/Cello Section/susvib/susvib_C1_v1_1.wav
d3820a6d57daf9a202a000bff0fa082a3f77acf6	3335948	Strings/Cello Section/susvib/susvib_C1_v3_1.wav
73ccb5dc2cc2a07926a1c41aa3c5621b19f420bf	2444174	Strings/Cello Section/susvib/susvib_C3_v1_1.wav
a192845091cb8e669c72d3ff4a88eb1c5968e626	3019394	Strings/Cello Section/susvib/susvib_C3_v3_1.wav
8076f809d4f6a8057f3835e12d22751a25e39252	2550956	Strings/Cello Section/susvib/susvib_D2_v1_1.wav
fdb46242bb68876ad275b9b8ed10c4b8508b9292	3291368	Strings/Cello Section/susvib/susvib_D2_v3_1.wav
e1125afc13def9b43e4612cdcebd11b99fce20cc	2153228	Strings/Cello Section/susvib/susvib_D4_v1_1.wav
9189549dab9d3e0928fc7e42f94c04d66d28c52b	2801210	Strings/Cello Section/susvib/susvib_D4_v3_1.wav
fcd27d29a8c0d520539cef6aad659bf9006ae730	2468348	Strings/Cello Section/susvib/susvib_E1_v1_1.wav
d5756d400ce67b25c332e04061dd9f32dc89d283	2439512	Strings/Cello Section/susvib/susvib_E1_v1_2.wav
666f0d1ba1a76133c12c9859222c1c7094b613cf	3080426	Strings/Cello Section/susvib/susvib_E1_v3_1.wav
63f4d6df3a25fb95f417b5d45b5f8bf6a11107bf	2456672	Strings/Cello Section/susvib/susvib_E3_v1_1.wav
7711cb67795d692b0d732eb8fd234c41d5980f42	3278270	Strings/Cello Section/susvib/susvib_E3_v3_1.wav
78f52c49ddc8a357657d92b05cd89f15beb6c717	2186012	Strings/Cello Section/susvib/susvib_F2_v1_1.wav
a384e84a342ab9be12ca55b92c845a3c351b75bf	3062696	Strings/Cello Section/susvib/susvib_F2_v3_1.wav
7f39cccecb392eaa0ff4c94e3607dc2294458a30	1922948	Strings/Cello Section/susvib/susvib_F4_v1_1.wav
074f12a91124e13ea0e4fb34d9ecbe7279ec0806	2726342	Strings/Cello Section/susvib/susvib_F4_v3_1.wav
42a2731d11a4749c3026f0618e21a8c9370c2024	2161700	Strings/Cello Section/susvib/susvib_G1_v1_1.wav
35971538059e18b8f38cdc556630967777a0a0d5	3370496	Strings/Cello Section/susvib/susvib_G1_v3_1.wav
7880157fbb8e57fb0b7a694b8569701bc0d942ea	2431598	Strings/Cello Section/susvib/susvib_G3_v1_1.wav
732d0c80596fdfc593f55b5a24f65c07cd3191cd	3335768	Strings/Cello Section/susvib/susvib_G3_v3_1.wav
01ce1406581e223d03d177428cc71f8d5dc29182	1999418	Strings/Cello Section/trem/trem_A2_v1_1.wav
b3cd3fa75e3e3c811dd961e7d76886a4713c7f62	2492954	Strings/Cello Section/trem/trem_A2_v2_1.wav
2db14b5e140812631f237e00a0bd4aacdcff43b1	2057552	Strings/Cello Section/trem/trem_B1_v1_1.wav
8ba6739037b2536455aa1e4209ced38c5fe12f09	1816706	Strings/Cello Section/trem/trem_B2_v2_1.wav
8cc90cd06bed0a3070eed294bc02084e436c453b	2086118	Strings/Cello Section/trem/trem_B3_v1_1.wav
1a20c03fbf3a28d806683ba439e6917235a062bd	2201306	Strings/Cello Section/trem/trem_B3_v2_1.wav
8141e6a8454370af624f9de17168e212e9437a45	2770772	Strings/Cello Section/trem/trem_C1_v2_1.wav
83115162183b6ad0de0d61436725178876ee884d	2166440	Strings/Cello Section/trem/trem_C3_v1_1.wav
8963b914a975e7ace7b8778e95d228183a716202	2155298	Strings/Cello Section/trem/trem_C3_v2_1.wav
5ea16cf0e585b17de9a6091ecd10cbc3ef30f63a	1837130	Strings/Cello Section/trem/trem_D2_v1_1.wav
6ecbe9a4436e2e523dd33a17417370c3d4aee1c4	2194472	Strings/Cello Section/trem/trem_D2_v2_1.wav
d0e303b7e23498e25c325853bb35dfd489b46785	1747856	Strings/Cello Section/trem/trem_D4_v1_1.wav
7e0ee3f7543a7ddf7327b5eb07e8984be90d45bf	1877174	Strings/Cello Section/trem/trem_D4_v2_1.wav
4f0b0e37586cc963551ba7184f52e7167a349bf5	2504834	Strings/Cello Section/trem/trem_E1_v1_1.wav
40a2d21fe4b129d4418e9311a09111e3521406d1	2206844	Strings/Cello Section/trem/trem_E1_v2_1.wav
7b8d7f3284af6eaecfcfffc1af1bef17911b4820	1789664	Strings/Cello Section/trem/trem_E3_v1_1.wav
074c54e05e9f6a5a4912636a5cb5596c39ee1871	2130890	Strings/Cello Section/trem/trem_E3_v2_1.wav
375d82e77d730ba12d9780c36a83ccf69ee6e809	1857944	Strings/Cello Section/trem/trem_F2_v1_1.wav
e5c951db69e1f4a025d65ea05aa439c4c049c358	1805360	Strings/Cello Section/trem/trem_F2_v2_1.wav
e93f13f0a0a8ef85427b1e49926d1bfb36fd3d95	1980140	Strings/Cello Section/trem/trem_F4_v1_1.wav
5fa88c274ec2a5c8459b6cf4a411c2701d85ad4a	1922408	Strings/Cello Section/trem/trem_F4_v2_1.wav
d55c7811f86d14a9413837861a805ddebbc00d88	1989578	Strings/Cello Section/trem/trem_G1_v1_1.wav
134d8cc1208f874ddf4e92e38da5eceff00fad76	2959028	Strings/Cello Section/trem/trem_G1_v2_1.wav
31bc5adda1a85a5266c890f7cbfb207c635067ba	1926902	Strings/Cello Section/trem/trem_G3_v1_1.wav
1e5bc46d26793ae51fe85f4d56994d67133b7f9d	2008850	Strings/Cello Section/trem/trem_G3_v2_1.wav
265383d75cb23b2882ca297e6c50908e3ec8247a	2007670	Strings/Harp/KSHarp_A2_mf.wav
acbece38a84e886cb5516e0f29d6ff5d38900fe1	2143618	Strings/Harp/KSHarp_A4_mf.wav
9fc9959804954e24e6837c426d702031fd2a3b7f	636870	Strings/Harp/KSHarp_A6_mf.wav
bb26292fd8b4d4d7f95703c69667c8f2234eebc8	2284022	Strings/Harp/KSHarp_B1_mf.wav
8d06cd55bc871d19f25a2bb1b56c7a567aabbc6b	1981130	Strings/Harp/KSHarp_B3_mf.wav
2d2689e8ca023cd685ed5a29161f3d641f109da9	779058	Strings/Harp/KSHarp_B5_mf.wav
d350ad472b663c9c239802f10228cd0073cf698d	483966	Strings/Harp/KSHarp_B6_mf.wav
20e91e167e86132bb16601f682c90444779d8a23	1586172	Strings/Harp/KSHarp_C3_mf.wav
748b4b1366616972c2a22e81fc48a86178801c45	1237142	Strings/Harp/KSHarp_C5_mf.wav
2a9d5a18ceb32459a29995a4e68e06c8f78dff5d	1741118	Strings/Harp/KSHarp_D2_mf.wav
342eec5072e2c0a7fb7cb03b6f5b46d84ed6ac69	1921690	Strings/Harp/KSHarp_D4_mf.wav
f66e88f651740695e4971c3197e6a1d61d6380c1	687750	Strings/Harp/KSHarp_D6_mf.wav
096a6d12f2a4e01c952d85100d11030b8ab2fdf9	396134	Strings/Harp/KSHarp_D7_f.wav
483714bd64ecf4947fe70d0ae0da6f2292c958f2	4001190	Strings/Harp/KSHarp_E1_f.wav
5c6c7410ae0ff7800214931f9db9a7f52db5987e	2461138	Strings/Harp/KSHarp_E3_mf.wav
20675907d698db011d0c8bc72cf9af4e7a1ac971	1171586	Strings/Harp/KSHarp_E5_mf.wav
03c3ce65453dc79a0b36805126b57574ff7dc654	3086590	Strings/Harp/KSHarp_F2_mf.wav
a1966639b165b623ac533270d616814cbc5389ef	1913498	Strings/Harp/KSHarp_F4_mf.wav
5d80932f790a28c088fab5dc2727c01ef2a130fc	413126	Strings/Harp/KSHarp_F6_mf.wav
2451907b2acc4cdf9b371111c760abc9bb866926	332482	Strings/Harp/KSHarp_F7_f.wav
b7935d0f8828a40be189f960960d4cb8d3235328	1189890	Strings/Harp/KSHarp_G1_mp.wav
a2f7fcc2bce81d039d9c0c529a94159f589f36e1	1806874	Strings/Harp/KSHarp_G3_mf.wav
8e3593345c95368ae9d74591c1046d21de6a8e60	1049778	Strings/Harp/KSHarp_G5_mf.wav
6b42c2b752ac8aa098fa512b1c068229036f9d55	344328	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A#0_v1_rr1.wav
74b090dd2b40841aa3657f35859ae5810ed3344e	326372	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A#0_v1_rr2.wav
b5525c15a77e1871feb42f70cc17a6650aee4355	417360	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A#0_v3_rr1.wav
3bcb6e93918b0e8355867acfcaca87106e421b23	458396	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A#0_v3_rr2.wav
311a5027a127715530f1e723a21f7927d280d493	623260	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A1_v1_rr1.wav
4ccbcc407cdc07f124f6523d50778d8e77ac2aad	485472	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_A1_v1_rr2.wav
c5bfef7aaa68a98928f172b8572711ea6ce8975d	417472	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_B2_v1_rr1.wav
a36c908d3b8b07d9ecc0107d465ab391160e3c79	332204	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_B2_v1_rr2.wav
16b7ca596182a49fe693b81ed925df8d2fc1be59	513824	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C#2_v1_rr1.wav
1538275fda063011eae150b531752b410186c2b6	498308	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C#2_v1_rr2.wav
46a4f947083669e7281be98b16c89b434529ea9e	270720	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C1_v1_rr1.wav
aa16603fb7d318a87c47abf01e3ea321cdc78418	405984	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C1_v1_rr2.wav
eb8c1aa8049e386288b71b7678098352a0c8f037	400396	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C1_v3_rr1.wav
974926b4eda1088bb5c7865de6712acc7803d304	384920	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_C1_v3_rr2.wav
623693ad1479a3e1da230fe62b8d012406412d86	856252	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_D1_v1_rr1.wav
6b66446765a55ddcad2fbfdf3b47fdc6737bc540	1062672	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_D1_v1_rr2.wav
8e025f9d9f072fd42a12ff27bad023f95016203f	423964	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E0_v1_rr1.wav
548f3bf22840c6477487df248e1a2d6417ad7175	412812	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E0_v1_rr2.wav
3258f6728cacc74c5ad6addadaa8a61cbb9d57cd	901744	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E0_v3_rr1.wav
92da6c6d93f06c950cbf8ebd737947cc8cd02769	908620	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E0_v3_rr2.wav
da8962289a777507e94094c6dde7131916ca1b64	294356	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E1_v1_rr1.wav
3326b2b4ae5a4bc6156e7ec8ce5adaca94e867e5	315292	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E1_v1_rr2.wav
1cada4277b16b2eb8b240d4a6da4bbd3aca989a0	518876	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E1_v3_rr1.wav
9033e53e840a4ca791ff0ae57bd1f171bc5a310c	445256	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E1_v3_rr2.wav
ba882653db7ef6fcebc5dc0e373707cdca944e62	438040	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E2_v1_rr1.wav
0d330f46bca35ae676072455ab09bc1391ffdff7	595380	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_E2_v1_rr2.wav
4578fd1b4f56290dc35ee453105e487efb3c5c67	256360	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#0_v1_rr1.wav
d0a056d068a5c9e2b9e1ddbf1f309c80e617dc9f	297240	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#0_v1_rr2.wav
4e6933681d86ea908000d9319e01db9858b499e1	828940	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#0_v3_rr1.wav
09b455dcad902b0c725168f405e5635c580ed3f2	910664	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#0_v3_rr2.wav
757d0487bc7ad3461aac13cdce1999fabb3952b3	868632	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#1_v1_rr1.wav
9a7f711fd6039b0ba71e6061edfb7de9d7102a8a	1036836	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_F#1_v1_rr2.wav
1b3774619e9ae958177bc6bd4429d32fbef0c0c8	601752	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G#1_v1_rr1.wav
51b5c8bbabf1760a072fc557652fb84bcaf827d8	537212	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G#1_v1_rr2.wav
b32004f92c141a30ba5e314dd0cc1d2687b92856	376048	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G#2_v1_rr1.wav
425eaabaf3d12ea8da780056e5e1a7ee4ddbde80	273224	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G#2_v1_rr2.wav
45d11b0a0545d59407f740b938461b205e8c91cb	169640	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G0_v1_rr1.wav
968cf37ef77070e116c8f665d0242af1287530fc	240624	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G0_v1_rr2.wav
219542998cac263bb0b5bd03ab02fd6bbdcb3d21	636880	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G0_v3_rr1.wav
09b63873d4e3070f2d0c513f69cb827ed83911c0	713924	Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_G0_v3_rr2.wav
1246bcb65fd3fe48e16f248486059944ca983a68	194664	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A#0_v1_rr1.wav
7d4edcd42a2a9a379862b31fda8062f2bf715ae2	231328	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A#0_v1_rr2.wav
4e04468888ee97306ae5b8ce73270c25e60ee612	260456	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A#0_v3_rr1.wav
94be75a715e9c897afa4d470f21f48006ee46ebd	311856	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A#0_v3_rr2.wav
8f020de45fd955ffe1d55570bacf8e57ab0de143	421292	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A1_v1_rr1.wav
56b700e9339329f60bcbf5860f1092cd36552b7d	401520	Strings/Solo Contrabass/Spic/BKCtbss_Spic_A1_v1_rr2.wav
4b198581d8d4e38816e76c365372a68254a2c81f	278964	Strings/Solo Contrabass/Spic/BKCtbss_Spic_B2_v1_rr1.wav
1697ad01a6d3d7bd685577499c89b97041b41a92	263652	Strings/Solo Contrabass/Spic/BKCtbss_Spic_B2_v1_rr2.wav
b92ba9831b089dcef128055c70fc7953fc9aea05	250516	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C#2_v1_rr1.wav
8254730ce72baad0bf5a5136c61bea13a3e339c4	334136	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C#2_v1_rr2.wav
03ebca73c64b7cb65c9f5db30133d4e61ad1c898	284716	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C1_v1_rr1.wav
a5823cc28774e098618b11aad5a36a82a602a79c	212816	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C1_v1_rr2.wav
712a59e62af56d68c210424b5526d4aed5009a95	239208	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C1_v3_rr1.wav
0be6efd7a711446edda295307b0a4d4b139f0c00	238012	Strings/Solo Contrabass/Spic/BKCtbss_Spic_C1_v3_rr2.wav
7076b42d62f57410c4369394b5305997e11bc5ba	268532	Strings/Solo Contrabass/Spic/BKCtbss_Spic_D1_v1_rr1.wav
4fbd9525f5f7209fccdaf2c3d89e4d45fc54f9df	280840	Strings/Solo Contrabass/Spic/BKCtbss_Spic_D1_v1_rr2.wav
49365a97360e240092041c32071f73cb053e4f74	305376	Strings/Solo Contrabass/Spic/BKCtbss_Spic_D1_v3_rr1.wav
5fa713d49854842b5fca7d4017dcf7c22a44a82c	271904	Strings/Solo Contrabass/Spic/BKCtbss_Spic_D1_v3_rr2.wav
c858fe0aeac53874ae33b98b463ad19b76b44d9c	327036	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E0_v1_rr1.wav
b6bc513466e27e2a9a062deff52e2f297b7b520f	426464	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E0_v1_rr2.wav
51db108d52c9a212fbc5e8e454bc0a6b4bf4abb6	579300	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E0_v3_rr1.wav
a3e80dea43cd183121c4bd51c1bf70387873f3d3	559292	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E0_v3_rr2.wav
de8a53628a9de1cdcc18202c23f5e1c4d9b8e512	246588	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E1_v1_rr1.wav
cabffb611561da582253b44928a4d16421c1d776	227528	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E1_v1_rr2.wav
a48af4d19d4f79180e3a7f89506e438f1242a104	381272	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E1_v3_rr1.wav
2cbf3b69db08f5cd16ecc0c8abdf7149d9ed2067	290536	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E1_v3_rr2.wav
491a14198674d517cd3ed77999fc3d1f5032aada	264448	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E2_v1_rr1.wav
d0f0e8ba56ec350e36f3440148cb87b1aaf86709	313948	Strings/Solo Contrabass/Spic/BKCtbss_Spic_E2_v1_rr2.wav
a5e00f82168c8655fc18a5efc69409a7614689c8	241572	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#0_v1_rr1.wav
8f08c1ed5de2ef2ab6ef24432a030807c84d42b2	276620	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#0_v1_rr2.wav
037927cef0283303513110d106f6bb52c44c97ac	358708	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#0_v3_rr1.wav
4bb66d9a107f67f70482069606a804246bbe59c7	439972	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#0_v3_rr2.wav
b8ea57d499c58ca57b0c1d85a921c2511b8c0502	262040	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#1_v1_rr1.wav
c2340e867d5c68c57d520fbe92e88bd21019d5d3	266076	Strings/Solo Contrabass/Spic/BKCtbss_Spic_F#1_v1_rr2.wav
468d3d287dd12990fdaf439e44497fe44e37f34e	433108	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G#1_v1_rr1.wav
ddf5871bec661b4bdf8462459d078b87a60e29fe	358092	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G#1_v1_rr2.wav
50ec5338d2532e5eb5baa9fc446119815ea934b0	315092	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G#2_v1_rr1.wav
30ad8e0b53c87fb65bcb53ba1dfe2c1c1997736d	353536	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G#2_v1_rr2.wav
d2fb7767c684ddd8f7a80fc914c837ba35485180	211852	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G0_v1_rr1.wav
e76d210ca57dadee06c02a3dbee89b2a4b3a6e5e	212112	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G0_v1_rr2.wav
08e14035167f3baf33d2388bb3a224b839c18564	282048	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G0_v3_rr1.wav
ed9eb3889e172db4dfe32cfde3fde6b692f1432d	289524	Strings/Solo Contrabass/Spic/BKCtbss_Spic_G0_v3_rr2.wav
7cf00f069ec3bcd2168ab3bf323528ccad07444c	1861432	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_A#0_v1_rr1.wav
938d98f61c6df3573658c7b1ebfaddc3643b29ee	1786876	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_A#0_v3_rr1.wav
1bffe0476c289a25c3404d023a37e26d473dee48	1249496	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_A1_v1_rr1.wav
1931bca16de18f5a7f4f3d36334b8d49bbfd935f	2383056	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_A1_v3_rr1.wav
1fa75f0eabf6637e3b64eedc7bcbda664b7bd5c9	1596108	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_B2_v1_rr1.wav
ffc3f8d81a8d551a7caa650d75b7ff45b27870c6	1375120	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_B2_v3_rr1.wav
6c81a4f26d83527e775f705a8888cde24224e75e	1162724	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_C#2_v1_rr1.wav
2e6da6b6e76e5eb396bf7203f847413f344202cf	1752396	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_C#2_v3_rr1.wav
e8b4cd7952603319926b7ad8d1ac363c07f61a67	1458252	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_C1_v1_rr1.wav
b682eeea5db633ff03765d15add584871a421092	1843084	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_C1_v3_rr1.wav
efc144474b11569f4c40c48b3b112d068d038274	2548840	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_D1_v1_rr1.wav
249f36163d2073c10a9085072324ac90c427641d	3209708	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_D1_v3_rr1.wav
3ec46c827e37588c7f5eed288055e85b75171a08	2852456	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E0_v1_rr1.wav
755166d7fa032b814274c2eb48f927069c20f03d	2341236	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E0_v3_rr1.wav
bfa40160c441f0b4ef4fb964a05434ba79513c10	2824612	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E1_v1_rr1.wav
bfb7197f57602935e10486ad753a4bc20220bb2e	2356332	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E1_v3_rr1.wav
b419330c6a748a8b4aa1cf2c3cffb04da87ec22a	1356572	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E2_v1_rr1.wav
458b973c82eb8d06aa8df74744c388e9571aa324	1277060	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_E2_v3_rr1.wav
6ad421289478178f9e3bec82ae206bebb7ce5292	2224156	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_F#0_v1_rr1.wav
51a849123c202178bccee68191009a1a862cd3e1	2295924	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_F#0_v3_rr1.wav
7bcbf7236cdee6c05b998b43bfe3d845d8a07837	1322048	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_F#1_v1_rr1.wav
a6681f7efe06d19894b0bdb03b7f15f04fe4c135	1619688	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_F#1_v3_rr1.wav
a7fb50754e56af940300a7af2f834f3635d2228d	1342128	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G#1_v1_rr1.wav
6142b5a07c12982809119348f2633bc57ff8c400	1722468	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G#1_v3_rr1.wav
c9eb10a6d480739d47e232f70f99b7441cd2ca4f	1630016	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G#2_v1_rr1.wav
95169c0f1fb4287e2b9bafb006912ba524dddac1	1585864	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G#2_v3_rr1.wav
1a0f1864681c12fbc9a0dd8ca118754e95bb20c6	1881520	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G0_v1_rr1.wav
d6a91ce81864ed75338f79038c55c57fd18d48bc	1934328	Strings/Solo Contrabass/SusNV/BKCtbss_SusNV_G0_v3_rr1.wav
6121cdd1a2011599c3f016c8bba312902d8dff5f	1336820	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_A#0_v1_rr1.wav
93b045a2ce6f37a7b479ee32c17b87a791bc16e0	2193316	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_A#0_v3_rr1.wav
552d5297f6a9b0384a4544eda9689fbb1f9f0950	2131692	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_A1_v1_rr1.wav
2829c3686a2ae6c728cd2c924679b66d850d74de	1975160	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_A1_v3_rr1.wav
ec3908bbb75b03c60c5fdfc182761016e90b3a89	1246160	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_B2_v1_rr1.wav
9424df5a5e339fc2aec523d78b99efa0de6e4d09	1633420	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_B2_v3_rr1.wav
7c9dde09e9bc254c0b7523ccce679c69b87a25e3	1349416	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_C#2_v1_rr1.wav
b84db77f1fec73b106f2f108037c66d23a35c1ce	1860096	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_C#2_v3_rr1.wav
b0698cd7f3deab8320de5bda1d96d1c3443a51b2	1835940	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_C1_v1_rr1.wav
961971106505e82db1b2a2c850e573528a75c6e7	2479908	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_C1_v3_rr1.wav
305eaa62b5a84f1035a8723792fe0f4011d7f9e6	3057536	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_D1_v1_rr1.wav
e66dde25194ee27477b4fdd31fd7726e84df2d73	2450408	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_D1_v3_rr1.wav
b1fbaaf4c5226a1ea8447b4e3687fb0539d62b0c	2429548	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_E1_v1_rr1.wav
c1749de03dc4ea9b49eca55318e7698b76e5b65d	2051084	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_E1_v3_rr1.wav
8a7643452697f29cfddba49c23549fdc913a8726	1533524	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_E2_v1_rr1.wav
2fc3c01f5d1a0449489800a5b5dabd3bc8817c80	1874324	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_E2_v3_rr1.wav
ddd3f5c1bff906167aa16bee3ceb45589fc32f22	1597380	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_F#0_v1_rr1.wav
4ffc597b3930f4e383be776141f0dab145120d62	2177272	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_F#0_v3_rr1.wav
cb95407f5853c21b4544a117bcca9cf074f45e71	1153568	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_F#1_v1_rr1.wav
dce2dab98559f73837834f23d80a1f73f6a57ad1	1710912	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_F#1_v3_rr1.wav
318147f57e7e2c6c13306e2a703dbcba670454a8	1256636	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G#1_v1_rr1.wav
6f701d221e67b5451cb80affd3002e743c8e4e68	1874712	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G#1_v3_rr1.wav
a9f242894bb6b52da9f7bef619023888e3b70c65	1352760	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G#2_v1_rr1.wav
e64bf733e9622fb6bea298708d0d30e3ce1c49b6	1821888	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G#2_v3_rr1.wav
35ee3d675424306c55438f2130f2c05e312da3f6	1583696	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G0_v1_rr1.wav
834df8922de2c341ee5f841f5bcc13e0bcb1206c	1990464	Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_G0_v3_rr1.wav
4bd5ac9b95bb34ced666a8c7f617f281c2524a8c	1271100	Strings/Solo Contrabass/Trem/BKCtbss_Trem_B2_v1_rr1.wav
4d343afe708a988521914157d5c3cb1b26f04004	1295132	Strings/Solo Contrabass/Trem/BKCtbss_Trem_B2_v2_rr1.wav
41b8665b1aaca24c7644c4af711dc447266dcfae	1639656	Strings/Solo Contrabass/Trem/BKCtbss_Trem_C1_v1_rr1.wav
eb79be467b6f087fb653f573b8508ffcaecb77ab	1541644	Strings/Solo Contrabass/Trem/BKCtbss_Trem_C1_v2_rr1.wav
d3560d0bd9d24c341ecbba75c04ecc82861e34b2	1876908	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E0_v1_rr1.wav
a6c21e1b33bbe38a8eb6191b9fc393ebc82e887e	1393488	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E0_v2_rr1.wav
daea5b25219713a5314c06407a0108a4d67e1d9a	1288084	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E1_v1_rr1.wav
f22c7de7b31174f01452d0018306bbd6bbcc0771	1244628	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E1_v2_rr1.wav
357879c646efa49ce2635f1bbedd817cee26cde8	1250224	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E2_v1_rr1.wav
1e1d52ea6dc808fc53b0df2bbdc58d3b82c70c51	1329532	Strings/Solo Contrabass/Trem/BKCtbss_Trem_E2_v2_rr1.wav
4d4f4f504dedaa7084bb8291397d4ae797758fde	1127372	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G#1_v1_rr1.wav
364bad13ba84df7f651f43e26f704f621e1eae46	1415692	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G#1_v2_rr1.wav
ca79dea597d50a21eb089f8d6220550854437d20	1079184	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G#2_v1_rr1.wav
b2038c220b9ee2249f2993695d28a6ea4b7eabb6	1273128	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G#2_v2_rr1.wav
40dcdf796f7aee1e80a61dde24b3c8aee21ec30b	1077836	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G0_v1_rr1.wav
d322da95ef63b833ff5b589f03b8baaca11bbfd2	1204000	Strings/Solo Contrabass/Trem/BKCtbss_Trem_G0_v2_rr1.wav
82964f15bb0ca3d34dbdfdd43ad0148f9d8767af	2864482	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A3_f.wav
7122b440f4dbd148a81319fca1d04a550710cef3	2911130	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A3_p.wav
3155c72c1f9ea1518ddb6c1a20eb5c0a094bd537	2488526	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A4_f.wav
e8667671328e1cfcd769a7624c26fac133ad7b0f	2612122	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A4_p.wav
eebb9f220dc2a93557acc849d5dd3273b8f0ff8f	1986834	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A5_f.wav
5eb8185d8ca9b3f34110654c2779e587de513921	2562122	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A5_p.wav
c296065592b8adf9e12f51af9d003b7259ecc6e2	2052254	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A6_f.wav
32e4646793f68c897271fb7f97887c95dbaf59fc	2614110	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_A6_p.wav
8a700075b7ae2f19c1c56108738324dfba6959e8	2334170	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C4_f.wav
9f876cafa572a8719e2e93fc994c5303992b8e62	3096650	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C4_p.wav
93e9a2cf8106acc5e49ba18dab112c947473917f	2497990	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C5_f.wav
71f0671d77cf8b79ce1a18ba20d9661e24f086fc	2498790	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C5_p.wav
89f48f37313800df4c5901dc76b49b1c5c69e396	2162774	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C6_f.wav
33bc7e87816637462d6e174da9949eb9b5e45ef4	2358906	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C6_p.wav
2348056e211ef9b6d309f3718d8e4e49471f65ce	2176486	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C7_f.wav
bc1f4c13bb7c9693f7c5ef5a44bfe27463aa8cda	2274706	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_C7_p.wav
6b1bcdf57513dd089a2172adc0ddbac4a335b3a0	2416566	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E4_f.wav
99279ebc21258ab48aae6eb63d1eb7538f28d306	2600174	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E4_p.wav
269658d510e82345227ac10d22f928cfae428c99	2365174	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E5_f.wav
670865e19772aceab538850ea7a0d1a86024d955	2517094	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E5_p.wav
26855bca28a7be29386cbd6db56d2ae6f7c3b66c	2363554	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E6_f.wav
52407eb061956458643424aa623998ee43ce5136	2514702	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_E6_p.wav
a09b038528097878ad6b12d30da4ac1a227d5a98	2936890	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G3_f.wav
bc5f7d33610abbc3000f432562f36063f1d3d725	2788822	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G3_p.wav
f9c1a5547a7e062eb34ee6bef09e559d3839f46e	2366050	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G4_f.wav
7324564c663bf239802020287c217b27c76b8142	2594066	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G4_p.wav
f8745db337ebf8e82d59f90cea7c0f060a3615ce	2222106	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G5_f.wav
a0ac97ce56dcbfb7b622abd2aa3c61678053f791	2596714	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G5_p.wav
9bd2b0d9d6e5505a0c0ce0722bd10db7913ee97d	2164026	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G6_f.wav
eca2508aa84cef89ee2002953d3b5f9867d53802	2417222	Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_G6_p.wav
e73444b559e8f5cacde32568c1e5cd5916e64767	455042	Strings/Solo Violin/Pizz/LLVln_Pizz_A3_f_RR1.wav
035403d940005c8d8ec62fd185154e5d52aa76f7	352286	Strings/Solo Violin/Pizz/LLVln_Pizz_A3_f_RR2.wav
5a602ef63e0ec7598c5ddbe04dd47810f18e08d4	252226	Strings/Solo Violin/Pizz/LLVln_Pizz_A3_p_RR1.wav
2b583ba22edfa2412479560b44e62d473089a468	236542	Strings/Solo Violin/Pizz/LLVln_Pizz_A3_p_RR2.wav
0068a6bd084708b278b10b1e6880cf97ffd59245	407654	Strings/Solo Violin/Pizz/LLVln_Pizz_A4_f_RR1.wav
61c9f743fce95fdf5e820b8d3508dfb0a72dc726	487638	Strings/Solo Violin/Pizz/LLVln_Pizz_A4_f_RR2.wav
e1edd9dec991f5e30ccfbea1e71e44a36cf3d037	407194	Strings/Solo Violin/Pizz/LLVln_Pizz_A4_p_RR1.wav
2df344122ff2eae349af7b22648346044bfbf01e	392590	Strings/Solo Violin/Pizz/LLVln_Pizz_A4_p_RR2.wav
262a86433d8e1130483315af38c1f645076bf7cf	329810	Strings/Solo Violin/Pizz/LLVln_Pizz_A5_f_RR1.wav
eefa5108617b5f14aceeeaa8b46ae62ac0b708a6	355430	Strings/Solo Violin/Pizz/LLVln_Pizz_A5_f_RR2.wav
a40098f5d112f566074d41204a45192f199381c9	231858	Strings/Solo Violin/Pizz/LLVln_Pizz_A5_p_RR1.wav
37f7eb78ac0c7311edaaa75eacb8343530245997	259234	Strings/Solo Violin/Pizz/LLVln_Pizz_A5_p_RR2.wav
6e74fd53eeb0bc387c63367b9813ad31afe411c9	158874	Strings/Solo Violin/Pizz/LLVln_Pizz_A6_f_RR1.wav
046e2309074eebcd05d153d4edc66dd52e5a3b1a	170638	Strings/Solo Violin/Pizz/LLVln_Pizz_A6_f_RR2.wav
6c869ff5041622f68dfdc242013f8be83584d585	266734	Strings/Solo Violin/Pizz/LLVln_Pizz_C4_f_RR1.wav
06ab4b8f5891038d7b7c5b0a896827f42ac37553	243210	Strings/Solo Violin/Pizz/LLVln_Pizz_C4_f_RR2.wav
1de8534ffd8027c438bf8e676c1d8bd619a51c05	202686	Strings/Solo Violin/Pizz/LLVln_Pizz_C4_p_RR1.wav
3fbea8e8d9bca978a4b2808d8e6a26da39388942	180622	Strings/Solo Violin/Pizz/LLVln_Pizz_C4_p_RR2.wav
6b098e94523e710182b7ffdc9b61a6831b8bf956	314458	Strings/Solo Violin/Pizz/LLVln_Pizz_C5_f_RR1.wav
6d0e35664cac7fe32cef9ea7c35dee95f6089ab5	245206	Strings/Solo Violin/Pizz/LLVln_Pizz_C5_f_RR2.wav
62e1847954dd5c8e979db5238fd36129c61d54dc	146346	Strings/Solo Violin/Pizz/LLVln_Pizz_C5_p_RR1.wav
1fcb0a0583690560c4991b6f4455b2637b10e423	132558	Strings/Solo Violin/Pizz/LLVln_Pizz_C5_p_RR2.wav
167fd12572f38700327585840479299286704019	186922	Strings/Solo Violin/Pizz/LLVln_Pizz_C7_f.wav
ddd3aef5e50524c121d01dde12e026547d0c3b44	343798	Strings/Solo Violin/Pizz/LLVln_Pizz_E4_f_RR1.wav
fdf75c90e30fb70c9a1ac05b0e98601ccb0e05ee	340118	Strings/Solo Violin/Pizz/LLVln_Pizz_E4_f_RR2.wav
f8033df88e916726881994b8d7af8b1731358dc0	219786	Strings/Solo Violin/Pizz/LLVln_Pizz_E4_p_RR1.wav
1179a775b51c7842d0ad8e2d0ca9137ac71e1ef3	244910	Strings/Solo Violin/Pizz/LLVln_Pizz_E4_p_RR2.wav
78fa76ba4c64ca8c9d93e201e3b3d53657118b6d	549454	Strings/Solo Violin/Pizz/LLVln_Pizz_E5_f_RR1.wav
54f85086b5d772b993ae3b763b835aaab46e4402	587006	Strings/Solo Violin/Pizz/LLVln_Pizz_E5_f_RR2.wav
1c2138383e304522c69019ba23bd9fe2682225ee	309230	Strings/Solo Violin/Pizz/LLVln_Pizz_E5_p_RR1.wav
a100ec48192b0a6de1d7ee2c54e08fbf2454f917	374842	Strings/Solo Violin/Pizz/LLVln_Pizz_E5_p_RR2.wav
c772b62c24da878732b1c7aabe303569a2e04649	221638	Strings/Solo Violin/Pizz/LLVln_Pizz_E6_f_RR1.wav
58f3916f60314b6e17e226f5d6e3cf07b3dad81d	179286	Strings/Solo Violin/Pizz/LLVln_Pizz_E6_f_RR2.wav
3babfa3e843a8252100cad58d4931d5e9784c2c0	708714	Strings/Solo Violin/Pizz/LLVln_Pizz_G3_f_RR1.wav
463670173ba5e4a8104b325e74fa8fb8bad8eec0	853698	Strings/Solo Violin/Pizz/LLVln_Pizz_G3_f_RR2.wav
b00ffdca3db2879b00121f6948176d63ec46e89d	670770	Strings/Solo Violin/Pizz/LLVln_Pizz_G3_p_RR1.wav
b88cb207441bd8dd97220f849351a377d0df55ab	229234	Strings/Solo Violin/Pizz/LLVln_Pizz_G4_f_RR1.wav
827b57fde631ce963509d12c1e9eea04fa6b1497	244566	Strings/Solo Violin/Pizz/LLVln_Pizz_G4_f_RR2.wav
0974949115e937fb8380bc6b1363da3c928a9524	237770	Strings/Solo Violin/Pizz/LLVln_Pizz_G4_p_RR1.wav
dccbd510dd1f858ae2f19f4bb9d51311c49b093c	204786	Strings/Solo Violin/Pizz/LLVln_Pizz_G4_p_RR2.wav
56bbed3374d802c8a01634f8dbdb288c0fa54468	210570	Strings/Solo Violin/Pizz/LLVln_Pizz_G5_f_RR1.wav
8f481a3a43a2dcd2f13b42c047a9805df8e41be4	246934	Strings/Solo Violin/Pizz/LLVln_Pizz_G5_f_RR2.wav
f5237bb8d72a272bf5b9ac6c4b5cc109559a77b8	160246	Strings/Solo Violin/Pizz/LLVln_Pizz_G5_p_RR1.wav
d697b47443ca17b5978a0a0f562011ee7b5efaf1	164818	Strings/Solo Violin/Pizz/LLVln_Pizz_G5_p_RR2.wav
a2a34e7d4e11c786102489b9edecd897914b5f1e	1242096	Strings/Solo Violin/Trem/LLVln_trem_A2_v1_rr1.wav
0e6cf170a98fa2d6cd87c9b0f3b742e8a1d96948	1434720	Strings/Solo Violin/Trem/LLVln_trem_A2_v2_rr1.wav
b05e9f2e63db6447bd91165f4777244b719db259	1325428	Strings/Solo Violin/Trem/LLVln_trem_A3_v1_rr1.wav
b790de6a30af1a6b735a400a6bb2789e46058ca8	1234852	Strings/Solo Violin/Trem/LLVln_trem_A3_v2_rr1.wav
d92aca7f77f5288c47954fa15d1a58fc1dafbf17	1341468	Strings/Solo Violin/Trem/LLVln_trem_A4_v1_rr1.wav
dfb62d47ec80c9733ed938ac79cc9c5166371b53	1308108	Strings/Solo Violin/Trem/LLVln_trem_A4_v2_rr1.wav
7d15239eb5e1bcde2bce8e21091f301938de5fd1	1207480	Strings/Solo Violin/Trem/LLVln_trem_C3_v1_rr1.wav
88815cd35151089b3e19e115a85968497f51e761	1268928	Strings/Solo Violin/Trem/LLVln_trem_C3_v2_rr1.wav
eb9aa85e53c57bdff184d9d7825a7a04ee1e8ac1	1185856	Strings/Solo Violin/Trem/LLVln_trem_C4_v1_rr1.wav
5dd7adb8a15a05794a0f9b94933e388a6aae0183	1385804	Strings/Solo Violin/Trem/LLVln_trem_C4_v2_rr1.wav
6b2a0edb3b53bfb4c1bfe953c7b56399c1c3ffd3	1156076	Strings/Solo Violin/Trem/LLVln_trem_C5_v1_rr1.wav
a0ba87d9f4f462c5a5dc66f53c33b3db738ff310	1042900	Strings/Solo Violin/Trem/LLVln_trem_C5_v2_rr1.wav
3360e3637e8d367f1cdf21c8e302eb25bfe9846c	1666564	Strings/Solo Violin/Trem/LLVln_trem_C6_v2_rr1.wav
4c6b97372045f0ebbaecee30381d251b98a91b9d	1357076	Strings/Solo Violin/Trem/LLVln_trem_E3_v1_rr1.wav
9607e5bbcc8907beeb26665ce7e09442ffbde4c1	1358384	Strings/Solo Violin/Trem/LLVln_trem_E3_v2_rr1.wav
aae3b51f5c62478f5d68c1d93a99252118e19fcc	988948	Strings/Solo Violin/Trem/LLVln_trem_E4_v1_rr1.wav
ae6d11a641c974641950744334b6b1a5626ac411	1248160	Strings/Solo Violin/Trem/LLVln_trem_E4_v2_rr1.wav
6e6cdf7eb24559c735fe9a511ce00496da76314b	1206932	Strings/Solo Violin/Trem/LLVln_trem_E5_v1_rr1.wav
6ac89880fb68aeb4e27a16cb8f1469c1784c247f	1340880	Strings/Solo Violin/Trem/LLVln_trem_E5_v2_rr1.wav
4533a387820f4a07e0c52c2d76d3562681cbd6e0	1168480	Strings/Solo Violin/Trem/LLVln_trem_G2_v1_rr1.wav
cb3127b3ca2cbe3395b4ea678a45ea54fc9a2c3c	1055924	Strings/Solo Violin/Trem/LLVln_trem_G2_v2_rr1.wav
5b869ae9e77b61b88e5a518c0691991c0d48d986	1167032	Strings/Solo Violin/Trem/LLVln_trem_G3_v1_rr1.wav
8f3a5c5da8931c33bad473054079347f195a3e71	1408600	Strings/Solo Violin/Trem/LLVln_trem_G3_v2_rr1.wav
4137625c50acb02b0355d6ef27caeeee5f75346a	1106004	Strings/Solo Violin/Trem/LLVln_trem_G4_v1_rr1.wav
4962ef0da4b1cf48385377496f7311c3cfa84e04	1157700	Strings/Solo Violin/Trem/LLVln_trem_G4_v2_rr1.wav
6796c2947c47697125e52b5f89ada2742193c6e5	1489688	Strings/Solo Violin/Trem/LLVln_trem_G5_v1_rr1.wav
39feb64ebd20a227e445b42bd6f77240a5a7b6ca	1105492	Strings/Solo Violin/Trem/LLVln_trem_G5_v2_rr1.wav
211254adc1095c5cd07ffe446cab03d13d199f4e	212172	Strings/Solo Violin/spic/LLVln_spic_A2_v1_rr1.wav
70f2c40b11103c2b500051f590a906c75731674b	147868	Strings/Solo Violin/spic/LLVln_spic_A2_v1_rr2.wav
eca9436681313234882a4c17c3082d9343f27808	292356	Strings/Solo Violin/spic/LLVln_spic_A2_v2_rr1.wav
42f611e564b7b69f886f522cc6e547ee4f06ccfc	334496	Strings/Solo Violin/spic/LLVln_spic_A2_v2_rr2.wav
908f547bf41f4c96f563a477d49729837512a21e	181484	Strings/Solo Violin/spic/LLVln_spic_A3_v1_rr1.wav
62e4007089ee95bc0bb6d7564b25d7db5bde43f3	163712	Strings/Solo Violin/spic/LLVln_spic_A3_v1_rr2.wav
1dea32d696864337efef8d8c6b0cd28adf1161d5	245852	Strings/Solo Violin/spic/LLVln_spic_A3_v2_rr1.wav
decce7ea868ddf499e2e611f9814f0865cdf7a2a	315832	Strings/Solo Violin/spic/LLVln_spic_A3_v2_rr2.wav
944b32b43f491ffdbc799411fc1835023c5c7468	243708	Strings/Solo Violin/spic/LLVln_spic_A4_v1_rr1.wav
d795873816e42fa52865482d0e0dfe261c61e3b3	235924	Strings/Solo Violin/spic/LLVln_spic_A4_v1_rr2.wav
9d34ba95a4f5e3d57cf41a9c4e70ed743e9763bb	244532	Strings/Solo Violin/spic/LLVln_spic_A4_v2_rr1.wav
5cbe11816807f935d8c622fe093502c4be99ce04	342108	Strings/Solo Violin/spic/LLVln_spic_A4_v2_rr2.wav
9fa3c1afc57721aca459f95ba62e7a4f2a8c44f0	190168	Strings/Solo Violin/spic/LLVln_spic_A5_v1_rr1.wav
f9b0e3f8b5f9c6d08a026a3c6e48f7746f0921a0	159720	Strings/Solo Violin/spic/LLVln_spic_A5_v1_rr2.wav
59f6e7795b71e1b8a669bc6d649eef49bb4a5f6c	239996	Strings/Solo Violin/spic/LLVln_spic_A5_v2_rr1.wav
fc5dc7e25d856634d4176a97d5c1a82cc95edee7	169368	Strings/Solo Violin/spic/LLVln_spic_A5_v2_rr2.wav
c9abfda176f7c980a813cab215d8c7d9a7202702	147328	Strings/Solo Violin/spic/LLVln_spic_C3_v1_rr1.wav
7296148d638da5a13dc7869e4c698447b0754f27	143016	Strings/Solo Violin/spic/LLVln_spic_C3_v1_rr2.wav
2db2c5caa332b7f80ce3db072751ffb261e02507	201628	Strings/Solo Violin/spic/LLVln_spic_C3_v2_rr1.wav
604935c00648d3cf3de3812d058116a2fea2e2b9	208516	Strings/Solo Violin/spic/LLVln_spic_C3_v2_rr2.wav
e28743348f83c23fbacba710f2d0ca1efe1732be	150832	Strings/Solo Violin/spic/LLVln_spic_C4_v1_rr1.wav
c4a85464d54132ebd749a4478e0eb0aebb105434	158924	Strings/Solo Violin/spic/LLVln_spic_C4_v1_rr2.wav
9ba721d1e32ea23a21668fb93a20b8c7baba8552	211868	Strings/Solo Violin/spic/LLVln_spic_C4_v2_rr1.wav
7a236b75693dcf3334b0cbe315492b478a14a8d6	209452	Strings/Solo Violin/spic/LLVln_spic_C4_v2_rr2.wav
b668b7180e25f0220c67ebb42737441085d307fb	221532	Strings/Solo Violin/spic/LLVln_spic_C5_v1_rr1.wav
e06665c7ebac0cf00495643eb80199fb3cb5afba	165968	Strings/Solo Violin/spic/LLVln_spic_C5_v1_rr2.wav
f99aa8b70b2853d7eb18b33d61f3636a1a09aa3e	217828	Strings/Solo Violin/spic/LLVln_spic_C5_v2_rr1.wav
5515bc6f34bfdb6576f818d2233992d8097c54b3	226964	Strings/Solo Violin/spic/LLVln_spic_C5_v2_rr2.wav
1effead1f870eda3d8df49149fa6f8e1a1cc6f91	216652	Strings/Solo Violin/spic/LLVln_spic_C6_v1_rr1.wav
e58b7f8a952a0c811f3aeb5ea31b32818c281bb6	191664	Strings/Solo Violin/spic/LLVln_spic_C6_v1_rr2.wav
b5394fffeb1e8a094446ae606a6d0411c7f02ec9	196924	Strings/Solo Violin/spic/LLVln_spic_C6_v2_rr1.wav
e508cc8e810ea18466f7024c5945e54e0970bec9	206584	Strings/Solo Violin/spic/LLVln_spic_C6_v2_rr2.wav
8fa7ec4ed3489504ed74b6d93d5ae9d0f5ddb81c	225092	Strings/Solo Violin/spic/LLVln_spic_E3_v1_rr1.wav
e6fb2b1addc8baf3136fcb76b43e8f554da64020	220480	Strings/Solo Violin/spic/LLVln_spic_E3_v1_rr2.wav
9b62458ed0cf1d75d3f8b9c81d0a2bdb306ceee1	290760	Strings/Solo Violin/spic/LLVln_spic_E3_v2_rr1.wav
77290d529a4f0d9618df5edeaed1fd33a08cee99	215624	Strings/Solo Violin/spic/LLVln_spic_E3_v2_rr2.wav
253fda64fb563265822d6b4ba01aa3611e77607f	291860	Strings/Solo Violin/spic/LLVln_spic_E4_v1_rr1.wav
9958739b6962455e04cd091ed5f2c5abcf5a14dc	297672	Strings/Solo Violin/spic/LLVln_spic_E4_v1_rr2.wav
92f3ec662cf22a853c7742fc75a003239915eebc	326208	Strings/Solo Violin/spic/LLVln_spic_E4_v2_rr1.wav
b603d34101e30c725aaa4d13086c8e5fbee053cb	353820	Strings/Solo Violin/spic/LLVln_spic_E4_v2_rr2.wav
92076286dd7dce51640594b504164cb0fcbb389b	235416	Strings/Solo Violin/spic/LLVln_spic_E5_v1_rr1.wav
8482e37b5318476932bb79ce8e876bff9a2b43dc	236520	Strings/Solo Violin/spic/LLVln_spic_E5_v1_rr2.wav
d5f86ab47c85be60cad90a3c1762a252ddd4ec27	204612	Strings/Solo Violin/spic/LLVln_spic_E5_v2_rr1.wav
6928fc3785ee468048421b64cf1fbeaffcedef91	173228	Strings/Solo Violin/spic/LLVln_spic_E5_v2_rr2.wav
ba70f44254bcb8e29d70bc183fda36fde930d6d8	161360	Strings/Solo Violin/spic/LLVln_spic_G2_v1_rr1.wav
d1f02c01501100bd249169ef28d2c7a0db7cced5	209040	Strings/Solo Violin/spic/LLVln_spic_G2_v1_rr2.wav
db74dd3455da835f2a32cf260cbb02fa26d0f0b7	391880	Strings/Solo Violin/spic/LLVln_spic_G2_v2_rr1.wav
275e8c8daf0b552de0750fccefedc05d040513e8	368676	Strings/Solo Violin/spic/LLVln_spic_G2_v2_rr2.wav
cbd6597be4125472c37149341bba7864adb6c2bc	262440	Strings/Solo Violin/spic/LLVln_spic_G3_v1_rr1.wav
51e5e0a2c564d4b2ff1ad9bcb04e33b23d610806	178892	Strings/Solo Violin/spic/LLVln_spic_G3_v1_rr2.wav
48c6b41928f6b676c4b3372ef3bf7e271370566f	207440	Strings/Solo Violin/spic/LLVln_spic_G3_v2_rr1.wav
46a505b3aaf448ae9849d015f84daeabffc02da4	196268	Strings/Solo Violin/spic/LLVln_spic_G3_v2_rr2.wav
2ffdb43df271a27a189ac6cdd94f4becdfcfd5c5	220868	Strings/Solo Violin/spic/LLVln_spic_G4_v1_rr1.wav
f762c40bb3f095821fb74b8601c729711830f943	199328	Strings/Solo Violin/spic/LLVln_spic_G4_v1_rr2.wav
2ab520fa524a0d3599ae6cc08ee2645cf3482efc	226544	Strings/Solo Violin/spic/LLVln_spic_G4_v2_rr1.wav
bf2c7c53c19cae414f6b775ea6993513c0fd1bb6	243868	Strings/Solo Violin/spic/LLVln_spic_G4_v2_rr2.wav
bf88ecd7cd28778614588177c8acf2e99f155fbf	144376	Strings/Solo Violin/spic/LLVln_spic_G5_v1_rr1.wav
fc3457d5b420ea7771069f7e9f68d34dd4cb095c	180720	Strings/Solo Violin/spic/LLVln_spic_G5_v1_rr2.wav
6b66264e9aac4b2b7e59eee940843a93a2343e96	163952	Strings/Solo Violin/spic/LLVln_spic_G5_v2_rr1.wav
be48f20e235522dfbec184da6f4ccbd5c1514f99	212520	Strings/Solo Violin/spic/LLVln_spic_G5_v2_rr2.wav
9e79655db650ba68cb3d0394044bb01eb0625761	180950	Strings/Viola Section/pizz/ViolaEns_pizz_A3_v1_rr1.wav
e74461d23a5310539d7abae002a43edff0ffd4b8	169790	Strings/Viola Section/pizz/ViolaEns_pizz_A3_v1_rr2.wav
9de4d07c67de4dca6f27cf2327ebb6c08c1b94f3	254342	Strings/Viola Section/pizz/ViolaEns_pizz_A3_v2_rr1.wav
2ea6ad363b9163b72a912bee4d031c6744e78e4d	252530	Strings/Viola Section/pizz/ViolaEns_pizz_A3_v2_rr2.wav
cb78e06a28de6cef9418c397ad888c9c0c08d44e	486998	Strings/Viola Section/pizz/ViolaEns_pizz_B2_v1_rr1.wav
e5e9fc90bf58f608705e7946e2421ba3b9e78338	328820	Strings/Viola Section/pizz/ViolaEns_pizz_B2_v1_rr2.wav
f173ceb40736998973ab4337bbdd465eca7f56c7	663686	Strings/Viola Section/pizz/ViolaEns_pizz_B2_v2_rr1.wav
250c435360d6a963254fd57b01dbce0ba760ab2d	569942	Strings/Viola Section/pizz/ViolaEns_pizz_B2_v2_rr2.wav
b77228684ce83c89167c923886308c6c10026aa3	74750	Strings/Viola Section/pizz/ViolaEns_pizz_B4_v1_rr1.wav
b3378a46d3b8f9a52665beb77169087a5b705abd	90494	Strings/Viola Section/pizz/ViolaEns_pizz_B4_v1_rr2.wav
f18ce2e445e9de37eb5eb378f15b6e51734096b4	132410	Strings/Viola Section/pizz/ViolaEns_pizz_B4_v2_rr1.wav
c36405bbd5564a0ab9a4890f7e5636f02528beed	121232	Strings/Viola Section/pizz/ViolaEns_pizz_B4_v2_rr2.wav
681e5aac2f7e7e79449609fd01edb99b9d7a9915	601340	Strings/Viola Section/pizz/ViolaEns_pizz_C2_v1_rr1.wav
9df0a42549a2dc6b107a876b3f130fba8c78c1da	567884	Strings/Viola Section/pizz/ViolaEns_pizz_C2_v1_rr2.wav
42b07fe5c91fa44ce0c1a9708d9a2c31ed72d273	631802	Strings/Viola Section/pizz/ViolaEns_pizz_C2_v2_rr1.wav
51ae8e702fb269b268d997c633e20c86d9ed2153	890594	Strings/Viola Section/pizz/ViolaEns_pizz_C2_v2_rr2.wav
e9f5427323653e6e4072f714d3525642d30a0c5c	230726	Strings/Viola Section/pizz/ViolaEns_pizz_C4_v1_rr1.wav
024a6340cc8c13aa8712055db7a6e2008c3ba201	226922	Strings/Viola Section/pizz/ViolaEns_pizz_C4_v1_rr2.wav
925a67d46b76698778086c3654f89c75c4bea758	225626	Strings/Viola Section/pizz/ViolaEns_pizz_C4_v2_rr1.wav
aed00952457a473b3e40743267b26d8f729ea3ff	244472	Strings/Viola Section/pizz/ViolaEns_pizz_C4_v2_rr2.wav
215c51dec2a5a182f19c652e82a5f7214f964f0d	464972	Strings/Viola Section/pizz/ViolaEns_pizz_D3_v1_rr1.wav
b601b3f8cd8082bb32325a6eb0319019c6d0d8b2	197036	Strings/Viola Section/pizz/ViolaEns_pizz_D3_v1_rr2.wav
d9f9a65a0bb7bea7a24b493277224189c88bd66d	728720	Strings/Viola Section/pizz/ViolaEns_pizz_D3_v2_rr1.wav
8d1b5d42631c2a617717b8a61b5a7411c83165b0	688850	Strings/Viola Section/pizz/ViolaEns_pizz_D3_v2_rr2.wav
d923ff493d566981e5f7f20fb371aa009c809656	105980	Strings/Viola Section/pizz/ViolaEns_pizz_D5_v1_rr1.wav
9a5f0c442d1c63ed2814f6049bce074515b82409	112166	Strings/Viola Section/pizz/ViolaEns_pizz_D5_v1_rr2.wav
0e6395ddd69d3181dc79d4e0d8892d5f87e25c60	120776	Strings/Viola Section/pizz/ViolaEns_pizz_E2_v1_rr1.wav
fb8666c37d082e544aff209c312d6dd0ce64d155	219314	Strings/Viola Section/pizz/ViolaEns_pizz_E2_v1_rr2.wav
44c2457a6e282d7c0e2a8599d82ad98d7a369c89	264506	Strings/Viola Section/pizz/ViolaEns_pizz_E2_v2_rr1.wav
a5772b8121c095a178ee24f404dcceea9ce147fb	375290	Strings/Viola Section/pizz/ViolaEns_pizz_E2_v2_rr2.wav
5de1e8f41bc35125422aa5493f5adebeb3eb462b	177002	Strings/Viola Section/pizz/ViolaEns_pizz_E4_v1_rr1.wav
fd07cdc2800f65b2d7da088d0097e52b5b80e6ff	180950	Strings/Viola Section/pizz/ViolaEns_pizz_E4_v1_rr2.wav
f5ef63b7ec6edf1878e8e27e4819e8faaec2b458	305114	Strings/Viola Section/pizz/ViolaEns_pizz_E4_v2_rr1.wav
3330871e68bb94abc55d8379b910bdd40b71d9f1	469490	Strings/Viola Section/pizz/ViolaEns_pizz_E4_v2_rr2.wav
410d464cf9c4aaba28bc8f03209ff1381fb1122f	299774	Strings/Viola Section/pizz/ViolaEns_pizz_F3_v1_rr1.wav
b03a32b1dcf0af32496cc8b8e27ad87cefd6e3a0	149690	Strings/Viola Section/pizz/ViolaEns_pizz_F3_v1_rr2.wav
95611c06607f789e89326df5bc477b3f107889fd	286154	Strings/Viola Section/pizz/ViolaEns_pizz_F3_v2_rr1.wav
d21c0dfab81e4aa214b53f84dc00742b521b3891	300176	Strings/Viola Section/pizz/ViolaEns_pizz_F3_v2_rr2.wav
c6f1fcf03c6e58a8271de5241f9ebba587fde53f	239990	Strings/Viola Section/pizz/ViolaEns_pizz_G2_v1_rr1.wav
363365ee2f9dbab59db11e75bf354a1b5d9df4bd	233522	Strings/Viola Section/pizz/ViolaEns_pizz_G2_v1_rr2.wav
848f66b586381b00db427ee53af6812c736ab633	780344	Strings/Viola Section/pizz/ViolaEns_pizz_G2_v2_rr1.wav
7f03df3f840615771554d49f43af240c3ab2f1a8	726512	Strings/Viola Section/pizz/ViolaEns_pizz_G2_v2_rr2.wav
9f0504d7ce462cc908885c87efec1115682ea4bc	123878	Strings/Viola Section/pizz/ViolaEns_pizz_G4_v1_rr1.wav
f16c3d2c5f3f2f5ea80a4599d3721231df2a0bf0	130316	Strings/Viola Section/pizz/ViolaEns_pizz_G4_v1_rr2.wav
f965b64b0a3df20c90778abe2bc20be6f5eabb5a	283118	Strings/Viola Section/pizz/ViolaEns_pizz_G4_v2_rr1.wav
c709c28a81da81ab639bf99aeb84bbabae64cd84	135260	Strings/Viola Section/pizz/ViolaEns_pizz_G4_v2_rr2.wav
7e0fe9260ccaa6dc22332ff4b1e7ec376ac13a47	172336	Strings/Viola Section/spic/Violas_spic_A3_v1_rr1.wav
7f071d51f17e778a57009ee5d7a9b008a8940196	168272	Strings/Viola Section/spic/Violas_spic_A3_v1_rr2.wav
44b2193506505200a49ada7a335d3d1032f6a5d0	213020	Strings/Viola Section/spic/Violas_spic_A3_v2_rr1.wav
354283e800b3fc5a4e2fd3dc078eb88fe700ffc4	200880	Strings/Viola Section/spic/Violas_spic_A3_v2_rr2.wav
00b1eb7ef0e9bda09f47a722bf516cfa313a944a	204768	Strings/Viola Section/spic/Violas_spic_B2_v1_rr1.wav
b5dafc0c0e8b185dbe682f73fff781d1df0fbc6e	206688	Strings/Viola Section/spic/Violas_spic_B2_v1_rr2.wav
0ca70c1a4810a6b40e2a3724aa36b94e2fd661b1	381464	Strings/Viola Section/spic/Violas_spic_B2_v2_rr1.wav
284597f40065c6ed8816d1007d22abe362d19169	348488	Strings/Viola Section/spic/Violas_spic_B2_v2_rr2.wav
f43c8dfe6acb756a3e4b4af6f66543bc683db0d7	138912	Strings/Viola Section/spic/Violas_spic_B4_v1_rr1.wav
303b63a9e49fbddb3f66d683f99f19b4229cb7aa	161560	Strings/Viola Section/spic/Violas_spic_B4_v1_rr2.wav
c0584aea529622c863396ab812e0c73a942de662	193496	Strings/Viola Section/spic/Violas_spic_B4_v2_rr1.wav
aed906fb05ccf322816d4c4cc91003a067f84d0f	185408	Strings/Viola Section/spic/Violas_spic_B4_v2_rr2.wav
26546725ea33650be2efb4bb83d9412ef3a7fc7b	480592	Strings/Viola Section/spic/Violas_spic_C2_v1_rr1.wav
367346aaa0d3c3a7619da8fdf720d4d16cb3fdbf	458248	Strings/Viola Section/spic/Violas_spic_C2_v1_rr2.wav
1b8860fd1fc4a363b24ec7bbf6231059dc2e1eba	497616	Strings/Viola Section/spic/Violas_spic_C2_v2_rr1.wav
4d57d8817155c6bf2a9886f8f4900145bf9b7fa3	547260	Strings/Viola Section/spic/Violas_spic_C2_v2_rr2.wav
ddf5da12e45541bd16f2851ef2ed4c15647bec56	157472	Strings/Viola Section/spic/Violas_spic_C4_v1_rr1.wav
25f23648a77f06b60c6e959d4a3da0f3795330e1	136124	Strings/Viola Section/spic/Violas_spic_C4_v1_rr2.wav
cceb73f75e0edd3f55a486c81f8afa818dc13b64	208272	Strings/Viola Section/spic/Violas_spic_C4_v2_rr1.wav
51d8d5401812ca82f22c34af429bde2ab014481f	208164	Strings/Viola Section/spic/Violas_spic_C4_v2_rr2.wav
c805f017e5c979e5c75deac8395f7ec02c02afc4	185208	Strings/Viola Section/spic/Violas_spic_D3_v1_rr1.wav
90be2e3ad0eb2bb667235cd1607db0018f9fdf26	196864	Strings/Viola Section/spic/Violas_spic_D3_v1_rr2.wav
c9a87c2769b0d900c8dcbc1f9bd4f9bd521eed53	229276	Strings/Viola Section/spic/Violas_spic_D3_v2_rr1.wav
02632aa236013435dbd9485a7eaf0f9f05312d04	272300	Strings/Viola Section/spic/Violas_spic_D3_v2_rr2.wav
b5c91075bf9267719d21c232bc3b6740463f4dbb	112036	Strings/Viola Section/spic/Violas_spic_D5_v1_rr1.wav
d5b32a7f72306872aecf34525512a46b588abbe9	98968	Strings/Viola Section/spic/Violas_spic_D5_v1_rr2.wav
4eb25b19317276dbcee9e5767144d4bda1c5034d	111808	Strings/Viola Section/spic/Violas_spic_D5_v2_rr1.wav
d24469b8f8113af5fcae5ec0ddcc17ce3df3dfd7	105384	Strings/Viola Section/spic/Violas_spic_D5_v2_rr2.wav
3c273e443cec4eaab0087d572c7c991b163c5e64	144364	Strings/Viola Section/spic/Violas_spic_E2_v1_rr1.wav
fed0ed515a247ef69543639d3768db59a42e9fe3	149048	Strings/Viola Section/spic/Violas_spic_E2_v1_rr2.wav
6223e41ace2a4c3d1008d20793c6cbdb23e5f157	271708	Strings/Viola Section/spic/Violas_spic_E2_v2_rr1.wav
222008100682dbed82f52e914c5e8da38639c90b	214036	Strings/Viola Section/spic/Violas_spic_E2_v2_rr2.wav
c002f9119b08ca33e4753b3138c5889552b74843	148856	Strings/Viola Section/spic/Violas_spic_E4_v1_rr1.wav
02d309ba9380d73050699a1cbe979152961c9171	184864	Strings/Viola Section/spic/Violas_spic_E4_v1_rr2.wav
8674892c8fd5b3b767efff0384f7b510b00373aa	216696	Strings/Viola Section/spic/Violas_spic_E4_v2_rr1.wav
d4be5ef49af97700e1431e0fa9728b8ff9857e57	213756	Strings/Viola Section/spic/Violas_spic_E4_v2_rr2.wav
4e3bbfc1ed1bddecbf15bb1ac15488c4d9363d4b	125928	Strings/Viola Section/spic/Violas_spic_F3_v1_rr1.wav
91ecd239a51a8e05d2d3342e00cacc9d2723db76	127564	Strings/Viola Section/spic/Violas_spic_F3_v1_rr2.wav
5c04487955ce47d9f6851fee9da6bbfbd9b95051	157156	Strings/Viola Section/spic/Violas_spic_F3_v2_rr1.wav
6933ddcd167f333374c969c416119964b8b2cf7a	139780	Strings/Viola Section/spic/Violas_spic_F3_v2_rr2.wav
0abf00c92f84da56264333829fe382b9935850a9	196048	Strings/Viola Section/spic/Violas_spic_G2_v1_rr1.wav
d02d3ee8a41945ae40687f9850c4c00a81a8c6af	137708	Strings/Viola Section/spic/Violas_spic_G2_v1_rr2.wav
93129efe05ce1337fde24d013057fa44a0ea831d	211020	Strings/Viola Section/spic/Violas_spic_G2_v2_rr1.wav
af42459a70f5b51345d79a6c4520add841c23c2c	248216	Strings/Viola Section/spic/Violas_spic_G2_v2_rr2.wav
c59252833699782fb9d27dcf24e39a5a2c336621	177596	Strings/Viola Section/spic/Violas_spic_G4_v1_rr1.wav
d7ef4c9ff8ec51480b8fb42453bd6b09b320e5ed	157560	Strings/Viola Section/spic/Violas_spic_G4_v1_rr2.wav
89ef2e483a61ff8533a811c82b07f6044e595701	136532	Strings/Viola Section/spic/Violas_spic_G4_v2_rr1.wav
a407057a4fec9d652b3c3564631e5c2783574d1a	139408	Strings/Viola Section/spic/Violas_spic_G4_v2_rr2.wav
a57d0e5e328257ef14a3dd09b1debea045671527	2491352	Strings/Viola Section/susvib/ViolaEns_susvib_A3_v1_1.wav
b479361fe3bed076db011092b8d48bca54daf83f	2861282	Strings/Viola Section/susvib/ViolaEns_susvib_A3_v2_1.wav
86e2428bca77c49d795e5e3d5be7dd9b022fce65	2861510	Strings/Viola Section/susvib/ViolaEns_susvib_B2_v1_1.wav
0f7bee6ccadc6e25a101cbd7be1c27ac6e896ea4	3268364	Strings/Viola Section/susvib/ViolaEns_susvib_B2_v2_1.wav
66520dad5b544b8e93c48e0f3aa941b3e85bc633	2203118	Strings/Viola Section/susvib/ViolaEns_susvib_B4_v1_1.wav
818ac60340e41f1287024c738d43c5bf3cf7dc9d	2893766	Strings/Viola Section/susvib/ViolaEns_susvib_B4_v2_1.wav
b1cfb66c1ab03bdb9adac7e347b427bc61524b94	2642360	Strings/Viola Section/susvib/ViolaEns_susvib_C2_v1_1.wav
7851268d881b226650cba4ef1d4e9578ae212099	3318188	Strings/Viola Section/susvib/ViolaEns_susvib_C2_v2_1.wav
a88aa6006bbc4ad1b25e4f08eb2d8ac974a7097f	2289656	Strings/Viola Section/susvib/ViolaEns_susvib_C4_v1_1.wav
4561f010d9b6de44b121246731042d1879d38ab7	2954936	Strings/Viola Section/susvib/ViolaEns_susvib_C4_v2_1.wav
d508161e1c7a255d291f1d32f9605a9c215357aa	2359898	Strings/Viola Section/susvib/ViolaEns_susvib_D2_v1_1.wav
bf8a94de83b7d96375bef7c94e07d616f43f9c14	3049772	Strings/Viola Section/susvib/ViolaEns_susvib_D2_v2_1.wav
9a3a65b93d871964a666d6a86deec4d29425d828	2789648	Strings/Viola Section/susvib/ViolaEns_susvib_D3_v1_1.wav
2f6d74aa54f4f23889de311ff85d9f704fb600b9	3596756	Strings/Viola Section/susvib/ViolaEns_susvib_D3_v2_1.wav
57d1de0867673e6861f318c01ed3358ffbff2996	2087798	Strings/Viola Section/susvib/ViolaEns_susvib_D5_v1_1.wav
05a181827b7f6b3f339a92fa8eaf648f352651a5	2638244	Strings/Viola Section/susvib/ViolaEns_susvib_D5_v2_1.wav
6401156b3518b6f39e95fdaefc74cc814d6aceb2	2520044	Strings/Viola Section/susvib/ViolaEns_susvib_E2_v1_1.wav
764698fba8db1da82ecc6b5ec54fe61c0036e4f2	3027656	Strings/Viola Section/susvib/ViolaEns_susvib_E2_v2_1.wav
c97e8f4eeffe3fd94afeb8a3d32099105ab270d2	2044358	Strings/Viola Section/susvib/ViolaEns_susvib_E4_v1_1.wav
c0e669461ba50854dd80e68767604a6f57471cc2	2559086	Strings/Viola Section/susvib/ViolaEns_susvib_E4_v2_1.wav
f9e0fa27802046cf9ed1e6b5625b6a815b3c09e8	2487818	Strings/Viola Section/susvib/ViolaEns_susvib_F3_v1_1.wav
e6b387021b4b98c926d737b2d451037aad087d0e	3471944	Strings/Viola Section/susvib/ViolaEns_susvib_F3_v2_1.wav
7c6dbafbe1f5de539b5861515f1bf39987e354cb	2001644	Strings/Viola Section/susvib/ViolaEns_susvib_G2_v1_1.wav
e8b4cc651229723bc4dcb781d715d6b995b5589d	3637364	Strings/Viola Section/susvib/ViolaEns_susvib_G2_v2_1.wav
2f34fb8b8826e09cf0427d1710b650a5c3dd3010	2542586	Strings/Viola Section/susvib/ViolaEns_susvib_G4_v1_1.wav
54255fd83b3bf242022e61ff6d9fe518401dc537	3103628	Strings/Viola Section/susvib/ViolaEns_susvib_G4_v2_1.wav
da970517a0b4ec56b49aa41133b3ed7bc142d01a	2074040	Strings/Viola Section/trem/Violas_trem_A3_v1_rr1.wav
96a8464c539fb1e666291d77690b7b0c17b516e2	1987664	Strings/Viola Section/trem/Violas_trem_A3_v2_rr1.wav
3fe73c927a2a963ba0da6666b937548e5981ace5	2177152	Strings/Viola Section/trem/Violas_trem_B2_v1_rr1.wav
d1635ae9f437b1d3e5038738340cd17f4e85c069	1893008	Strings/Viola Section/trem/Violas_trem_B2_v2_rr1.wav
538bcbc7af0046a58620e0100a6f4f50dbd77958	1420528	Strings/Viola Section/trem/Violas_trem_B4_v1_rr1.wav
053d615fb9081213878eb9a2e2ff1a51e78bae41	1444092	Strings/Viola Section/trem/Violas_trem_B4_v2_rr1.wav
076adb9742483a5e5af080678c7650b15ec1432b	1856136	Strings/Viola Section/trem/Violas_trem_C2_v1_rr1.wav
4c1c80c65c5cb4b14c45b6f963c8ba9d9a7ac8c5	1835380	Strings/Viola Section/trem/Violas_trem_C2_v2_rr1.wav
77ea4c48c76d4baa2fafc933efdf7fc275fd1dc8	2539680	Strings/Viola Section/trem/Violas_trem_C4_v1_rr1.wav
2683517d9d92af84561c81b06181ad8f46509017	1518068	Strings/Viola Section/trem/Violas_trem_C4_v2_rr1.wav
8fa3369368b2ca7d7af6514090834794864ab2af	2680800	Strings/Viola Section/trem/Violas_trem_D3_v1_rr1.wav
77b862bb6b6f888ce3f0f2008ef458317c04f182	1895296	Strings/Viola Section/trem/Violas_trem_D3_v2_rr1.wav
21c5efcbe323c14f111c5379e74b191fa093e048	2319296	Strings/Viola Section/trem/Violas_trem_D5_v1_rr1.wav
1ceea7ec61b530e7cac662736c7b3ff17609d385	1300320	Strings/Viola Section/trem/Violas_trem_D5_v2_rr1.wav
e0da8dd1efbfe34fbec2baa041f070496ff2cccd	2337132	Strings/Viola Section/trem/Violas_trem_E2_v1_rr1.wav
a8c4d999c6c3ba4c540fe37d579d3fb0ebd0a58f	1824436	Strings/Viola Section/trem/Violas_trem_E2_v2_rr1.wav
9a63f06c388479300c3e0a9a65448cba2efa84c7	2187412	Strings/Viola Section/trem/Violas_trem_E4_v1_rr1.wav
b53402e7d523c5ab247b03c9aa14d5d220761093	1857696	Strings/Viola Section/trem/Violas_trem_E4_v2_rr1.wav
78de378e709c31d44df0a9f5ec635ad0e6dc1018	2746992	Strings/Viola Section/trem/Violas_trem_F3_v1_rr1.wav
e9b13f88e23b8260b0cf0099a236de8ddc1cb523	1536124	Strings/Viola Section/trem/Violas_trem_F3_v2_rr1.wav
755e30e9eda3d4be101a1f8af2f09a352bfb54cb	1934756	Strings/Viola Section/trem/Violas_trem_G2_v1_rr1.wav
9db44006222aa0ed88b4e3bc334775145e0e7fc0	1603596	Strings/Viola Section/trem/Violas_trem_G2_v2_rr1.wav
63471997b9184ce8e1446570e1b00c97b84ed826	1919520	Strings/Viola Section/trem/Violas_trem_G4_v1_rr1.wav
b8d2bfff5e73aff650a72a37ea83a5c9f744bcad	1411504	Strings/Viola Section/trem/Violas_trem_G4_v2_rr1.wav
93b98c5260e23178abca15764e43b2d61f0ee86a	220926	Strings/Violin Section/Pizz/VlnEns_Pizz_A2_v1_rr1.wav
dbdb03af973cfbadefe9c6493dd37d3affaba346	247290	Strings/Violin Section/Pizz/VlnEns_Pizz_A2_v1_rr2.wav
67424af2bfc19cbac72eee6a8fdba6acebbf735e	187354	Strings/Violin Section/Pizz/VlnEns_Pizz_A2_v2_rr1.wav
537e430bb5d41680acb11848e489708bd6070b82	315758	Strings/Violin Section/Pizz/VlnEns_Pizz_A2_v2_rr2.wav
06793268b9279f7cac16e997732515851e619173	163490	Strings/Violin Section/Pizz/VlnEns_Pizz_A3_v1_rr1.wav
e9e5a1ce6277be3cee527230e50923ec043d1bdc	180382	Strings/Violin Section/Pizz/VlnEns_Pizz_A3_v1_rr2.wav
251db5f874e4d431601a5f76b7a780cc1e5ef489	194010	Strings/Violin Section/Pizz/VlnEns_Pizz_A3_v2_rr1.wav
9e489802b42cd46908eb4244fa8383c287a29bc0	205482	Strings/Violin Section/Pizz/VlnEns_Pizz_A3_v2_rr2.wav
3c5e8e9cc23e4832f7cd6e3b467e05edc8375761	124886	Strings/Violin Section/Pizz/VlnEns_Pizz_B2_v1_rr1.wav
aafef0e36416a366a75565897e7355b842814194	116098	Strings/Violin Section/Pizz/VlnEns_Pizz_B2_v1_rr2.wav
13603a872baf1c825d6f1adea446033872b3995e	180134	Strings/Violin Section/Pizz/VlnEns_Pizz_B2_v2_rr1.wav
1d3f09cec45d4ca9ffe3cde92a7122e05a805faa	292378	Strings/Violin Section/Pizz/VlnEns_Pizz_B2_v2_rr2.wav
a05d57ce0a3cf310aed9d9349c122a89e5394a0f	88054	Strings/Violin Section/Pizz/VlnEns_Pizz_B4_v1_rr1.wav
0fd7442a37efe97c44185386554bd03a9a980b03	92066	Strings/Violin Section/Pizz/VlnEns_Pizz_B4_v1_rr2.wav
521e295e499f4b578c6f31f5a26968b03beb77d5	106362	Strings/Violin Section/Pizz/VlnEns_Pizz_B4_v2_rr1.wav
27fcda44d85a84c72ceb69e29260457b6c19bee0	126302	Strings/Violin Section/Pizz/VlnEns_Pizz_B4_v2_rr2.wav
435b07a8821b1ce9bc2c3347faa2304e0075b4c7	105914	Strings/Violin Section/Pizz/VlnEns_Pizz_C4_v1_rr1.wav
9c30ba07f8c7f032ffe9b385fa4f6c15a2f9338a	122922	Strings/Violin Section/Pizz/VlnEns_Pizz_C4_v1_rr2.wav
2321eac4b4d5b26823a89e56a98e232fc143e121	184590	Strings/Violin Section/Pizz/VlnEns_Pizz_C4_v2_rr1.wav
f5123c18b79f336e52489f57edf792768598d70d	197238	Strings/Violin Section/Pizz/VlnEns_Pizz_C4_v2_rr2.wav
81edb847a315aaab80bcb96b0531554e5dcd7683	280306	Strings/Violin Section/Pizz/VlnEns_Pizz_D3_v1_rr1.wav
823cdc568bb895512620b025abd456f33e720e21	375514	Strings/Violin Section/Pizz/VlnEns_Pizz_D3_v1_rr2.wav
72d0589858c7bcd1e8c616c9ae5e384dd53851be	391226	Strings/Violin Section/Pizz/VlnEns_Pizz_D3_v2_rr1.wav
d4af565c80bcc9b5946eef87efc94040c3e2922d	410238	Strings/Violin Section/Pizz/VlnEns_Pizz_D3_v2_rr2.wav
c5757bfbc85366ee0fb73137a51f36bedbdb3503	122870	Strings/Violin Section/Pizz/VlnEns_Pizz_D5_v1_rr1.wav
fd683dfdf89fb6ba82366ebf7758a8164b9bd8fe	77634	Strings/Violin Section/Pizz/VlnEns_Pizz_D5_v1_rr2.wav
85833b67611f3bb3e1c082721d62269f305e0afa	113286	Strings/Violin Section/Pizz/VlnEns_Pizz_D5_v2_rr1.wav
e39ebc0f6a7a69115a1ebd1e123766ae1addb2d7	125806	Strings/Violin Section/Pizz/VlnEns_Pizz_D5_v2_rr2.wav
c365d0d634fe675af05e97a90f427c8ed2152d26	109318	Strings/Violin Section/Pizz/VlnEns_Pizz_E4_v1_rr1.wav
158eb24a6e312d10ba81a15de1b8c5e71277aa72	150326	Strings/Violin Section/Pizz/VlnEns_Pizz_E4_v1_rr2.wav
34adeb666686974d1a7c2eab5ff6109014b96908	146742	Strings/Violin Section/Pizz/VlnEns_Pizz_E4_v2_rr1.wav
466e0a071c8a3e00baabda9db655447b30dab2aa	167882	Strings/Violin Section/Pizz/VlnEns_Pizz_E4_v2_rr2.wav
d8da392b5c5b778897eb9bc4e1e3ccb9cef06941	197422	Strings/Violin Section/Pizz/VlnEns_Pizz_F#3_v1_rr1.wav
b8876db06c7edbbbb828247458e79cb3e659e870	135562	Strings/Violin Section/Pizz/VlnEns_Pizz_F#3_v1_rr2.wav
db2ec270d423f9c4ef156bb11ad96c9d23a36883	157066	Strings/Violin Section/Pizz/VlnEns_Pizz_F#3_v2_rr1.wav
13050c58147c0ade173a32e1167d5c85cef1e082	176738	Strings/Violin Section/Pizz/VlnEns_Pizz_F#3_v2_rr2.wav
4078199c3a83b088af2374801bf02a69a34e2692	409242	Strings/Violin Section/Pizz/VlnEns_Pizz_G2_v1_rr1.wav
ecdd5249b71aaf4147e9ee80f9f3e1221c6c46e1	459646	Strings/Violin Section/Pizz/VlnEns_Pizz_G2_v1_rr2.wav
3ec99d0f2abd24e4fc18cf5ce5db320d7974b0ba	532010	Strings/Violin Section/Pizz/VlnEns_Pizz_G2_v2_rr1.wav
a8787f3fd98f15b518fd21fb9a0d51e0ac0c397d	437694	Strings/Violin Section/Pizz/VlnEns_Pizz_G2_v2_rr2.wav
6854ee3feb04c2ad33290768f4704dee8d73edc1	148766	Strings/Violin Section/Pizz/VlnEns_Pizz_G4_v1_rr1.wav
99ac3b68d02d9fec1d569132977d5954bca20b5c	82618	Strings/Violin Section/Pizz/VlnEns_Pizz_G4_v1_rr2.wav
9a723d81746d3241c1adcea38fc925fed558c735	184102	Strings/Violin Section/Pizz/VlnEns_Pizz_G4_v2_rr1.wav
bb9a2169ec4e0aae4645ca6009f94d16503ba1a0	170178	Strings/Violin Section/Pizz/VlnEns_Pizz_G4_v2_rr2.wav
a794cbe840ac88a90b2b23faee573f71e9ef1d91	327090	Strings/Violin Section/Spic/VlnEns_Spic_A2_v1_rr1.wav
ac8c4f4a4b596ff63600781a9356a94505391577	339302	Strings/Violin Section/Spic/VlnEns_Spic_A2_v1_rr2.wav
c1cfa82aa2b930acbacb8b1cbffc3a1158a3a0ad	347066	Strings/Violin Section/Spic/VlnEns_Spic_A2_v2_rr1.wav
b2f9297553bb58fdbc99b8119935d6fa215397d9	272346	Strings/Violin Section/Spic/VlnEns_Spic_A2_v2_rr2.wav
073f359ff4708b93240798353c79b98c7ba92833	167582	Strings/Violin Section/Spic/VlnEns_Spic_A3_v1_rr1.wav
4cd283726571e71438974e88361f6b0bc3c05746	158622	Strings/Violin Section/Spic/VlnEns_Spic_A3_v1_rr2.wav
fb4ac5e085c3d9e4a0623247a74004cbd8881f9b	213126	Strings/Violin Section/Spic/VlnEns_Spic_A3_v2_rr1.wav
c93c24bab8ebc7573a91f8763a665876f81febe0	246210	Strings/Violin Section/Spic/VlnEns_Spic_A3_v2_rr2.wav
21f5bd5721f3e9aa124ad55164127ef80d0caddb	115554	Strings/Violin Section/Spic/VlnEns_Spic_B2_v1_rr1.wav
367ddae427eb9a12a3a09a432cf6e09ecf941d11	131774	Strings/Violin Section/Spic/VlnEns_Spic_B2_v1_rr2.wav
11b255c4b3c717ce345ecf3eb0d98638d75e1b1d	160826	Strings/Violin Section/Spic/VlnEns_Spic_B2_v2_rr1.wav
a1aab1c6b72d88849f17c5ad5372f090f33ff8b9	172390	Strings/Violin Section/Spic/VlnEns_Spic_B2_v2_rr2.wav
47b96870f42bcba7ce40bf38d330f5a9a04ca580	182342	Strings/Violin Section/Spic/VlnEns_Spic_B4_v1_rr1.wav
f7d7acb3ee6c33acd24cf0712507a14cc33beecb	153682	Strings/Violin Section/Spic/VlnEns_Spic_B4_v1_rr2.wav
d91c54ffcecbef31708a0a9439907945f9843a08	199926	Strings/Violin Section/Spic/VlnEns_Spic_B4_v2_rr1.wav
3e8898b02d05583d87fdd634266f034ddb583acd	168810	Strings/Violin Section/Spic/VlnEns_Spic_B4_v2_rr2.wav
70a464d3dd61d21e36b209573475345f4e36b46b	130390	Strings/Violin Section/Spic/VlnEns_Spic_C4_v1_rr1.wav
6b6d5f9f694f94f6023e85d295d6fff6837373a7	110434	Strings/Violin Section/Spic/VlnEns_Spic_C4_v1_rr2.wav
ae3b8629fbbdb12ca1c6627ecdc5c0228ecb9ed0	167454	Strings/Violin Section/Spic/VlnEns_Spic_C4_v2_rr1.wav
8ce6ba371c35d70704829e8923a0aab4621b1aa1	124626	Strings/Violin Section/Spic/VlnEns_Spic_C4_v2_rr2.wav
f23740af6543f553cf2e4483d6177f600bc6730d	212730	Strings/Violin Section/Spic/VlnEns_Spic_D3_v1_rr1.wav
a487a679c85544f696c2bec7e1915dbfb0503913	251726	Strings/Violin Section/Spic/VlnEns_Spic_D3_v1_rr2.wav
4894f893f93143180d5234212d0440110dac0b8f	311850	Strings/Violin Section/Spic/VlnEns_Spic_D3_v2_rr1.wav
ec4376833eaffafb05c1895ed2f31b0f22552f57	290746	Strings/Violin Section/Spic/VlnEns_Spic_D3_v2_rr2.wav
c54eb32ceef868f25e37af20d9c22c2ee9017443	107654	Strings/Violin Section/Spic/VlnEns_Spic_D5_v1_rr1.wav
f186358c67a144532926b5c3c44ca559436b14dd	124034	Strings/Violin Section/Spic/VlnEns_Spic_D5_v1_rr2.wav
8eb20bdd3d40ecfc18e2e9c3e59a299710e86d60	136734	Strings/Violin Section/Spic/VlnEns_Spic_D5_v2_rr1.wav
828f82b17a84757411474bcd781897b2d42353a9	124686	Strings/Violin Section/Spic/VlnEns_Spic_D5_v2_rr2.wav
2449f9d5cd6337530ae52c06b92c0f99b5f81a7d	87666	Strings/Violin Section/Spic/VlnEns_Spic_E4_v1_rr1.wav
31306b62cd518bbe0d4e793c2c9eb598c06e9e73	183402	Strings/Violin Section/Spic/VlnEns_Spic_E4_v1_rr2.wav
f95512f43f61703daa2c436071627ef6b7bb6a9d	106314	Strings/Violin Section/Spic/VlnEns_Spic_E4_v2_rr1.wav
c9b02904df2283cf50b765e9b16c6ccfb4c78042	134190	Strings/Violin Section/Spic/VlnEns_Spic_E4_v2_rr2.wav
a1440411347da6c7ea3e2ea5e23d4ed5c65b5b98	126294	Strings/Violin Section/Spic/VlnEns_Spic_F#3_v1_rr1.wav
48ae2a53909309538a65e40184f4d0885b3dbe53	112254	Strings/Violin Section/Spic/VlnEns_Spic_F#3_v1_rr2.wav
f08c57a675190d1f562d4055b8fda58064f69cdc	166870	Strings/Violin Section/Spic/VlnEns_Spic_F#3_v2_rr1.wav
2e51e90cf6031974c73c1045a7c97f1e6587140b	192442	Strings/Violin Section/Spic/VlnEns_Spic_F#3_v2_rr2.wav
df1b9212691c50ed94ad3b04c6c06d4c3d72bbd9	544838	Strings/Violin Section/Spic/VlnEns_Spic_G2_v1_rr1.wav
3f58d27e4b2f99a20170a580412eb0199c08aea9	565874	Strings/Violin Section/Spic/VlnEns_Spic_G2_v1_rr2.wav
617e0e35885885eced13fb75f1d25603e52852ea	435542	Strings/Violin Section/Spic/VlnEns_Spic_G2_v2_rr1.wav
8f35c6ad7e74d6f48fb8d2fab89490f080b7b8c9	428774	Strings/Violin Section/Spic/VlnEns_Spic_G2_v2_rr2.wav
6756b5aed1346ee2a4e775906977ef684e8a3627	193166	Strings/Violin Section/Spic/VlnEns_Spic_G4_v1_rr1.wav
3bcc89bc715de8f6f17feccfb98cc5bb024e142e	221382	Strings/Violin Section/Spic/VlnEns_Spic_G4_v1_rr2.wav
59f932de2ed91cb8148b600a2a1a4fd0e0914421	162898	Strings/Violin Section/Spic/VlnEns_Spic_G4_v2_rr1.wav
56f44b7808cbb5570dbdc90487f1dc1a5b398326	154078	Strings/Violin Section/Spic/VlnEns_Spic_G4_v2_rr2.wav
b28d43995483f64a32dfaddbdd8769f8fd35ad89	2002132	Strings/Violin Section/Trem/VlnEns_Trem_A2_v1.wav
2a6c4a738e82fe0c29715a1ad23c4605b0bd13f6	1543864	Strings/Violin Section/Trem/VlnEns_Trem_A2_v2.wav
6ca230c6b393661456b0bd423171698ed0e6961e	1702732	Strings/Violin Section/Trem/VlnEns_Trem_A3_v1.wav
66d1023bfd02f10777084846c854141139e7db6d	1469244	Strings/Violin Section/Trem/VlnEns_Trem_A3_v2.wav
79681a92f03713cd267d3960e9523b42fb3525bd	1777112	Strings/Violin Section/Trem/VlnEns_Trem_B2_v1.wav
636136978b92eb10217260588dfd7e70f1c7334c	1682428	Strings/Violin Section/Trem/VlnEns_Trem_B2_v2.wav
e65a4bd927527566921ab8bf848dd2d93823c8e3	1661532	Strings/Violin Section/Trem/VlnEns_Trem_B4_v1.wav
2ef3f2574e116829c9a76ddfb8969a63971052f0	1334516	Strings/Violin Section/Trem/VlnEns_Trem_B4_v2.wav
09557ef0aacba149134d4d2a002810521040645d	1633776	Strings/Violin Section/Trem/VlnEns_Trem_C4_v1.wav
1e3ff9d3bfbada89c199fed5ec2ce59f00161d9c	1432052	Strings/Violin Section/Trem/VlnEns_Trem_C4_v2.wav
2e8354f7829d070b6a974c36c56bcc3544678ee4	2316212	Strings/Violin Section/Trem/VlnEns_Trem_D3_v1.wav
49809c75b1bc8a2aaf2ff41a258676a43de1ee20	1802456	Strings/Violin Section/Trem/VlnEns_Trem_D3_v2.wav
3f0242daabc16c55a28ff270861583a2b7318fc0	1404632	Strings/Violin Section/Trem/VlnEns_Trem_D5_v1.wav
2cc6241c28707d5b7628347f0d49bd5d2311acec	1650800	Strings/Violin Section/Trem/VlnEns_Trem_D5_v2.wav
79a43accef11a57dde4a39b6b7aef0d291834661	1555896	Strings/Violin Section/Trem/VlnEns_Trem_E4_v1.wav
d5c2c00f2317e4bab5b30052f0e0090371ffae93	1400056	Strings/Violin Section/Trem/VlnEns_Trem_E4_v2.wav
1384eeefa5ddd8423f47f492cdef76d3b0197e48	1829444	Strings/Violin Section/Trem/VlnEns_Trem_F#3_v1.wav
45da6cab10e5cc2581319f99f64f18cfbe6f35ed	1937288	Strings/Violin Section/Trem/VlnEns_Trem_G2_v1.wav
c33077784fb76dc501a7957af7f0d5e387de368c	1850860	Strings/Violin Section/Trem/VlnEns_Trem_G2_v2.wav
7383ee7406104a63393ea279a73305b60b2e88fa	1717532	Strings/Violin Section/Trem/VlnEns_Trem_G4_v1.wav
773928f8f54d93b099250e1c70901928b8681f83	1487868	Strings/Violin Section/Trem/VlnEns_Trem_G4_v2.wav
b86c2e7000da2a80466196acca2ddbdf6cf83fe8	1979216	Strings/Violin Section/susVib/VlnEns_susVib_A2_v1.wav
5960b46c4678a146834594031d0bba1048855102	2231504	Strings/Violin Section/susVib/VlnEns_susVib_A2_v2.wav
ec84b89a4b93ecdc7e23d0c023b897b6f151bca7	1890316	Strings/Violin Section/susVib/VlnEns_susVib_A3_v1.wav
401653718e521b65712da594a53d22184f4a207a	1671704	Strings/Violin Section/susVib/VlnEns_susVib_A3_v2.wav
c2bdf89eed02c0e7fbb11b52799ac62276787ff8	2314360	Strings/Violin Section/susVib/VlnEns_susVib_B2_v1.wav
4f54ea9180f4c11ec3d0e92f556003be59cb0f0c	2373380	Strings/Violin Section/susVib/VlnEns_susVib_B2_v2.wav
8e22cb66ba5bccb4df68decf98139b3008733e8a	2056964	Strings/Violin Section/susVib/VlnEns_susVib_B4_v1.wav
598c11bd6fb25e33c599836428e03336ad5a5031	1923744	Strings/Violin Section/susVib/VlnEns_susVib_B4_v2.wav
6d81fcafba04ca992a8b85665a56e60337929ce0	2063320	Strings/Violin Section/susVib/VlnEns_susVib_C4_v1.wav
1c8e05059b270f870342a03e19b93882d6dd1e1b	2017512	Strings/Violin Section/susVib/VlnEns_susVib_C4_v2.wav
e47f9a53d487475fb049039ca7846e11c1ff830a	2061808	Strings/Violin Section/susVib/VlnEns_susVib_D3_v1.wav
31143ae1a31ddd57baa38b3e79a4415b108a0007	2457908	Strings/Violin Section/susVib/VlnEns_susVib_D3_v2.wav
fa455a7f8fe8c5c00b36c8e131bbc340204ae1c8	2116352	Strings/Violin Section/susVib/VlnEns_susVib_D5_v1.wav
804a72a49c07eed754e377b354f8e54a4805476d	1976276	Strings/Violin Section/susVib/VlnEns_susVib_D5_v2.wav
838b43d3c9e763898817869d411ab26463b7464f	2315540	Strings/Violin Section/susVib/VlnEns_susVib_E4_v1.wav
2c33cc296b9b3654fd08fc9e9887042eabee738d	1702620	Strings/Violin Section/susVib/VlnEns_susVib_E4_v2.wav
996ca7e6b1d9541d2f2fd7f53ba88294693893e7	1585612	Strings/Violin Section/susVib/VlnEns_susVib_F#3_v1.wav
33a19df9d89a5dbb174b9f72e6ae79a07327b2b6	1720800	Strings/Violin Section/susVib/VlnEns_susVib_F#3_v2.wav
e2de84e8b912dbfb8df3efe7b8ee241e2bcfa027	2341712	Strings/Violin Section/susVib/VlnEns_susVib_G2_v1.wav
b7693eb5c9d104fc01e130ee2552dac546ee85f7	2681324	Strings/Violin Section/susVib/VlnEns_susVib_G2_v2.wav
81d3994ebbf467cbbc88bb2d2ad0dd94d96e7e04	2330236	Strings/Violin Section/susVib/VlnEns_susVib_G4_v1.wav
c36674326c6d0b6ae8bf5d20b52b6ddd005719bb	2150136	Strings/Violin Section/susVib/VlnEns_susVib_G4_v2.wav
7bf3a81ab0718e051874bb8ea3806dc10c4cdbed	3415	Timpani.sfz
903e36585901522fab68b4aa7cb292dfe20fac2e	1336	TimpaniRolls.sfz
6e60edef55889d4ff78f82971f9d9b81bc40987a	6403	TromboneStac.sfz
b109b4135b0658d8003a986c51f7c5b4d55f786b	3550	TromboneSus.sfz
a560513d221fc92b84ec1d27747f29b923631cde	1480	TromboneVib.sfz
d22cb0ee296591ecf1c2f428ca7829a50af7ae5e	2192	TrumpetHarmonMuteSus.sfz
64f2092f3071770882b9ca4e7725fd8b0e37b9cb	7928	TrumpetStac.sfz
7203241954188ff67a4489f001b4d8749f146219	2222	TrumpetStraightMuteSus.sfz
2b9be543a5179638788f8766dc1c181956975025	2510	TrumpetSus.sfz
c57891b0b7a6747ed7d862fa7fde9ef5ca744a1b	2808	TrumpetSusVib.sfz
f785dd760fb95d6aa7f654e5db11df1d33b732e7	10826	Tuba-KS.sfz
55855036917d5b47f4243892b8b17e2de713fb79	7629	TubaStac.sfz
68e19dda5c86409f826baba95d294ad611d0e0a5	2737	TubaSus.sfz
642fa96bb32942cdff10cfd052d55ad2a17d086e	621	TubularBells.sfz
21418f4149e61a098c21ce34d6fec0c4ef1838b0	7614	UprightPiano.sfz
8718cadcf5e03df456cc48505a54ff5a3d4f463f	8579	VSUpright1.sfz
05266b8ce4866aba9acd54d8fafab7f59bc7c7b1	17175	ViolaEns-KS.sfz
2034dedbca5089ed67ca8c8f46070b3cc8e43068	5374	ViolaEnsPizz.sfz
dc5172156a61094db4adfc1f83f68540f5311836	5514	ViolaEnsSpic.sfz
56d7c8097fed3a5158dcc0ad0c863ad7aa6fae74	1631	ViolaEnsSusVib-Quiet.sfz
7e0e643701a26acf5676dd6c1327ee436ab43c97	3063	ViolaEnsSusVib.sfz
42877562ba0f0d5015cc1a3007b3c570a10632d8	2793	ViolaEnsTrem.sfz
4ea829f19ad33cfd4dfae7b8a904cec7c296f592	15431	ViolinEns-KS.sfz
dbe55d6cc6e7ca9d810b985292b92fdc1d1467ee	5069	ViolinEnsPizz.sfz
bbe09a5b146546da908a10a5598b4bad41e65dd9	5085	ViolinEnsSpic.sfz
2750b93d68de0a49ed16c9731dc90f037ae2e762	1368	ViolinEnsSusVib-Quiet.sfz
07f05f5ad2cccb0d19b1902bc67ffa49cf15bc68	2538	ViolinEnsSusVib.sfz
65617743b6ee30582d35747e5a5b0a20e67e8c44	2387	ViolinEnsTrem.sfz
ce2bc4094565345f44b5cf850b9e57026d58c6c4	122556	Woodwinds/Bassoon/stac/PSBassoon_A#0_v2_rr1.wav
720a5c636ef8be4bd0929b33273e2bc1a7bf1b49	126684	Woodwinds/Bassoon/stac/PSBassoon_A#0_v2_rr2.wav
cd178513ae9774f303d9436a0335d7f66ae5e4f5	106804	Woodwinds/Bassoon/stac/PSBassoon_A1_v1_rr1.wav
22cbef86155cfc3a2ccc4a0ac85c6928361d33c1	104220	Woodwinds/Bassoon/stac/PSBassoon_A1_v1_rr2.wav
37450504ae6befd51050d5cd96f800d57de44674	120412	Woodwinds/Bassoon/stac/PSBassoon_A1_v2_rr1.wav
5a55df6e1acd17fbbc17a7c74b97db769dcf4107	119848	Woodwinds/Bassoon/stac/PSBassoon_A1_v2_rr2.wav
d45730d343860402cc4e32d7edb9eda1cfd41f0b	102420	Woodwinds/Bassoon/stac/PSBassoon_A2_v1_rr1.wav
6e97c6292ae8ad07d824577b571c4454f2503e2f	97760	Woodwinds/Bassoon/stac/PSBassoon_A2_v1_rr2.wav
d445fde73e3a391d86e28f8eb63fcb91754ebe79	132928	Woodwinds/Bassoon/stac/PSBassoon_A2_v2_rr1.wav
1fd0821a3dbd67b72987eac167eca3570f0fd301	123256	Woodwinds/Bassoon/stac/PSBassoon_A2_v2_rr2.wav
b79049b29c83c481c5000af8103d506cb42dd32b	117316	Woodwinds/Bassoon/stac/PSBassoon_C2_v1_rr1.wav
49dc81c8573368743c4b66647d43b90053e9e04d	120260	Woodwinds/Bassoon/stac/PSBassoon_C2_v1_rr2.wav
09c3c9fc98e243d444e282a7db4fcfc9c600ba33	125524	Woodwinds/Bassoon/stac/PSBassoon_C2_v2_rr1.wav
6e99494f058964f7fb2242adfa61f5f8b33b515f	130840	Woodwinds/Bassoon/stac/PSBassoon_C2_v2_rr2.wav
d2c2b2d05947226c4b77bb48af6cc3ce33602a24	117228	Woodwinds/Bassoon/stac/PSBassoon_C3_v1_rr1.wav
6c3cc54c5de792097a5d1756a067b8e5489f7a13	115880	Woodwinds/Bassoon/stac/PSBassoon_C3_v1_rr2.wav
3b45a2db7642213a94f9082ec5869c1e626f2328	126972	Woodwinds/Bassoon/stac/PSBassoon_C3_v2_rr1.wav
a5458c14b2a0f0d230264d657b1da04b284c7b68	129144	Woodwinds/Bassoon/stac/PSBassoon_C3_v2_rr2.wav
672f772dae0e8f846309d4ffe3bc2940d65362c9	116356	Woodwinds/Bassoon/stac/PSBassoon_C4_v1_rr1.wav
a5b53cc0ccfa11a5bb4a763a37e6374c37a043f9	122468	Woodwinds/Bassoon/stac/PSBassoon_C4_v1_rr2.wav
43e21c5ea380df6a4a5da45e4976fc8573f3f828	124568	Woodwinds/Bassoon/stac/PSBassoon_C4_v2_rr1.wav
0a82462a15b8856418e92250d08339a7961ba980	122732	Woodwinds/Bassoon/stac/PSBassoon_C4_v2_rr2.wav
93dfa97f79e0057c227723ffd7642386070ea7e8	132692	Woodwinds/Bassoon/stac/PSBassoon_D#2_v2_rr1.wav
bf8fe365924d2cca9f3dd5d970c00c98c7225884	138780	Woodwinds/Bassoon/stac/PSBassoon_D#2_v2_rr2.wav
edaa84851385133fcfff9f5c3d34d254d4254b58	122984	Woodwinds/Bassoon/stac/PSBassoon_D1_v2_rr1.wav
428ab847a9ae70c1595a83f91063d66478187316	128184	Woodwinds/Bassoon/stac/PSBassoon_D1_v2_rr2.wav
5a54606185a6f609b755606f19bdf5d85519bea7	133028	Woodwinds/Bassoon/stac/PSBassoon_E2_v1_rr1.wav
31163aaed492a2ba4dd61d378ff27f76850a998e	125288	Woodwinds/Bassoon/stac/PSBassoon_E2_v1_rr2.wav
cd2fbaee22fc1b7f4564a6362163cadee36dd4fb	137972	Woodwinds/Bassoon/stac/PSBassoon_E2_v2_rr1.wav
02536f5989e5c71b190f001a0b0cfa3ef511e723	136176	Woodwinds/Bassoon/stac/PSBassoon_E2_v2_rr2.wav
cf0656d519a542051f1e831ae0945ba8d25b4fb9	126936	Woodwinds/Bassoon/stac/PSBassoon_E3_v1_rr1.wav
a5e302a1facb78a5353001c5ea033a6a8f738229	124928	Woodwinds/Bassoon/stac/PSBassoon_E3_v1_rr2.wav
074cd8414e2c0fa7d55176d2ac3cc2fb5c8552e5	125328	Woodwinds/Bassoon/stac/PSBassoon_E3_v2_rr1.wav
eccb61086fa0f4b5e4d61a0f2aef5a5f1bfd5a6c	125344	Woodwinds/Bassoon/stac/PSBassoon_E3_v2_rr2.wav
538154e1284a919b92d040da9903f464bc65a82f	120488	Woodwinds/Bassoon/stac/PSBassoon_F1_v1_rr1.wav
080ccf5bb02b67b5469740d216d4bfc93be8824c	114000	Woodwinds/Bassoon/stac/PSBassoon_F1_v1_rr2.wav
5c48832f84e3a49419ab17814f0caf276030725f	131620	Woodwinds/Bassoon/stac/PSBassoon_F1_v2_rr1.wav
6a672091b73d543124f48c782749fbda6f0d8872	143496	Woodwinds/Bassoon/stac/PSBassoon_F1_v2_rr2.wav
4cabb830d1d6595fd57f88c214cb19fa061215d3	114008	Woodwinds/Bassoon/stac/PSBassoon_G2_v1_rr1.wav
4ff26462048d34fffc00bb77a6bec6e4b1df6085	117340	Woodwinds/Bassoon/stac/PSBassoon_G2_v1_rr2.wav
5d238aedb1eeec47fb0831eb44a9c01400d9aa38	134460	Woodwinds/Bassoon/stac/PSBassoon_G2_v2_rr1.wav
fd2ed32fbf198d0f279d6de73bb81eb64e5966d6	143912	Woodwinds/Bassoon/stac/PSBassoon_G2_v2_rr2.wav
62cc463dd7e17de25cf8ba47252fbe165e458f47	122860	Woodwinds/Bassoon/stac/PSBassoon_G3_v1_rr1.wav
a41a94c33ba537f1025f0772dcc9b8fc80b68ef4	128528	Woodwinds/Bassoon/stac/PSBassoon_G3_v1_rr2.wav
70a76ab5128efc3d23beb138fa8cf7d7b3fb7fea	131664	Woodwinds/Bassoon/stac/PSBassoon_G3_v2_rr1.wav
23158586d9c8cc62e9dc450a3856451fa7f010bc	129804	Woodwinds/Bassoon/stac/PSBassoon_G3_v2_rr2.wav
f99b00f4944c8571dabc04683549935e4a81c987	1604336	Woodwinds/Bassoon/sus/PSBassoon_A#0_v1_1.wav
40be07cae85c8038a0bc2790f55391ba05bfd9ca	1277208	Woodwinds/Bassoon/sus/PSBassoon_A#0_v2_1.wav
ddd0d4eace186255cb3cd3fe1f9bfa4bc8507947	1305956	Woodwinds/Bassoon/sus/PSBassoon_A#1_v1_1.wav
d216c128e16b6e82e203e65cb3e5374873125b95	1139172	Woodwinds/Bassoon/sus/PSBassoon_A#1_v2_1.wav
cb1109d73a34b69c08b52a2398fb0ba4b775f852	1590160	Woodwinds/Bassoon/sus/PSBassoon_A1_v1_1.wav
1c0cbd04167c64567abd3e292c2ba20602f22cea	1272168	Woodwinds/Bassoon/sus/PSBassoon_A1_v2_1.wav
59c1fb41b41670807ad44d06d0f54fecac4fa0ae	1713280	Woodwinds/Bassoon/sus/PSBassoon_A3_v1_1.wav
b0056a9582d14d97ca93d3c0b3b67637ad444bfe	1711380	Woodwinds/Bassoon/sus/PSBassoon_A3_v2_1.wav
b79ee313cb48502ab0aa8dec46bc9fb5e4077988	1090836	Woodwinds/Bassoon/sus/PSBassoon_C#1_v1_1.wav
2f91082298b60cf5a3b04b2f089ff7380e6ba90d	1053324	Woodwinds/Bassoon/sus/PSBassoon_C#1_v2_1.wav
10ff119e43e0785b606bd4c1586dcb62bf6be6b5	1121404	Woodwinds/Bassoon/sus/PSBassoon_C2_v1_1.wav
14b9d5e95ccd565ea9e3eb2b8ef8c641ac3ac022	1118832	Woodwinds/Bassoon/sus/PSBassoon_C2_v2_1.wav
346fcf577136aac725b49419a915c92efa078d6a	1540544	Woodwinds/Bassoon/sus/PSBassoon_C3_v1_1.wav
7778b0fa352d6466272f2e0a7b053ca38ac1e35f	1394452	Woodwinds/Bassoon/sus/PSBassoon_C3_v2_1.wav
b046554b78d5edaaeb4a81d045833365253bae60	1969476	Woodwinds/Bassoon/sus/PSBassoon_C4_v1_1.wav
0c1d22dd2f18c5dabfcb6a5d6ac694f3f0c8dd71	1737168	Woodwinds/Bassoon/sus/PSBassoon_C4_v2_1.wav
f11eba53f3d278cb38b79af9d62b5b769393bbdd	1524036	Woodwinds/Bassoon/sus/PSBassoon_D#3_v1_1.wav
567d185f861d30cde23a3843f86fc907cf130720	1111204	Woodwinds/Bassoon/sus/PSBassoon_D#3_v2_1.wav
1302bf15411e3bc017686c9094c6bfa1563ed176	1304912	Woodwinds/Bassoon/sus/PSBassoon_D#4_v2_1.wav
ef632d2b0dc9970afb62c5945413d4da628883fb	1751604	Woodwinds/Bassoon/sus/PSBassoon_F1_v1_1.wav
6b6c81a47d6e77853dd711a471e97ee631ae7f78	1418740	Woodwinds/Bassoon/sus/PSBassoon_F1_v2_1.wav
9d5e0ac1c1fafd0b650e249a3fc799b9685b4d38	1405324	Woodwinds/Bassoon/sus/PSBassoon_G#3_v1_1.wav
c88e1744e0298c353479a08c607fe13469cef2b6	1271796	Woodwinds/Bassoon/sus/PSBassoon_G#3_v2_1.wav
1802d35ea36b486169050595296b758b41b3bfc7	1509644	Woodwinds/Bassoon/sus/PSBassoon_G2_v1_1.wav
95a39a3c70c033e7167792f0e9d7f592a252044f	1273248	Woodwinds/Bassoon/sus/PSBassoon_G2_v2_1.wav
51377bb88e9100284ab1ba2967aafbbcf72d87b1	1286944	Woodwinds/Bassoon/vib/PSBassoon_A1_v1_1.wav
972b14255c1860169914ce21ff4f1204361c49d3	1386796	Woodwinds/Bassoon/vib/PSBassoon_A1_v2_1.wav
a34cebdfed6d4bff4af1abc4330f3828b5df1afc	1496068	Woodwinds/Bassoon/vib/PSBassoon_A2_v2_1.wav
bef3ec149a2c4bffde72bff2c19a1e006a853c0b	1889028	Woodwinds/Bassoon/vib/PSBassoon_A3_v1_1.wav
4be2b387b0257817b8d88e4e04b15cf5ff4f9db4	1510120	Woodwinds/Bassoon/vib/PSBassoon_A3_v2_1.wav
4f134676abad699e76264cabba37775c254124ad	1383596	Woodwinds/Bassoon/vib/PSBassoon_C2_v1_1.wav
59cdf75c793556294f99f801f27d6f8a01dc727b	1488964	Woodwinds/Bassoon/vib/PSBassoon_C2_v2_1.wav
ef26701373519401f9dadef9df69377688afecf1	1357616	Woodwinds/Bassoon/vib/PSBassoon_C3_v1_1.wav
8ef15e01d5067cf8cc43c287cac9cc312a40d48f	844128	Woodwinds/Bassoon/vib/PSBassoon_C3_v2_1.wav
2fe8d29d16bc57a4161792668cb82dd49fc6c07a	1280532	Woodwinds/Bassoon/vib/PSBassoon_C3_v2_2.wav
520bdadef50f604b579bff8827b2f99a2baac92c	1033644	Woodwinds/Bassoon/vib/PSBassoon_C4_v1_1.wav
acfe468fffce4a96f90537a22957886d20f9ef35	1436008	Woodwinds/Bassoon/vib/PSBassoon_C4_v2_1.wav
db31b85ea19c8757253be74bca5f0533a13f7b51	957096	Woodwinds/Bassoon/vib/PSBassoon_E3_v1_1.wav
c4a125e1aafed743defa938a19aba7c3f75092d2	1403260	Woodwinds/Bassoon/vib/PSBassoon_E3_v2_1.wav
5331df96d78fb0a73c93915a632d054da112e4c8	966448	Woodwinds/Bassoon/vib/PSBassoon_E3_v2_2.wav
f71cca023091c38f0bab24f2b448a666c17cd81c	1246816	Woodwinds/Bassoon/vib/PSBassoon_G1_v1_1.wav
78052a6cb3b271d0cb7469aba41141a7dc5ddb45	1425960	Woodwinds/Bassoon/vib/PSBassoon_G1_v2_1.wav
44a8c453993866b68b975cf7bc12605d9568de57	1531240	Woodwinds/Bassoon/vib/PSBassoon_G2_v1_1.wav
95aeda68ef3079406a9a9a8eafde2189039044c2	1515148	Woodwinds/Bassoon/vib/PSBassoon_G2_v2_1.wav
e138c7bd171bb4b64274f024adabe4f0cd566d16	1527852	Woodwinds/Bassoon/vib/PSBassoon_G3_v1_1.wav
4a67f5dddeff4b5214d08feb02b7a3d0299cfd4d	1461964	Woodwinds/Bassoon/vib/PSBassoon_G3_v2_1.wav
8e204e51e6821182479ee9da0524bbd9de881a56	99496	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v1_rr1_sum.wav
a12e429978d2e905397463952834ddbd0ff438d6	98508	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v1_rr2_sum.wav
ad969a7692cc00d47902b2544c77fed82dbd2c6f	103516	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v2_rr1_sum.wav
e198a7d79c06106ffae1366698852d47ea4ff01e	110812	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v2_rr2_sum.wav
7b33fd7d87a5d2c9a545743d9b05a917c9883be3	103712	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v3_rr1_sum.wav
56981b94da9d2cd9b675cab138ab57e0bcd476db	104200	Woodwinds/Clarinet/stac/DCClar_stac_A#2_v3_rr2_sum.wav
1d64739ac14897f9bed78f0f817641e37446aec0	89440	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v1_rr1_sum.wav
2dc1266c7b8facbebbca7b2d493e3deb9039a2d4	101440	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v1_rr2_sum.wav
3b76ffe7306ee10cec51da68441dc68aed73d4b4	115828	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v2_rr1_sum.wav
ae7537ac099fc27d001dee335517862c2ac9316b	93840	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v2_rr2_sum.wav
23ee0ea355f2bca5632b1f6cf3bc506919c248d6	108136	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v3_rr1_sum.wav
67bb9ccc457e926986fd4fba52b55ec733d93885	128332	Woodwinds/Clarinet/stac/DCClar_stac_A#3_v3_rr2_sum.wav
6d3ef3420e297cc1fae9fd77dac5b7a9957ea5fb	105220	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v1_rr1_sum.wav
855c14d97061ea9ba87c46b991344d22cde6b240	108592	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v1_rr2_sum.wav
e16969d2bcb5432ba1ed0ce542d513c8cbe0a113	113488	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v2_rr1_sum.wav
b6fb39c7e60971de354f6f40bf0fd7c96ed5d2dd	109304	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v2_rr2_sum.wav
30d19c8a7937acb797fe2e8df0d201dd6805a3d2	111108	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v3_rr1_sum.wav
f10e306eed5ce13b8bcf159e0b549bbea7ffde82	116068	Woodwinds/Clarinet/stac/DCClar_stac_A#4_v3_rr2_sum.wav
207f69ca8003c63b41328aef948ba1201964ac6d	93372	Woodwinds/Clarinet/stac/DCClar_stac_D2_v1_rr1_sum.wav
e8d1ada067a73c481c4c81ee1cac685a75c98fb9	94044	Woodwinds/Clarinet/stac/DCClar_stac_D2_v1_rr2_sum.wav
7580349cc2aab832adfef800be622165f56fc05e	101608	Woodwinds/Clarinet/stac/DCClar_stac_D2_v2_rr1_sum.wav
e27783e5b349e7da016fcb90df289bc5b6ee3303	97340	Woodwinds/Clarinet/stac/DCClar_stac_D2_v2_rr2_sum.wav
cd4533bbc9483d174414a1c77d333e15de3b08b1	101936	Woodwinds/Clarinet/stac/DCClar_stac_D2_v3_rr1_sum.wav
d364feb266202fce154b4be2e7538c5a88fa8c0c	98436	Woodwinds/Clarinet/stac/DCClar_stac_D2_v3_rr2_sum.wav
d42f438f95cfaf1aff4752f1845da355593350b5	92400	Woodwinds/Clarinet/stac/DCClar_stac_D3_v1_rr1_sum.wav
51b1dda28be2e94b4bcad4c4e42b7a383079116c	94472	Woodwinds/Clarinet/stac/DCClar_stac_D3_v1_rr2_sum.wav
39dd33d152d2ee22c2b21a7d927d4dd0ca2159f9	101040	Woodwinds/Clarinet/stac/DCClar_stac_D3_v2_rr1_sum.wav
427b15b5095b5bfc8995a66a623fc6b51c4424fb	101680	Woodwinds/Clarinet/stac/DCClar_stac_D3_v2_rr2_sum.wav
890f4fbc6a2d06bbdc466fada3b9bd66ed385c35	117624	Woodwinds/Clarinet/stac/DCClar_stac_D3_v3_rr1_sum.wav
c03bb50baff0a710203a670812bd4af1ae8979b6	111700	Woodwinds/Clarinet/stac/DCClar_stac_D3_v3_rr2_sum.wav
09a335aec0aa6104edcf63685cd43dc31a19486e	122248	Woodwinds/Clarinet/stac/DCClar_stac_D4_v1_rr1_sum.wav
fd49da708dd7266384b2b241dd307f37e87c0d20	119296	Woodwinds/Clarinet/stac/DCClar_stac_D4_v1_rr2_sum.wav
15cae66a6eeaa570819a580f1673d52af9518929	116956	Woodwinds/Clarinet/stac/DCClar_stac_D4_v2_rr1_sum.wav
b5405eaa3fb5297518f0e08a4b295fd9f09164f5	110680	Woodwinds/Clarinet/stac/DCClar_stac_D4_v2_rr2_sum.wav
e33170237affdce445a484f80315a83a93c80cb9	110360	Woodwinds/Clarinet/stac/DCClar_stac_D4_v3_rr1_sum.wav
23dd7b8d1a679c1fdad3ff779ff559a13678e8e2	118440	Woodwinds/Clarinet/stac/DCClar_stac_D4_v3_rr2_sum.wav
645dd468534f708adf69efe4d8058a41b10e17d2	101480	Woodwinds/Clarinet/stac/DCClar_stac_D5_v2_rr1_sum.wav
d1792cea3ff99c3359c7c22395d47493aaceffa0	105860	Woodwinds/Clarinet/stac/DCClar_stac_D5_v2_rr2_sum.wav
b92a44637cf7d584ae4f2a871f19d3008a367069	98224	Woodwinds/Clarinet/stac/DCClar_stac_D5_v3_rr1_sum.wav
9c0d0013d5d172d50340c58e06894c4d62d183ce	111700	Woodwinds/Clarinet/stac/DCClar_stac_D5_v3_rr2_sum.wav
b8d72deac510901f6742275b17e419a8dde4f9bd	81372	Woodwinds/Clarinet/stac/DCClar_stac_F2_v1_rr1_sum.wav
0c27dc18e339f775b4a389906efb251914c968bd	79300	Woodwinds/Clarinet/stac/DCClar_stac_F2_v1_rr2_sum.wav
754fb641bfa15a3cf411cc3f55231ad613236b74	91188	Woodwinds/Clarinet/stac/DCClar_stac_F2_v2_rr1_sum.wav
9788b1a080a45c1c48e3ad41d25a2d9bc6d6f723	86608	Woodwinds/Clarinet/stac/DCClar_stac_F2_v2_rr2_sum.wav
637121f7093ac7da16947dd73687f10b2daa3eb6	92644	Woodwinds/Clarinet/stac/DCClar_stac_F2_v3_rr1_sum.wav
63c8a401e134b4559016f2d7ecd3b774d8ab399e	89504	Woodwinds/Clarinet/stac/DCClar_stac_F2_v3_rr2_sum.wav
e6b1eda50209e95c2a41f465c64f55e3b59eef2a	94108	Woodwinds/Clarinet/stac/DCClar_stac_F3_v1_rr1_sum.wav
c78f0754b80a9cc67423d7f26545443af140e191	93172	Woodwinds/Clarinet/stac/DCClar_stac_F3_v1_rr2_sum.wav
41c5423b1db6d061c6066c695c7f2dd93eecc400	98364	Woodwinds/Clarinet/stac/DCClar_stac_F3_v2_rr1_sum.wav
c9d9aa09ab452ceb008a466f722dcea873d49c35	98020	Woodwinds/Clarinet/stac/DCClar_stac_F3_v2_rr2_sum.wav
53a65ea09cd886c3e3e68d584865adc99362becd	94568	Woodwinds/Clarinet/stac/DCClar_stac_F3_v3_rr1_sum.wav
79c394bff353086d23b2a9337bbd5d36804ad0ec	94872	Woodwinds/Clarinet/stac/DCClar_stac_F3_v3_rr2_sum.wav
5f477c9dfb1ba405665538cf38a2455b239dd0ee	123916	Woodwinds/Clarinet/stac/DCClar_stac_F4_v1_rr1_sum.wav
efa30e04d81508399459e2bab9dae406a4f0f4d1	114456	Woodwinds/Clarinet/stac/DCClar_stac_F4_v1_rr2_sum.wav
495948a7a2bd8cfee15d6679a54e299d8b7845a5	105552	Woodwinds/Clarinet/stac/DCClar_stac_F4_v2_rr1_sum.wav
90d355caaa581690746cadba02f5d0b6e0d9c66b	117176	Woodwinds/Clarinet/stac/DCClar_stac_F4_v2_rr2_sum.wav
ff0800e937194cbe9f630683470d316918b7783e	107756	Woodwinds/Clarinet/stac/DCClar_stac_F4_v3_rr1_sum.wav
c57e9646c4d2e7fa0729d235f6945f9d92ce180f	108896	Woodwinds/Clarinet/stac/DCClar_stac_F4_v3_rr2_sum.wav
8d84c59441195fd793ccf8c3be08ef76241e81ea	99084	Woodwinds/Clarinet/stac/DCClar_stac_F5_v1_rr1_sum.wav
4c1f0bc71cb7222091c90087872a686b6ad507ab	110972	Woodwinds/Clarinet/stac/DCClar_stac_F5_v1_rr2_sum.wav
5906891ce346b6134f3377aef9734bbd28215f0b	100148	Woodwinds/Clarinet/stac/DCClar_stac_F5_v2_rr1_sum.wav
a8f4c6c3897786e81b7bc531939814f35655f81a	145576	Woodwinds/Clarinet/stac/DCClar_stac_F5_v2_rr2_sum.wav
b8974a290592529e307f2b905a152806dc39b047	117132	Woodwinds/Clarinet/stac/DCClar_stac_F5_v3_rr1_sum.wav
d675fa7048e4a453183c304cb7010e1b3d0a3596	117868	Woodwinds/Clarinet/stac/DCClar_stac_F5_v3_rr2_sum.wav
c02251ea67183260dd5f3b4cca97eeb0e8f23bed	1825324	Woodwinds/Clarinet/susLong/DCClar_susLong_A#2_v1_rr1_sum.wav
4ab307dd0c82ce0900eb7439bdb8d0a1008d4034	1909388	Woodwinds/Clarinet/susLong/DCClar_susLong_A#2_v2_rr1_sum.wav
d08b0b0242b1695b533f14c7774c4e5bd7f83646	2335540	Woodwinds/Clarinet/susLong/DCClar_susLong_A#2_v3_rr1_sum.wav
f8db827226f661779d8965737fa0850d8275be9a	1599888	Woodwinds/Clarinet/susLong/DCClar_susLong_A#3_v1_rr1_sum.wav
c80415402c31b050eb51796e17fba541a24a57a0	1791140	Woodwinds/Clarinet/susLong/DCClar_susLong_A#3_v2_rr1_sum.wav
08f1508a646a60a8795861688932e38955cc8ba0	2059160	Woodwinds/Clarinet/susLong/DCClar_susLong_A#3_v3_rr1_sum.wav
27315505c21685cdc911e3ae30ce8712c712da26	1996064	Woodwinds/Clarinet/susLong/DCClar_susLong_A#4_v1_rr1_sum.wav
4250227b229f8f94ea73ecb3ff4e996bfa1cf91b	1823220	Woodwinds/Clarinet/susLong/DCClar_susLong_A#4_v2_rr1_sum.wav
bc184323f783462fb1bbb3f49ad57ddaaac2cb11	1885948	Woodwinds/Clarinet/susLong/DCClar_susLong_A#4_v3_rr1_sum.wav
22e4849edce9f5f75473852d71b1a71e75502505	806612	Woodwinds/Clarinet/susLong/DCClar_susLong_D2_v1_rr1_sum.wav
e435f825232aff390c93e0462d9e93e9e488d7ed	1689164	Woodwinds/Clarinet/susLong/DCClar_susLong_D2_v2_rr1_sum.wav
3d40552dd6d2dead91c702fe68175869a988009d	1381704	Woodwinds/Clarinet/susLong/DCClar_susLong_D2_v3_rr1_sum.wav
8f3f973a0d69c3c721f1eb8b27f208c80bd17ceb	2230948	Woodwinds/Clarinet/susLong/DCClar_susLong_D3_v1_rr1_sum.wav
dfffae60b3793d9687b2cb2c9b3850f593c723c6	1876188	Woodwinds/Clarinet/susLong/DCClar_susLong_D3_v2_rr1_sum.wav
aa7a1f5f31cef8d36552072d9f275b7940c879c0	1856124	Woodwinds/Clarinet/susLong/DCClar_susLong_D3_v3_rr1_sum.wav
c3284691eb2dfe4f1be1b116b804a2e41062bb9c	1987372	Woodwinds/Clarinet/susLong/DCClar_susLong_D4_v1_rr1_sum.wav
9efaf747591d3c39b7b6e87a077963a1ac71ae45	2047596	Woodwinds/Clarinet/susLong/DCClar_susLong_D4_v2_rr1_sum.wav
119bec0bc1ad924b04e416966239d6af3a67a764	2087348	Woodwinds/Clarinet/susLong/DCClar_susLong_D4_v3_rr1_sum.wav
ee07579d393b6c9a43aaf65f375d2012c3d0c774	1692352	Woodwinds/Clarinet/susLong/DCClar_susLong_D5_v1_rr1_sum.wav
d2c1fa23c73a15d50b581b6f83aa9e56e7e01a0c	1772224	Woodwinds/Clarinet/susLong/DCClar_susLong_D5_v2_rr1_sum.wav
a06b19f95d397920e21a56cdb85223a39e860d47	1593652	Woodwinds/Clarinet/susLong/DCClar_susLong_D5_v3_rr1_sum.wav
0e30b7890f8c35943fa4eb693c704ce5c595acec	1025344	Woodwinds/Clarinet/susLong/DCClar_susLong_F#5_v1_rr1_sum.wav
5e103799bb30ef1afa405511230c852b942a9d7c	1252444	Woodwinds/Clarinet/susLong/DCClar_susLong_F#5_v2_rr1_sum.wav
9655d9014a2500386d01f80bf0d7e3100e8caa59	1586272	Woodwinds/Clarinet/susLong/DCClar_susLong_F#5_v3_rr1_sum.wav
a8b913d7e923c58f150e757f1748da37c80587b4	1527412	Woodwinds/Clarinet/susLong/DCClar_susLong_F2_v1_rr1_sum.wav
090db5da13fb0ec67673b6a656887644c923d341	1835164	Woodwinds/Clarinet/susLong/DCClar_susLong_F2_v2_rr1_sum.wav
04b88f5463edcbdfb44e64826d26d8528b4a12f6	1747440	Woodwinds/Clarinet/susLong/DCClar_susLong_F2_v3_rr1_sum.wav
31ac755ac1dff319c409505d26706d9851bb7e92	1762976	Woodwinds/Clarinet/susLong/DCClar_susLong_F3_v1_rr1_sum.wav
1a445b0610a060c571574916d140344fc60922b2	2069572	Woodwinds/Clarinet/susLong/DCClar_susLong_F3_v2_rr1_sum.wav
fc79b6d0f5b3420f4e24b0392484b43a864a6d50	1743712	Woodwinds/Clarinet/susLong/DCClar_susLong_F3_v3_rr1_sum.wav
04e3a4727ee49ff915baeb65c1d32ee4e9ec37e2	2034208	Woodwinds/Clarinet/susLong/DCClar_susLong_F4_v1_rr1_sum.wav
9188e6eb2204ec227bac95cf254b9ce20e5d9d58	2142808	Woodwinds/Clarinet/susLong/DCClar_susLong_F4_v2_rr1_sum.wav
086d21e2c435964f31b77df757b763e6d6b5eb54	2373520	Woodwinds/Clarinet/susLong/DCClar_susLong_F4_v3_rr1_sum.wav
5227a2e44dcafb78d9d265c6ccc5b2dd30627b8f	2837844	Woodwinds/Flute/expvib/LDFlute_expvib_A3_v1_1.wav
f67d076c1fa9f038065543f21dbb060598ffe7a4	3003534	Woodwinds/Flute/expvib/LDFlute_expvib_A4_v1_1.wav
92385acbf4146a08c4b835235900662e7bf8630c	2765178	Woodwinds/Flute/expvib/LDFlute_expvib_A5_v1_1.wav
7ad5ee7616fa365c824764750947cd1c824858ff	2642046	Woodwinds/Flute/expvib/LDFlute_expvib_C3_v1_1.wav
d0b324d952d80520a7201cf22ccc17891def64b7	3142338	Woodwinds/Flute/expvib/LDFlute_expvib_C4_v1_1.wav
fed2a11c9f706d80d62c8ef4d7ef5073d816b3b9	3190830	Woodwinds/Flute/expvib/LDFlute_expvib_C5_v1_1.wav
c920b4da8af0b6025f9d2d80e2dbfb6b82429d43	3282168	Woodwinds/Flute/expvib/LDFlute_expvib_C5_v1_2.wav
be2d5766070cb3d5d1ea657ec3f5c5f9083c0bd9	1091082	Woodwinds/Flute/expvib/LDFlute_expvib_C6_v1_1.wav
e7668b7aaf41f471f03aefd27a8e4a6939bbb3fa	1125240	Woodwinds/Flute/expvib/LDFlute_expvib_C6_v1_2.wav
f5d3a85a9a3f656a8c57cd4ef0c1da1bfa701483	2136570	Woodwinds/Flute/expvib/LDFlute_expvib_E3_v1_1.wav
e53892fd781ebf58125b829d4813f0828f8ca6de	2702592	Woodwinds/Flute/expvib/LDFlute_expvib_E3_v1_2.wav
f6fd2ab0aa0d9172a2124ef323c8d991bd2803ad	2878710	Woodwinds/Flute/expvib/LDFlute_expvib_E4_v1_1.wav
d57a33ab9252b2566f055af066fced3f7acb34b9	2784102	Woodwinds/Flute/expvib/LDFlute_expvib_E5_v1_1.wav
af05c846172ca955389d6f576475c20cc4a9c1f8	2575950	Woodwinds/Flute/expvib/LDFlute_expvib_E5_v1_2.wav
2a0f3517af9d4836f1574514f6aa94c2e9af2587	169494	Woodwinds/Flute/stac/LDFlute_stac_A3_v1_rr1.wav
8773c79e9469125ac23c82652314cf136957d709	274506	Woodwinds/Flute/stac/LDFlute_stac_A3_v1_rr2.wav
407b5658d6f53afc6cc4bee0ba6d8227cef2d547	206022	Woodwinds/Flute/stac/LDFlute_stac_A3_v2_rr1.wav
7811d912a561d82476b05ccf12357b09718c17cc	188274	Woodwinds/Flute/stac/LDFlute_stac_A3_v2_rr2.wav
a6f3702c0ab6f9e8f49e89fbcfb14714c1299dba	223920	Woodwinds/Flute/stac/LDFlute_stac_A3_v3_rr1.wav
1e1de61cec1374b07093c7f0ba9e4b4917f8aff9	190524	Woodwinds/Flute/stac/LDFlute_stac_A3_v3_rr2.wav
dc9bc75e007375269560cff1c5d655bb6dad8025	208560	Woodwinds/Flute/stac/LDFlute_stac_A4_v1_rr1.wav
b435c8c507f7552cf1918867ed76f1e565c22878	193008	Woodwinds/Flute/stac/LDFlute_stac_A4_v1_rr2.wav
157ada54c6bcf37349297082a8f5ccb25aeaf15f	200514	Woodwinds/Flute/stac/LDFlute_stac_A4_v2_rr1.wav
4bba068a8af95507335db23039f76c5020870076	189954	Woodwinds/Flute/stac/LDFlute_stac_A4_v2_rr2.wav
f8a11712d8d5c9b00c39ba552cad6c04a99886a4	197358	Woodwinds/Flute/stac/LDFlute_stac_A4_v3_rr1.wav
732d10c72e0e4338b850db5395e2535f9605cf82	195228	Woodwinds/Flute/stac/LDFlute_stac_A4_v3_rr2.wav
83f13ab29896ddf57e1815b1d1096a8382009312	204132	Woodwinds/Flute/stac/LDFlute_stac_A5_v1_rr1.wav
d563733ab363be8c350cada4f14e622f0e92a450	336732	Woodwinds/Flute/stac/LDFlute_stac_A5_v1_rr2.wav
77e478a0cd26e6c95f65abba86a4b596f5ef3afb	228906	Woodwinds/Flute/stac/LDFlute_stac_A5_v2_rr1.wav
5f60918a36e5e7ffdd1c15bb96b175f375207843	210618	Woodwinds/Flute/stac/LDFlute_stac_A5_v2_rr2.wav
978fcc6601c4a22da897daf27478f2a3a87142e2	271494	Woodwinds/Flute/stac/LDFlute_stac_A5_v3_rr1.wav
304cdc1b7b585401196affc64e8c91d5d0d246f7	214248	Woodwinds/Flute/stac/LDFlute_stac_A5_v3_rr2.wav
cc11ab21c37ceee6267a791a9358d5ac9860362a	209538	Woodwinds/Flute/stac/LDFlute_stac_C4_v1_rr1.wav
1a973d51468fd947bef76659027f23cb158d98cb	179586	Woodwinds/Flute/stac/LDFlute_stac_C4_v1_rr2.wav
77cda69826c9ca4cd3e2b9512676b88ee12cc6ec	159558	Woodwinds/Flute/stac/LDFlute_stac_C4_v2_rr1.wav
6c825fb1110cc9bce3d86c9950f098c07faf84f5	164928	Woodwinds/Flute/stac/LDFlute_stac_C4_v2_rr2.wav
681ee8fa3bf49317d8c42f4ae46cbc5d920db08a	216276	Woodwinds/Flute/stac/LDFlute_stac_C4_v3_rr1.wav
cb05fb2c3bdf95dd5dbce91140bbd05a395689d2	178608	Woodwinds/Flute/stac/LDFlute_stac_C4_v3_rr2.wav
2ce4efec9fbd90f4c4c10c62e02e75642ff94afc	222498	Woodwinds/Flute/stac/LDFlute_stac_C4_v4_rr1.wav
c8af86c554c183b4ee9af8354a32c7405edf2a03	240540	Woodwinds/Flute/stac/LDFlute_stac_C4_v4_rr2.wav
2ad0bdf7c8f63a27ceba44e55a66f678aec5ac66	163326	Woodwinds/Flute/stac/LDFlute_stac_C5_v1_rr1.wav
08a4d87be820f096522e2e7cdd98d15728b97972	193542	Woodwinds/Flute/stac/LDFlute_stac_C5_v1_rr2.wav
8da3b215649aacc8e0590080987034bddbcaac16	176460	Woodwinds/Flute/stac/LDFlute_stac_C5_v2_rr1.wav
0316fbb6ccd256ec3608a19960088e12d42509ad	183138	Woodwinds/Flute/stac/LDFlute_stac_C5_v2_rr2.wav
0db3fd155b3d492e05fbcbcb6293ce3d1a369d8b	195378	Woodwinds/Flute/stac/LDFlute_stac_C5_v3_rr1.wav
7895f93485086509368fddda659a686ea7f36874	185748	Woodwinds/Flute/stac/LDFlute_stac_C5_v3_rr2.wav
5f25219f618d81218fc21ffa0aa6984c4ae792d5	211494	Woodwinds/Flute/stac/LDFlute_stac_C6_v1_rr1.wav
3e85d1ce95de1e6a44d61278393cf2becaef2dff	204558	Woodwinds/Flute/stac/LDFlute_stac_C6_v1_rr2.wav
da1e5de1f88dc57eb5132bc45c891324386498f3	230808	Woodwinds/Flute/stac/LDFlute_stac_C6_v2_rr1.wav
d2a1a315f83727b56cf8a3ae4e7252ce0785788f	224082	Woodwinds/Flute/stac/LDFlute_stac_C6_v2_rr2.wav
5889259f046de2eb164eab673df185fa0c3ac57c	180558	Woodwinds/Flute/stac/LDFlute_stac_E4_v1_rr1.wav
708bd49a52938f62eff5f283b9bac864f47931b0	176736	Woodwinds/Flute/stac/LDFlute_stac_E4_v1_rr2.wav
dba5a5b646d5229dab45ba98f947459e08aae9f8	252444	Woodwinds/Flute/stac/LDFlute_stac_E4_v2_rr1.wav
e2360dcb699e7ad82cc2e5a2e11bc273b5a6c82a	247578	Woodwinds/Flute/stac/LDFlute_stac_E4_v2_rr2.wav
a22d5efeba91a8852b08e52b8d735e1f3e72f258	235668	Woodwinds/Flute/stac/LDFlute_stac_E4_v3_rr1.wav
9a8b8dc1f0ba7b5c5e90eb9ecb1d3f58c3dd2dc3	247992	Woodwinds/Flute/stac/LDFlute_stac_E4_v3_rr2.wav
f2b06b1570e41b20609cdc92d03796de1038a749	208020	Woodwinds/Flute/stac/LDFlute_stac_E5_v1_rr1.wav
a8df869a4c18de9c0c4d67ace8a567c56146c7bc	287886	Woodwinds/Flute/stac/LDFlute_stac_E5_v1_rr2.wav
ab73651d5fdd1ab9a807f1087ef2403c8d54d6b2	231450	Woodwinds/Flute/stac/LDFlute_stac_E5_v2_rr1.wav
4f817cd09481652addcc9b97b7851a61d3069f8e	199128	Woodwinds/Flute/stac/LDFlute_stac_E5_v2_rr2.wav
9cf88368de0a36a26d1ab170ec38c07a785c488b	220758	Woodwinds/Flute/stac/LDFlute_stac_E5_v3_rr1.wav
d77b4c5111ce18d4517d200cac675fb92988dd64	218706	Woodwinds/Flute/stac/LDFlute_stac_E5_v3_rr2.wav
b690a4d0006b73699176dd2fab82a9249966e33b	2706216	Woodwinds/Flute/susNV/LDFlute_susNV_A3_v1_1.wav
75a6dbb605779e3eaef2a265b6857142211a5837	2765718	Woodwinds/Flute/susNV/LDFlute_susNV_A3_v3_1.wav
3007213aa6264efe0619c7321bf2e8df7966b0a2	3460842	Woodwinds/Flute/susNV/LDFlute_susNV_A4_v1_1.wav
fa6e9dc8429dc62ae37eb6e61cf63aed8ca38529	2147490	Woodwinds/Flute/susNV/LDFlute_susNV_A4_v3_1.wav
3f6ea8e543310a6e97ed97ac5b74c9e53ee3b05e	2885970	Woodwinds/Flute/susNV/LDFlute_susNV_A5_v1_1.wav
cbcfcd8aef190cf811e141bf9c602953a4c2d935	2100774	Woodwinds/Flute/susNV/LDFlute_susNV_A5_v3_1.wav
ac3b6e4b90480a5a64798c2c399f16ea95754015	2642490	Woodwinds/Flute/susNV/LDFlute_susNV_C3_v1_1.wav
18b1fa490327f38057a2edbaca4f000cffbf633d	2729730	Woodwinds/Flute/susNV/LDFlute_susNV_C3_v3_1.wav
ea9cc7ff40975e8d3917c6e8fa13f67167e142f2	2722056	Woodwinds/Flute/susNV/LDFlute_susNV_C4_v1_1.wav
850db1f598b5ba7a88ec2f929f8b832fb83cdd66	2539512	Woodwinds/Flute/susNV/LDFlute_susNV_C4_v3_1.wav
093129d6a876ce5f004279b2979894d0ed637a8d	2491416	Woodwinds/Flute/susNV/LDFlute_susNV_C5_v1_1.wav
c781084689262db0267e3b888ac9a9244f32dbd7	2382720	Woodwinds/Flute/susNV/LDFlute_susNV_C5_v2_1.wav
8b69c3cd65834619ad9c1389b3c9f8d50fab15f5	1618152	Woodwinds/Flute/susNV/LDFlute_susNV_C6_v1_1.wav
7a921854e39f8addf99a4dc8e4b3f27e187142c2	2874126	Woodwinds/Flute/susNV/LDFlute_susNV_E3_v1_1.wav
66390898fca3d96f65bbc2bffd26c55af56db11e	2814822	Woodwinds/Flute/susNV/LDFlute_susNV_E3_v3_1.wav
3f351c4623be881464381ac8de2c3cfef99ac646	2591256	Woodwinds/Flute/susNV/LDFlute_susNV_E4_v1_1.wav
67357c844a8c88034431d83438bd8ddea729e805	2449278	Woodwinds/Flute/susNV/LDFlute_susNV_E4_v3_1.wav
4017163d62316f9eb0a4a5d375de9f7d110dda64	2956800	Woodwinds/Flute/susNV/LDFlute_susNV_E5_v1_1.wav
cc70b43ccea6a87ac5677483c206b7905d510874	2121246	Woodwinds/Flute/susNV/LDFlute_susNV_E5_v2_1.wav
1e8972d4e28dbf8b48e348b93c7862f29b0edfab	2117124	Woodwinds/Flute/susvib/LDFlute_susvib_A3_v1_1.wav
1202232193c565a79618a1696913714e9fe1ad20	1942296	Woodwinds/Flute/susvib/LDFlute_susvib_A4_v1_1.wav
1114c8bf25896d3ee2f7d257c5d81e426fef2cc5	1457676	Woodwinds/Flute/susvib/LDFlute_susvib_A5_v1_1.wav
50220315ef8ca85e92b8809f6c0e15a0c4954cce	2088144	Woodwinds/Flute/susvib/LDFlute_susvib_C3_v1_1.wav
7be22f8b86e5dc405a10f51dd71d44712d23c9aa	2009832	Woodwinds/Flute/susvib/LDFlute_susvib_C4_v1_1.wav
18bfcccf848cfb4d8d10a005174408ef66fb1cae	2140530	Woodwinds/Flute/susvib/LDFlute_susvib_C4_v1_2.wav
5dc3e06072700651fe1844aafd304633692c6e97	1930938	Woodwinds/Flute/susvib/LDFlute_susvib_C5_v1_1.wav
f98e1ff1bc4d3dd23cb689de548e13bbfd48ebbb	1260120	Woodwinds/Flute/susvib/LDFlute_susvib_C6_v1_1.wav
ee1008bf0f9dde16d2c584b0cca67fc79889d298	2802054	Woodwinds/Flute/susvib/LDFlute_susvib_E3_v1_1.wav
19c052eab97d1e823fd7d8344c05d94dc7dd4733	2144718	Woodwinds/Flute/susvib/LDFlute_susvib_E4_v1_1.wav
5df7941f73d2de88cfe8890d52031b4e3fa2b8b4	1828944	Woodwinds/Flute/susvib/LDFlute_susvib_E4_v1_2.wav
14e407aa2cfd07b98585ebf7963d3c30be6f85dc	1586118	Woodwinds/Flute/susvib/LDFlute_susvib_E5_v1_1.wav
45c715c6e1ca72e4535b9723a030024fea16f40a	1858836	Woodwinds/Flute/susvib/LDFlute_susvib_E5_v1_2.wav
79054559972e5c5377b262de5de10a3de7ece7a9	179156	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v1_rr1_Main.wav
c1bd34d76e977944e7397b7c8963e98434b62551	148000	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v1_rr2_Main.wav
e5cfa4df3c4676eaa16bfc7f8f92915479d1d572	177684	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v2_rr1_Main.wav
a887c3d36a84757fa13dc34227aad8ab86008b4e	161668	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v2_rr2_Main.wav
d9c2f6b09c3904fcd6d30e2fe49878f36079f14b	179104	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v3_rr1_Main.wav
034f7f0f789e0d5fa3425644b7a5e1905e62af28	148052	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#2_v3_rr2_Main.wav
fd684d1d29615eb1c19ed5167c94de90d8544105	172608	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v1_rr1_Main.wav
02aa97783bcd0cb1cf42f57c10becc6c240a4a63	150876	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v1_rr2_Main.wav
a521c7bfc79c6a70f275eddb630920c48e62ed80	130932	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v2_rr1_Main.wav
3564bd4b50b9cb3a95f161eaffa41c042a500212	123824	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v2_rr2_Main.wav
0a5fbae398b8183d234a880b21a18ad9495afa3d	136532	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v3_rr1_Main.wav
e01394514e079f1dd2f250f3a221841f537646ae	173120	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#3_v3_rr2_Main.wav
1dc8580ae286c57ba826fcdb5a9571d6f6221f77	120952	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v1_rr1_Main.wav
4f8927aa2f3ccf7c4e74a061ac3cc61d07443bc7	90204	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v1_rr2_Main.wav
a6b0d7e68d80ef0bb06379dca767aaa3f62f56bc	136052	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v2_rr1_Main.wav
0208ff17565ab874b7333f0555d655a76f31d5b9	125544	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v2_rr2_Main.wav
385e08172ee97656d8d2297943e4cfee35042048	119560	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v3_rr1_Main.wav
e9e839ea8eb90d8d0449aa4af90a2ad2f54c74bc	126048	Woodwinds/Oboe/Stacc/Oboe_Stacc_A#4_v3_rr2_Main.wav
b9808f5c9a3bb0b27f907093274e0f6aede07549	170168	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v1_rr1_Main.wav
523064fc8787eecf661f9cf87de90aea64c32fda	176892	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v1_rr2_Main.wav
a140e6fff5be48ac562a6a6d982ad443f9024bae	173736	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v2_rr1_Main.wav
1f255ab321c8b0fec0f55639914375dd2436dc7f	177116	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v2_rr2_Main.wav
ed7bd5aae34cd1ff3a6a336b6510db8fa86ade9b	174404	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v3_rr1_Main.wav
2c41ff1c51f8acf9c63b35bc7c06e6237d7d9a2f	176348	Woodwinds/Oboe/Stacc/Oboe_Stacc_D3_v3_rr2_Main.wav
72da676bbc1df494e629fc6c9708f0cf3e9926c2	131148	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v1_rr1_Main.wav
176a68cecc019896ebe3144ffc683b3f0b0c7616	117704	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v1_rr2_Main.wav
f412b48c67279b314d5c6bf98c713acba83c9277	138192	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v2_rr1_Main.wav
6e7907f807ff984e3b88150f2a6e5e7e4cc0b5db	127196	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v2_rr2_Main.wav
14e2e5e0488bccc9821f090667e3b275cbd95062	135980	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v3_rr1_Main.wav
b5afcf7c47ed74115412bd9b7b24b04c461d5b6d	120724	Woodwinds/Oboe/Stacc/Oboe_Stacc_D4_v3_rr2_Main.wav
d6473b4de454a88d73ffe577697abbe8a04f2545	92036	Woodwinds/Oboe/Stacc/Oboe_Stacc_D5_v1_rr1_Main.wav
63285bcb4cfd52c6f0a5cec307931806acd9e6f7	113312	Woodwinds/Oboe/Stacc/Oboe_Stacc_D5_v1_rr2_Main.wav
50d761049d830f5a0d5c668eea9d0fde74422a98	126928	Woodwinds/Oboe/Stacc/Oboe_Stacc_D5_v3_rr1_Main.wav
ae2820f0c4d159c72b54046bc545795560fbba22	174700	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v1_rr1_Main.wav
6bc18af05a80152f796d3f1b4782dc4ca4c5f0ea	174428	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v1_rr2_Main.wav
4fd46551f8220d8c5c91625705fb925ed81cd41e	146872	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v2_rr1_Main.wav
f3b41c2c485a32d5f318ef143727f945874b9e6f	144260	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v2_rr2_Main.wav
1399dff8123fd54f19fb0c6a64af6ca997bb10c1	164116	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v3_rr1_Main.wav
f1e68dddb75aaa839f93980e8c924d979e81f73f	141868	Woodwinds/Oboe/Stacc/Oboe_Stacc_F3_v3_rr2_Main.wav
3db807f214205f86523502c038e2f76ef5f065cd	124312	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v1_rr1_Main.wav
a314a32b624a4fba61e8a398b20f6d73441da189	115856	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v1_rr2_Main.wav
af74c705817f03f33ba27db20caa8151b77b370d	118292	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v2_rr1_Main.wav
af75d72bb7b8239f5ada3d7c494e48a311f3f9b6	118264	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v2_rr2_Main.wav
2dadbaea99b455f486173f2d754b54e52f9ebc37	122556	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v3_rr1_Main.wav
6d96ae424a232156598fbd15c8306ddd75ed5fa8	125664	Woodwinds/Oboe/Stacc/Oboe_Stacc_F4_v3_rr2_Main.wav
bf1fdf201f73588094cd11b5e8a012c6d419bfe8	111424	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v1_rr1_Main.wav
90b84e8963c658b5a62f6c887a95d6c5cf73e57c	120092	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v1_rr2_Main.wav
cfd503800cac3438951f8dbc38e475cec8ea17c0	108120	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v2_rr1_Main.wav
2dea6b26ba2b0d2d80c6781575a8a75bf3140005	112480	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v2_rr2_Main.wav
2a4b5d12fbe20069fc11617055a3195d76d3f825	100276	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v3_rr1_Main.wav
388aef85d5996bb0ef6d426f8fe189c3e37edbf1	104592	Woodwinds/Oboe/Stacc/Oboe_Stacc_F5_v3_rr2_Main.wav
d1ee9884155ae8a6f67279452de23713f8f8b4e9	4783096	Woodwinds/Oboe/Sus/Oboe_Sus_A#2_v1_Main.wav
46e3ba91c7ed6e5f0e952e1c57738e91bd8dfbb1	2377080	Woodwinds/Oboe/Sus/Oboe_Sus_A#2_v3_Main.wav
6cf66ef2acdc033553930396a94a933f9276d418	1899732	Woodwinds/Oboe/Sus/Oboe_Sus_A#3_v1_Main.wav
a647e2253125834b891e8eedb594a3902c8a1def	1793592	Woodwinds/Oboe/Sus/Oboe_Sus_A#3_v3_Main.wav
13a008ba5705481fe2112af6d0a7a5cbb008892f	1855232	Woodwinds/Oboe/Sus/Oboe_Sus_A#4_v1_Main.wav
d41287e7cd6043ce9081ff49dd03c6e4ddc6730d	1546676	Woodwinds/Oboe/Sus/Oboe_Sus_A#4_v3_Main.wav
5b4e7daa195485f09934d9f63f78fa7bf3578a16	1966552	Woodwinds/Oboe/Sus/Oboe_Sus_D3_v1_Main.wav
807d1b60150381bcbbfa7adba01f6c9d1d9e56f2	2219916	Woodwinds/Oboe/Sus/Oboe_Sus_D3_v3_Main.wav
d96212fefd5d0e4a798a05ef0c9b4be2a3c2370e	1747332	Woodwinds/Oboe/Sus/Oboe_Sus_D4_v1_Main.wav
c2d464efea3547555666a781f4873c7f80dd1393	1699340	Woodwinds/Oboe/Sus/Oboe_Sus_D4_v3_Main.wav
243f0462e803ec0af99421ac60dd5c9ee3a91659	1564292	Woodwinds/Oboe/Sus/Oboe_Sus_D5_v1_Main.wav
9374b432947c30aa361dafae72ea0ef9b1cc730b	1650952	Woodwinds/Oboe/Sus/Oboe_Sus_D5_v3_Main.wav
2e634363e4273a6adfd9df3496db3f265fd921ac	1542764	Woodwinds/Oboe/Sus/Oboe_Sus_F3_v1_Main.wav
2024bd3888a256f86d7b9c1fdf7f06fc0877135e	1717152	Woodwinds/Oboe/Sus/Oboe_Sus_F3_v3_Main.wav
9e4ae9bc39bc906e21c7796e0e2c5eb5ef943dce	1666300	Woodwinds/Oboe/Sus/Oboe_Sus_F4_v1_Main.wav
4f2c0ca39a4604d8493367eaf953e8756bc0bf90	1452368	Woodwinds/Oboe/Sus/Oboe_Sus_F4_v3_Main.wav
e551ce12b3644639707243f02178f45010c78d1a	1652712	Woodwinds/Oboe/Sus/Oboe_Sus_F5_v1_Main.wav
55038a3b147179cef644aa58b390160ed37dcee5	1722672	Woodwinds/Oboe/Sus/Oboe_Sus_F5_v3_Main.wav
8123a9c433d1c021b708f6cf71561755f70799cb	1962784	Woodwinds/Oboe/Vib/Oboe_Vib_A#2_v1_Main.wav
281c98b6e0724f08207273383c01040a6068760d	1612072	Woodwinds/Oboe/Vib/Oboe_Vib_A#2_v3_Main.wav
11e415092b541e1b50288f8b6f6adab99bf78cad	1190800	Woodwinds/Oboe/Vib/Oboe_Vib_A#3_v1_Main.wav
0fe9f6f9108782a477d8bf3a8a6245ccca20780b	1276400	Woodwinds/Oboe/Vib/Oboe_Vib_A#3_v3_Main.wav
8ba804ac6a7bdd5ef50aa6fe86fc00d0410fcde4	1238560	Woodwinds/Oboe/Vib/Oboe_Vib_A#4_v1_Main.wav
6e593e290f7b24611868eb66a910a71e543acdba	1220064	Woodwinds/Oboe/Vib/Oboe_Vib_A#4_v3_Main.wav
7aeb7ee276ed4d2beb0a23809c9172dbd60e19cc	1717568	Woodwinds/Oboe/Vib/Oboe_Vib_D3_v1_Main.wav
dfe78cb70c94138f4a42ce2fc48d00ba980ab500	1219492	Woodwinds/Oboe/Vib/Oboe_Vib_D3_v3_Main.wav
e6b7ae503ea74955306ab9daa98a47a5e9f829d9	1215096	Woodwinds/Oboe/Vib/Oboe_Vib_D4_v1_Main.wav
60c393a1ccf1f83a69d8ff2c9eb1a451d4050f3c	1279084	Woodwinds/Oboe/Vib/Oboe_Vib_D4_v3_Main.wav
1f6ce8a04c5c7b19151c0172048b41a3050e0b4e	1183256	Woodwinds/Oboe/Vib/Oboe_Vib_D5_v1_Main.wav
b788a608581e380831cb7f2ed771e36e1f09e4ed	1343704	Woodwinds/Oboe/Vib/Oboe_Vib_D5_v3_Main.wav
87e942dcb4b42530959fa73fa2f9136af9d53214	1141364	Woodwinds/Oboe/Vib/Oboe_Vib_F3_v1_Main.wav
9a61e3adcb5837237e3cbb8bbfa6dff0d0570113	1167324	Woodwinds/Oboe/Vib/Oboe_Vib_F3_v3_Main.wav
9deac7dbdfc715dd85fbef34d904eb271d20370f	1465564	Woodwinds/Oboe/Vib/Oboe_Vib_F4_v1_Main.wav
8aec1d903928028c31e4adbc2ac4f356df2d7a53	1290652	Woodwinds/Oboe/Vib/Oboe_Vib_F4_v3_Main.wav
3490a876a34833e0be79bc3e67e45ad4eb0da4a3	1278544	Woodwinds/Oboe/Vib/Oboe_Vib_F5_v1_Main.wav
8fc50b77329e4c5dd140b45e9afb70259d8489f6	1220420	Woodwinds/Oboe/Vib/Oboe_Vib_F5_v3_Main.wav
65cb7a9641605a91459642bff55e1dbb6060af93	115628	Woodwinds/Piccolo/Stac/piccolo_A#4_staccato1.wav
f20ce8ef66558c5edd2b5d2d61d17c2af5df783b	113336	Woodwinds/Piccolo/Stac/piccolo_A#5_staccato1.wav
1f5a528b8d6b8d6a402d4a97f81d89f59f885f87	143984	Woodwinds/Piccolo/Stac/piccolo_A#6_staccato1.wav
a3e7467224b27a67f792a49e34e8de7db7d0602e	120014	Woodwinds/Piccolo/Stac/piccolo_G5_staccato1.wav
1b85700fb5ed35f6524bd8d72fa30a3e69544b3c	117104	Woodwinds/Piccolo/Stac/piccolo_G6_staccato1.wav
512edafd9a2c4825dad35a887eb742bdd161f9b9	2219690	Woodwinds/Piccolo/Sus/piccolo_C5_sustain1.wav
e6b815988705c811e736ecdc00c252195cae7521	3309242	Woodwinds/Piccolo/Sus/piccolo_C6_sustain1.wav
e2f56b2c8691ccda1d60a2f0eeff73dd7bf23e32	1951040	Woodwinds/Piccolo/Sus/piccolo_G4_sustain1.wav
302dc7f46b3d9d5bb6de189c05333cd19885c131	2246120	Woodwinds/Piccolo/Sus/piccolo_G5_sustain1.wav
9509e21a166a0d6ccef2cb5841817685f7c86123	2139986	Woodwinds/Piccolo/Sus/piccolo_G6_sustain1.wav
92305889ece1b63ff6683a6ae51001ed958b37ae	1065	Xylophone.sfz
"""#
}
