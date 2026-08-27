import XCTest
@testable import SynthKit

/// REQ-028 baseline for increment 001: Synth makes no network requests at all.
///
/// Two independent guards, both checked here:
///
/// 1. The App Sandbox is on and declares no network entitlement, so macOS
///    denies outbound connections regardless of what the code does.
/// 2. No source file reaches for a networking API in the first place.
///
/// The curated instrument download leaf (INS001, increment 005) is the one
/// place that may relax guard 1 — deliberately, by editing this test.
final class NoNetworkBaselineTests: XCTestCase {
    /// Repository root, found by walking up from this file's compile-time
    /// location to the directory holding `Synth.xcodeproj`.
    private static func repositoryRoot() throws -> URL {
        var candidate = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = candidate.appending(path: "Synth.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        // Never skip: a guard that cannot find what it guards is a failure.
        throw RepositoryRootNotFound(searchedUpwardsFrom: #filePath)
    }

    struct RepositoryRootNotFound: Error, CustomStringConvertible {
        let searchedUpwardsFrom: String
        var description: String {
            "Could not find the directory containing Synth.xcodeproj above \(searchedUpwardsFrom); "
                + "the no-network guard cannot run."
        }
    }

    private static let scannedSourceDirectories = ["Synth", "SynthKit"]

    /// Symbols that would open a network connection on Apple platforms.
    private static let forbiddenNetworkSymbols = [
        "URLSession",
        "NSURLSession",
        "URLRequest",
        "NSURLConnection",
        "NWConnection",
        "NWBrowser",
        "NWListener",
        "CFSocket",
        "CFStreamCreatePairWithSocketToHost",
        "getaddrinfo"
    ]

    func testAppDeclaresSandboxWithoutAnyNetworkEntitlement() throws {
        let entitlementsURL = try Self.repositoryRoot()
            .appending(path: "Synth")
            .appending(path: "Synth.entitlements")

        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "Synth.entitlements is not a plist dictionary"
        )

        XCTAssertEqual(
            plist["com.apple.security.app-sandbox"] as? Bool,
            true,
            "The App Sandbox must stay on: it is what structurally denies network access."
        )

        let networkKeys = plist.keys.filter { $0.hasPrefix("com.apple.security.network") }
        XCTAssertTrue(
            networkKeys.isEmpty,
            "Increment 001 must declare no network entitlement; found \(networkKeys)"
        )
    }

    func testNoSourceFileUsesANetworkingAPI() throws {
        let fileManager = FileManager.default
        var scannedFileCount = 0

        for directoryName in Self.scannedSourceDirectories {
            let root = try Self.repositoryRoot()
            // Resolve first: `enumerator(at:)` yields nothing for a URL that is
            // itself a symlink to a directory.
            let directory = root.appending(path: directoryName).resolvingSymlinksInPath()
            let enumerator = try XCTUnwrap(
                fileManager.enumerator(at: directory, includingPropertiesForKeys: nil),
                "Could not scan \(directory.path(percentEncoded: false))"
            )

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                scannedFileCount += 1
                let source = try String(contentsOf: fileURL, encoding: .utf8)

                if source.contains("import Network") {
                    XCTFail("\(fileURL.lastPathComponent) imports the Network framework")
                }
                for symbol in Self.forbiddenNetworkSymbols where source.contains(symbol) {
                    XCTFail("\(fileURL.lastPathComponent) references the networking symbol \(symbol)")
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFileCount,
            0,
            "The source scan found no Swift files — the repository layout changed and this guard is blind."
        )
    }
}
