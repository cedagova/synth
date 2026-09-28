import CryptoKit
import Foundation
import XCTest
@testable import SynthKit

/// The VSCO 2 CE file index ships as a bundled SynthKit resource,
/// `VSCO2Index.tsv`. These tests pin its bytes, prove it loads through the
/// framework bundle, and prove a missing or damaged copy is an error rather
/// than a quietly short catalog.
final class VSCO2IndexResourceTests: XCTestCase {
    /// SHA-256 of `SynthKit/VSCO2Index.tsv`. An edit to the index — deliberate
    /// or not — changes which bytes the catalog pins, so it must change this
    /// value in the same commit.
    static let pinnedSHA256 = "aea0b33e40858263ebb8e0864b1c0d61b71ef35115edad9d68a8bdf0856c7bb2"

    private var resourceURL: URL? {
        CuratedInstrumentLibraries.frameworkBundle.url(
            forResource: CuratedInstrumentLibraries.vsco2IndexResource.name,
            withExtension: CuratedInstrumentLibraries.vsco2IndexResource.extension
        )
    }

    func testTheIndexLoadsThroughTheFrameworkBundle() throws {
        let bundle = CuratedInstrumentLibraries.frameworkBundle
        XCTAssertEqual(bundle.bundleIdentifier, "com.cedagova.synth.SynthKit")
        XCTAssertEqual(bundle.bundleURL.pathExtension, "framework")
        let url = try XCTUnwrap(resourceURL, "VSCO2Index.tsv is not in SynthKit.framework.")
        XCTAssertTrue(url.path.hasPrefix(bundle.bundleURL.path))
        XCTAssertEqual(try CuratedInstrumentLibraries.loadVSCO2Assets(from: bundle).count, 2539)
    }

    func testTheIndexResourceIsPinnedToItsSHA256() throws {
        let data = try Data(contentsOf: try XCTUnwrap(resourceURL))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest,
            Self.pinnedSHA256,
            "VSCO2Index.tsv changed. If that was deliberate, update the pin in the same commit."
        )
    }

    func testTheCatalogUsesTheLoadedIndex() throws {
        XCTAssertEqual(
            CuratedInstrumentLibraries.vsco2CommunityEdition.assets,
            try CuratedInstrumentLibraries.loadVSCO2Assets(from: CuratedInstrumentLibraries.frameworkBundle)
        )
    }

    func testAMissingIndexThrowsNamingTheResource() throws {
        let bundle = try temporaryBundle(index: nil)
        XCTAssertThrowsError(try CuratedInstrumentLibraries.loadVSCO2Assets(from: bundle)) { error in
            guard case let .missing(resource, _)? = error as? CuratedInstrumentLibraries.IndexLoadError else {
                return XCTFail("Expected .missing, got \(error)")
            }
            XCTAssertEqual(resource, "VSCO2Index.tsv")
        }
    }

    func testACorruptIndexThrowsNamingTheLine() throws {
        let good = "63ae2edbbb93de31199dbddbdd6618b8e0b0ae22\t5192\tBassoonStac.sfz\n"
        let cases: [(String, Int)] = [
            (good + "84e2030f33b8631d4489e05afbe020508a51dbd1\t2796\n", 2),        // missing path
            (good + "84e2030f33b8631d4489e05afbe020508a51dbd1\tabc\tX.sfz\n", 2),  // bad size
            (good + "84e2030f\t2796\tX.sfz\n", 2),                                 // short SHA
            ("<html>404</html>\n", 1),                                             // not an index
            (good.replacingOccurrences(of: "\n", with: "\r\n") + good, 1),         // CRLF line endings
        ]
        for (text, line) in cases {
            let bundle = try temporaryBundle(index: Data(text.utf8))
            XCTAssertThrowsError(try CuratedInstrumentLibraries.loadVSCO2Assets(from: bundle)) { error in
                guard case let .corrupt(resource, badLine, _)? = error as? CuratedInstrumentLibraries.IndexLoadError else {
                    return XCTFail("Expected .corrupt for \(text.debugDescription), got \(error)")
                }
                XCTAssertEqual(resource, "VSCO2Index.tsv")
                XCTAssertEqual(badLine, line)
            }
        }
    }

    func testANonUTF8OrEmptyIndexThrows() throws {
        let notUTF8 = try temporaryBundle(index: Data([0xFF, 0xFE, 0x00, 0x09]))
        XCTAssertThrowsError(try CuratedInstrumentLibraries.loadVSCO2Assets(from: notUTF8)) { error in
            XCTAssertEqual(error as? CuratedInstrumentLibraries.IndexLoadError, .notUTF8(resource: "VSCO2Index.tsv"))
        }
        let empty = try temporaryBundle(index: Data("\n\n".utf8))
        XCTAssertThrowsError(try CuratedInstrumentLibraries.loadVSCO2Assets(from: empty)) { error in
            XCTAssertEqual(error as? CuratedInstrumentLibraries.IndexLoadError, .empty(resource: "VSCO2Index.tsv"))
        }
    }

    /// A plain directory bundle holding, optionally, a `VSCO2Index.tsv`.
    private func temporaryBundle(index: Data?) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSCO2IndexResourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let index {
            try index.write(to: directory.appendingPathComponent("VSCO2Index.tsv"))
        }
        return try XCTUnwrap(Bundle(url: directory))
    }
}
