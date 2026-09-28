import XCTest
@testable import SynthKit

/// Temporary: proves the resource-built catalog equals the literal-built one
/// before the literal is deleted. Removed together with the literal.
final class VSCO2IndexLiteralEquivalenceTests: XCTestCase {
    func testTheResourceBuildsTheSameAssetsAsTheLiteral() throws {
        let fromLiteral = PinnedGitHubAssets.parse(
            repositoryRawPrefix: "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/28092772094b2d9f1148d84cea97f4545b8c687d/",
            index: CuratedInstrumentLibraries.vsco2Index
        )
        let fromResource = try CuratedInstrumentLibraries.loadVSCO2Assets(from: CuratedInstrumentLibraries.frameworkBundle)
        XCTAssertEqual(fromLiteral.count, 2539)
        XCTAssertEqual(fromResource, fromLiteral, "Resource-built assets differ from the literal-built ones.")
        XCTAssertEqual(CuratedInstrumentLibraries.vsco2CommunityEdition.assets, fromLiteral)
        let text = try String(
            contentsOf: XCTUnwrap(CuratedInstrumentLibraries.frameworkBundle.url(forResource: "VSCO2Index", withExtension: "tsv")),
            encoding: .utf8
        )
        XCTAssertEqual(text, CuratedInstrumentLibraries.vsco2Index + "\n", "Resource is not the literal byte-for-byte plus a final newline.")
    }
}
