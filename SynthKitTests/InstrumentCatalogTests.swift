import Foundation
import XCTest
@testable import SynthKit

/// The shipped catalog itself: is it well-formed, does it cover what REQ-020
/// asks for, and does it say honest things about what it does not.
///
/// This is the leaf's cheapest and most valuable test. The catalog is 2,541
/// pinned assets generated from a git tree, and the failure mode it protects
/// against is a manifest that looks fine and then wastes three gigabytes of
/// someone's bandwidth before revealing a typo in a path.
final class InstrumentCatalogTests: XCTestCase {
    // MARK: Structure

    func testTheShippedCatalogHasNoStructuralProblems() {
        let problems = InstrumentCatalog.problems()
        XCTAssertTrue(
            problems.isEmpty,
            "The shipped catalog is malformed:\n" + problems.joined(separator: "\n")
        )
    }

    func testEveryAssetIsPinnedToHTTPSAndToExactBytes() throws {
        for library in InstrumentCatalog.libraries {
            for asset in library.assets {
                XCTAssertNotNil(
                    asset.httpsURL,
                    "\(library.identifier)/\(asset.identifier) is not an HTTPS URL: \(asset.sourceURL)"
                )
                XCTAssertGreaterThan(asset.byteCount, 0, "\(asset.identifier) has no pinned size.")
                switch asset.digest.algorithm {
                case .sha256:
                    XCTAssertEqual(asset.digest.hexValue.count, 64)
                case .gitBlobSHA1:
                    XCTAssertEqual(asset.digest.hexValue.count, 40)
                }
            }
        }
    }

    func testTheGitHubIndexParsedEveryLineItWasGiven() {
        let lines = CuratedInstrumentLibraries.vsco2Index
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(
            CuratedInstrumentLibraries.vsco2CommunityEdition.assets.count,
            lines.count,
            """
            The pinned index has \(lines.count) lines but produced a different \
            number of assets, so a line was silently dropped and the library \
            would install incomplete.
            """
        )
    }

    func testEveryGitHubAssetIsPinnedToTheOneCommitTheCatalogNames() {
        let prefix = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/"
            + CuratedInstrumentLibraries.vsco2Commit + "/"
        for asset in CuratedInstrumentLibraries.vsco2CommunityEdition.assets {
            XCTAssertTrue(
                asset.sourceURL.hasPrefix(prefix),
                """
                \(asset.identifier) is not pinned to the catalog's commit. A URL \
                pointing at a branch would stop being byte-stable the next time \
                anyone pushed.
                """
            )
        }
    }

    func testPathsWithSpacesAndSharpsSurviveURLEncoding() {
        // `Harpsi2_Normal_A#2_rr1.wav` is the case that matters: an unescaped
        // `#` truncates the URL at the fragment and fetches a directory.
        let encoded = PinnedGitHubAssets.encodePath("Keys/Upright Piano/A#2 v1,x.wav")
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertFalse(encoded.contains("#"))
        XCTAssertFalse(encoded.contains(","))
        XCTAssertTrue(encoded.contains("/"), "Path separators must not be escaped.")
        XCTAssertNotNil(URL(string: "https://example.invalid/" + encoded))
    }

    func testAssetIdentifiersProduceDistinctStagingFileNames() {
        for library in InstrumentCatalog.libraries {
            var seen: Set<String> = []
            for asset in library.assets {
                let name = AssetStagingArea.stagingFileName(forAssetID: asset.identifier)
                XCTAssertTrue(
                    seen.insert(name).inserted,
                    "\(library.identifier): two assets stage into the same file (\(name))."
                )
            }
        }
    }

    // MARK: Licences

    func testEveryLibraryIsMirrorableAndCreditedWhereItsLicenceSaysSo() {
        for library in InstrumentCatalog.libraries {
            XCTAssertEqual(
                library.licence.redistribution, .mirrorable,
                """
                \(library.identifier) is in the catalog but is not mirrorable. \
                A hotlink-only source must not be curated content.
                """
            )
            if library.licence.spdxIdentifier == "CC0-1.0" {
                XCTAssertFalse(
                    library.licence.requiresAttribution,
                    "CC0 requires no attribution; claiming otherwise misleads the owner."
                )
            } else {
                XCTAssertTrue(
                    library.licence.requiresAttribution,
                    "\(library.identifier) is \(library.licence.spdxIdentifier) and names no credit."
                )
                XCTAssertTrue(
                    library.licence.requiredAttribution.contains(library.publisher.split(separator: " and ").first ?? ""),
                    "\(library.identifier)'s credit does not name its publisher."
                )
            }
            XCTAssertTrue(library.licence.textURL.hasPrefix("https://"))
            XCTAssertTrue(library.homepageURL.hasPrefix("https://"))
        }
    }

    // MARK: REQ-020 coverage, including what is missing

    func testTheCatalogCoversEveryREQ020FamilyExceptTheOneItHonestlyCannot() {
        let covered = Set(InstrumentCatalog.libraries.flatMap(\.families))
        for family in InstrumentCoverage.Family.allCases {
            XCTAssertTrue(
                covered.contains(family),
                "No curated library covers \(family.displayName)."
            )
        }
    }

    func testTheNamedREQ020InstrumentsAreEachCoveredBySomeLibrary() {
        let names = InstrumentCatalog.libraries
            .flatMap(\.coverage)
            .map { $0.name.lowercased() }

        // REQ-020's own list, minus harpsichord — see the test below, which
        // asserts the gap deliberately rather than letting it be discovered.
        let required = [
            "violin", "viola", "cello", "contrabass",
            "flute", "piccolo", "oboe", "clarinet", "bassoon",
            "trumpet", "horn", "trombone", "tuba",
            "piano", "organ", "harp", "timpani"
        ]
        for instrument in required {
            XCTAssertTrue(
                names.contains { $0.contains(instrument) },
                "REQ-020 names \(instrument) and no curated library provides one."
            )
        }
    }

    /// **The one REQ-020 instrument this catalog does not cover.**
    ///
    /// An assertion rather than a comment, because a silent gap is exactly what
    /// the issue's failure behaviour forbids. The plan's harpsichord source
    /// (VCSL) ships raw WAV and no SFZ at its current head, and its SFZ release
    /// carries zero assets — so covering harpsichord means authoring mappings,
    /// which is a product decision for the owner and not something to slip into
    /// a download-manager leaf.
    ///
    /// When that decision is made and a harpsichord is added, this test fails
    /// and is deleted. That is the point: the gap cannot be quietly closed *or*
    /// quietly forgotten.
    func testHarpsichordIsKnowinglyAbsentAndTheCatalogDoesNotPretendOtherwise() {
        let names = InstrumentCatalog.libraries.flatMap(\.coverage).map { $0.name.lowercased() }
        XCTAssertFalse(
            names.contains { $0.contains("harpsichord") },
            """
            A harpsichord appeared in the catalog. If that is deliberate, delete \
            this test and tell the owner the REQ-020 gap is closed.
            """
        )
        XCTAssertEqual(
            InstrumentCatalog.knownUncoveredInstruments, ["harpsichord"],
            "The declared shortfall must be exactly what the catalog is missing."
        )
    }

    /// The declared shortfall has to stay true in both directions: an
    /// instrument named here must genuinely be absent, or the app is apologising
    /// for something it actually has.
    func testEveryDeclaredShortfallIsGenuinelyAbsentFromTheCatalog() {
        let names = InstrumentCatalog.libraries.flatMap(\.coverage).map { $0.name.lowercased() }
        for missing in InstrumentCatalog.knownUncoveredInstruments {
            XCTAssertFalse(
                names.contains { $0.contains(missing.lowercased()) },
                "\(missing) is declared uncovered but the catalog provides one."
            )
        }
    }

    func testTheAppNeverClaimsCompleteCoverageWhileSomethingIsKnownMissing() {
        let everything = Set(InstrumentCoverage.Family.allCases)
        let line = InstrumentCatalogDisplay.coverageSummary(installedFamilies: everything)
        XCTAssertTrue(
            line.contains("harpsichord"),
            """
            With every family installed the app says coverage is complete, while \
            a REQ-020 instrument is missing from inside one of them. It has to \
            say what is genuinely unavailable: \(line)
            """
        )
        XCTAssertFalse(
            line.contains("Every instrument family is downloaded."),
            "The old unqualified claim is back."
        )

        // With nothing declared missing, the line stays clean.
        XCTAssertEqual(
            InstrumentCatalogDisplay.coverageSummary(
                installedFamilies: everything, uncoveredInstruments: []
            ),
            "Everything this version can download is here."
        )
    }

    func testTheAllowedHostSetIsExactlyWhatTheCatalogDeclares() {
        let hosts = InstrumentCatalog.sourceHosts()
        XCTAssertEqual(
            hosts,
            ["raw.githubusercontent.com", "freepats.zenvoid.org", "versilian-studios.com"],
            """
            The transport refuses redirects to anything outside this set, so it             has to be exactly the hosts the catalog fetches from — no more, and             certainly no fewer.
            """
        )
        for library in InstrumentCatalog.libraries {
            for asset in library.assets {
                XCTAssertTrue(
                    hosts.contains(try! XCTUnwrap(asset.httpsURL?.host()?.lowercased())),
                    "\(asset.identifier)'s host is not in the permitted set."
                )
            }
        }
    }

    // MARK: Honesty

    func testEveryInstrumentWithThinSamplingSaysSo() {
        for library in InstrumentCatalog.libraries {
            for instrument in library.coverage where instrument.dynamicLayerCount == 1 {
                XCTAssertFalse(
                    instrument.qualityNotes.isEmpty,
                    """
                    \(instrument.identifier) has one sampled dynamic and no quality \
                    note. REQ-021 wants the limit visible before the owner relies on it.
                    """
                )
            }
        }
    }

    func testTheSectionPatchesStandingInForSoloLinesSayThatOutLoud() throws {
        for name in ["Viola section", "Cello section"] {
            let instrument = try XCTUnwrap(
                InstrumentCatalog.libraries.flatMap(\.coverage).first { $0.name == name }
            )
            XCTAssertTrue(
                instrument.qualityNotes.contains { $0.lowercased().contains("solo") },
                "\(name) is the only \(name.lowercased()) available and does not say it is a section patch."
            )
        }
    }

    // MARK: Size, and the digest that pins it

    func testTheCatalogReportsTheSizeItWillActuallyDownload() {
        let total = InstrumentCatalog.defaultSelectionByteCount
        XCTAssertEqual(
            total,
            InstrumentCatalog.libraries.reduce(0) { $0 + $1.downloadByteCount },
            "Nothing in this catalog is optional, so the default selection is all of it."
        )
        // A sanity bound, not a golden number: the point is that a catalog that
        // accidentally lost most of its assets is caught here rather than by an
        // owner whose orchestra has no strings.
        XCTAssertGreaterThan(total, 3_000_000_000, "The catalog is far smaller than the curated set.")
        XCTAssertLessThan(total, 4_000_000_000, "The catalog is far larger than the curated set.")
    }

    func testThePinnedManifestDigestChangesWhenAnAssetDoes() {
        let library = CuratedInstrumentLibraries.salamanderGrandPiano
        let original = library.pinnedManifestDigest

        let repinned = CatalogLibrary(
            identifier: library.identifier,
            name: library.name,
            publisher: library.publisher,
            summary: library.summary,
            licence: library.licence,
            homepageURL: library.homepageURL,
            assets: library.assets.map { asset in
                CatalogAsset(
                    identifier: asset.identifier,
                    sourceURL: asset.sourceURL,
                    byteCount: asset.byteCount,
                    digest: .sha256(String(repeating: "a", count: 64)),
                    payload: asset.payload
                )
            },
            coverage: library.coverage
        )

        XCTAssertNotEqual(
            original, repinned.pinnedManifestDigest,
            """
            Re-pinning a library to different bytes did not change its manifest \
            digest, so a stale install would look current.
            """
        )
    }

    // MARK: The validator itself

    func testTheValidatorCatchesTheMistakesItExistsFor() {
        let base = CuratedInstrumentLibraries.salamanderGrandPiano

        func library(assets: [CatalogAsset], coverage: [InstrumentCoverage]) -> CatalogLibrary {
            CatalogLibrary(
                identifier: base.identifier, name: base.name, publisher: base.publisher,
                summary: base.summary, licence: base.licence, homepageURL: base.homepageURL,
                assets: assets, coverage: coverage
            )
        }

        let plainFile = CatalogAsset(
            identifier: "one",
            sourceURL: "https://example.invalid/one.sfz",
            byteCount: 10,
            digest: .sha256(String(repeating: "b", count: 64)),
            payload: .file(path: "one.sfz")
        )

        // An SFZ path nothing installs — the typo that costs a whole download.
        let danglingSFZ = library(
            assets: [plainFile],
            coverage: [
                InstrumentCoverage(
                    identifier: "x", name: "X", family: .harp,
                    sfzPath: "typo.sfz", dynamicLayerCount: 1
                )
            ]
        )
        XCTAssertTrue(
            InstrumentCatalog.problems(in: [danglingSFZ]).contains { $0.contains("typo.sfz") },
            "A coverage entry pointing at a file no asset installs was not caught."
        )

        // A plain-HTTP source.
        let insecure = library(
            assets: [
                CatalogAsset(
                    identifier: "one", sourceURL: "http://example.invalid/one.sfz",
                    byteCount: 10, digest: .sha256(String(repeating: "b", count: 64)),
                    payload: .file(path: "one.sfz")
                )
            ],
            coverage: [
                InstrumentCoverage(
                    identifier: "x", name: "X", family: .harp,
                    sfzPath: "one.sfz", dynamicLayerCount: 1
                )
            ]
        )
        XCTAssertTrue(
            InstrumentCatalog.problems(in: [insecure]).contains { $0.contains("HTTPS") },
            "A plain-HTTP catalog URL was not caught."
        )

        // An install path that climbs out of the library folder.
        let escaping = library(
            assets: [
                CatalogAsset(
                    identifier: "one", sourceURL: "https://example.invalid/one.sfz",
                    byteCount: 10, digest: .sha256(String(repeating: "b", count: 64)),
                    payload: .file(path: "../elsewhere/one.sfz")
                )
            ],
            coverage: [
                InstrumentCoverage(
                    identifier: "x", name: "X", family: .harp,
                    sfzPath: "one.sfz", dynamicLayerCount: 1
                )
            ]
        )
        XCTAssertTrue(
            InstrumentCatalog.problems(in: [escaping]).contains { $0.contains("escapes") },
            "An install path escaping the library root was not caught."
        )
    }
}
