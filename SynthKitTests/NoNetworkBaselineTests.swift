import XCTest
@testable import SynthKit

/// REQ-028: the only thing Synth's network access is for is fetching pinned
/// instrument-catalog assets over HTTPS.
///
/// Two independent guards, both checked here:
///
/// 1. The App Sandbox is on and declares **outbound HTTPS only** — the client
///    entitlement and nothing else in the `com.apple.security.network.*`
///    family — so macOS denies incoming connections and listeners regardless
///    of what the code does.
/// 2. Exactly one source file may name a networking API. Every other file under
///    `Synth/` and `SynthKit/` is still scanned and still fails on any hit.
///
/// ## Why this test was relaxed, and how narrowly
///
/// Increment 001 wrote this guard as "no network entitlement, no networking
/// symbol anywhere", and named the curated instrument download leaf (INS001,
/// increment 005) as the one place allowed to relax it. This is that leaf and
/// this is that relaxation. It is deliberately the smallest one that lets
/// REQ-020 and REQ-022 exist at all:
///
/// * **The entitlement is asserted, not merely permitted.** The test now
///   requires `com.apple.security.network.client` to be exactly `true` and
///   still fails for *any other* `com.apple.security.network.*` key — so
///   `network.server` cannot be added without this test going red.
/// * **The source scan keeps running everywhere.** One file,
///   `AssetTransferURLSession.swift`, is allow-listed by name. A second entry
///   is a deliberate, reviewable edit to this array, and a networking symbol in
///   any other file — including a new one — still fails the build.
///
/// What did **not** change: nothing is uploaded, there is no account, no
/// telemetry, no analytics, and no user data leaves the machine. D9 (the app
/// ships no music) and increment 001's "local only, no cloud storage" stand
/// exactly as written. The network does one thing: HTTP GET on URLs this build
/// itself pins, whose bytes are then checked against a pinned digest.
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

    /// The complete set of files permitted to name a networking API.
    ///
    /// One entry. Adding a second means widening the app's network surface,
    /// which is a product decision, not a refactor — so it has to be made here,
    /// in the test whose job is to prevent it.
    /// Matched on the path relative to the repository root, not on the file
    /// name: two files sharing a basename anywhere under the scanned roots
    /// would otherwise both inherit the one exemption.
    private static let filesAllowedToUseNetworking: Set<String> = [
        "SynthKit/AssetTransferURLSession.swift"
    ]

    /// The one entitlement the download manager needs: outbound connections.
    private static let permittedNetworkEntitlement = "com.apple.security.network.client"

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
        "getaddrinfo",
        // Not obviously networking, and that is exactly why it is listed:
        // `Data(contentsOf:)` honours the URL's scheme, so it performs a
        // synchronous network fetch for an http/https URL. Local reads use
        // `FileHandle`, which cannot leave the filesystem.
        "Data(contentsOf:"
    ]

    func testAppDeclaresSandboxWithOutboundHTTPSAndNothingElse() throws {
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

        XCTAssertEqual(
            plist[Self.permittedNetworkEntitlement] as? Bool,
            true,
            """
            The catalog download manager needs \(Self.permittedNetworkEntitlement). \
            Without it, REQ-020 and REQ-022 cannot be delivered at all.
            """
        )

        let otherNetworkKeys = plist.keys
            .filter { $0.hasPrefix("com.apple.security.network") }
            .filter { $0 != Self.permittedNetworkEntitlement }
        XCTAssertTrue(
            otherNetworkKeys.isEmpty,
            """
            Outbound HTTPS is the entire permitted network surface. \
            Found \(otherNetworkKeys.sorted()), which would let Synth accept \
            incoming connections — nothing in this product needs that.
            """
        )
    }

    func testNoSourceFileOutsideTheDownloadTransportUsesANetworkingAPI() throws {
        let fileManager = FileManager.default
        var scannedFileCount = 0
        var allowedFilesSeen: Set<String> = []

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
                let name = fileURL.lastPathComponent
                let relativePath = directoryName + "/" + fileURL.lastPathComponent

                if Self.filesAllowedToUseNetworking.contains(relativePath) {
                    allowedFilesSeen.insert(relativePath)
                    continue
                }

                let source = try String(contentsOf: fileURL, encoding: .utf8)

                if source.contains("import Network") {
                    XCTFail("\(name) imports the Network framework")
                }
                for symbol in Self.forbiddenNetworkSymbols where source.contains(symbol) {
                    XCTFail("\(name) references the networking symbol \(symbol)")
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFileCount,
            0,
            "The source scan found no Swift files — the repository layout changed and this guard is blind."
        )

        // An allow-list entry for a file that no longer exists is a guard with
        // a hole in it: the next file to take that name inherits the exemption
        // without anyone deciding to give it one.
        XCTAssertEqual(
            allowedFilesSeen,
            Self.filesAllowedToUseNetworking,
            """
            The networking allow-list names files the scan never found: \
            \(Self.filesAllowedToUseNetworking.subtracting(allowedFilesSeen).sorted()). \
            Remove them, or the exemption outlives the file it was granted to.
            """
        )
    }

    /// The allow-listed file is exempt from the symbol scan, so nothing else
    /// checks that it is still the download transport rather than some file
    /// that inherited the name. This does.
    func testTheOneNetworkingFileIsStillTheCatalogDownloadTransport() throws {
        let url = try Self.repositoryRoot()
            .appending(path: "SynthKit")
            .appending(path: "AssetTransferURLSession.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            source.contains("AssetTransferring"),
            "The allow-listed networking file no longer implements the catalog asset transfer."
        )
        XCTAssertTrue(
            source.contains("url.scheme?.lowercased() == permittedScheme"),
            "The allow-listed networking file no longer checks the URL's scheme at all."
        )
        // The scheme guard runs once, on the URL the catalog supplies. Without a
        // redirect delegate, URLSession follows a 3xx to any host on its own and
        // that guard never sees the request that actually fetched the bytes.
        XCTAssertTrue(
            source.contains("willPerformHTTPRedirection"),
            """
            The transport no longer implements a redirect delegate, so REQ-028's             scoping to the catalog's declared sources is enforced on the first             request and nowhere after it.
            """
        )
        XCTAssertTrue(
            source.contains("permittedHosts.contains(host)"),
            "The redirect delegate no longer checks the destination host."
        )
        // Every `public` initialiser must pin the scheme itself. The only
        // initialiser that takes one is `internal`, which is what keeps the app
        // — which imports SynthKit normally — unable to ask for anything else.
        let publicInitialiserCount = source.components(separatedBy: "public convenience").count - 1
        XCTAssertGreaterThan(publicInitialiserCount, 0, "The transfer has no public initialiser.")
        XCTAssertEqual(
            source.components(separatedBy: #"permittedScheme: "https""#).count - 1,
            publicInitialiserCount,
            """
            A public initialiser of the transfer does not hard-code https. \
            REQ-028 permits HTTPS catalog fetches and nothing else.
            """
        )
        XCTAssertFalse(
            source.contains("public init(\n        permittedScheme"),
            "The scheme-taking initialiser became public, so the app could now ask for plain HTTP."
        )

        // `permittedScheme` is internal so that only `@testable import` can
        // change it. That is only true while the app target never names it.
        let appDirectory = try Self.repositoryRoot().appending(path: "Synth")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: appDirectory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil
            )
        )
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let appSource = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                appSource.contains("permittedScheme"),
                """
                \(fileURL.lastPathComponent) names permittedScheme. That knob \
                exists only so the loopback test fixture can be plain HTTP; the \
                app must never be able to fetch anything but HTTPS.
                """
            )
        }
        XCTAssertFalse(
            source.contains("httpBody"),
            """
            The download transport sends a request body, so it is uploading \
            something. REQ-028 and D9 permit fetching pinned assets, not sending.
            """
        )
        XCTAssertFalse(
            source.contains("NWListener"),
            "The download transport opens a listener; nothing in this product accepts connections."
        )
    }
}
