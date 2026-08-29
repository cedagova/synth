import XCTest
@testable import SynthKit

/// The file-access surface the export opens, and the much larger one it does
/// not (REQ-026, D9).
///
/// **Increment 006 is the first time Synth writes anywhere outside its own
/// container**, so it is the first time the sandbox's file entitlements are a
/// product decision rather than a default. Through increment 005 the app
/// declared `com.apple.security.files.user-selected.read-only`; an export needs
/// write access to the file the owner names in the save panel, so that key
/// becomes `…read-write`.
///
/// This is the guard on that change, written the way `NoNetworkBaselineTests`
/// guards the network one: **the permitted key is asserted, and every broader
/// key is asserted absent.** Widening the app's reach to the owner's Documents,
/// Downloads, Music, Movies, Pictures or Desktop folders would be a product
/// decision — one nothing in this leaf needs — so it has to be made here, in
/// the test whose job is to prevent it happening by accident.
final class AudioExportEntitlementTests: XCTestCase {
    /// The one file entitlement the export needs.
    private static let permittedFileEntitlement =
        "com.apple.security.files.user-selected.read-write"

    /// Entitlements that would give Synth a folder it was never handed.
    ///
    /// Listed explicitly rather than matched by prefix, so a reader can see
    /// exactly what is being refused, and so the read-only key it replaces is
    /// caught too: declaring both would be a contradiction Apple resolves in an
    /// undocumented direction.
    private static let refusedFileEntitlements = [
        "com.apple.security.files.user-selected.read-only",
        "com.apple.security.files.downloads.read-only",
        "com.apple.security.files.downloads.read-write",
        "com.apple.security.files.all",
        "com.apple.security.assets.music.read-only",
        "com.apple.security.assets.music.read-write",
        "com.apple.security.assets.movies.read-only",
        "com.apple.security.assets.movies.read-write",
        "com.apple.security.assets.pictures.read-only",
        "com.apple.security.assets.pictures.read-write",
        "com.apple.security.temporary-exception.files.home-relative-path.read-write",
        "com.apple.security.temporary-exception.files.absolute-path.read-write"
    ]

    func testTheAppMayWriteOnlyTheFileTheOwnerNamesInASavePanel() throws {
        let plist = try Self.entitlements()

        XCTAssertEqual(
            plist["com.apple.security.app-sandbox"] as? Bool, true,
            "The App Sandbox must stay on; it is what makes every claim below meaningful."
        )
        XCTAssertEqual(
            plist[Self.permittedFileEntitlement] as? Bool, true,
            """
            The export needs \(Self.permittedFileEntitlement) to write the file the owner \
            chose. Without it REQ-026 cannot be delivered at all.
            """
        )

        for refused in Self.refusedFileEntitlements {
            XCTAssertNil(
                plist[refused],
                """
                \(refused) is declared. The export writes exactly one file — the one the \
                owner named in a save panel — so no folder-wide grant is needed, and \
                widening this is a product decision rather than a refactor.
                """
            )
        }

        // Anything new in the file-access families that this test has not been
        // taught about. A guard that only checks a fixed list silently permits
        // whatever key is invented next.
        let unexpected = plist.keys.filter { key in
            (key.hasPrefix("com.apple.security.files")
                || key.hasPrefix("com.apple.security.assets"))
                && key != Self.permittedFileEntitlement
        }
        XCTAssertEqual(
            unexpected.sorted(), [],
            "Unreviewed file-access entitlements: \(unexpected.sorted())."
        )
    }

    /// The entitlement is what lets the export write; the *reason* it is safe
    /// is that nothing writes outside the file the owner named. This pins the
    /// second half so the two cannot drift.
    ///
    /// `AudioExportStaging` may only build paths from the destination's own
    /// directory. A staged file anywhere else — a temporary directory, the
    /// container, a home-relative path — would either not be atomic with the
    /// destination or would need an entitlement the test above refuses.
    func testTheExportStagesOnlyBesideItsDestination() throws {
        let source = try String(
            contentsOf: try AudioExportTests.sourceFile("AudioExport.swift"), encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct AudioExportStaging {"))
        let staging = String(source[start.lowerBound...])

        XCTAssertTrue(
            staging.contains("let directory = self.destination.deletingLastPathComponent()"),
            "Staging no longer derives its directory from the destination."
        )
        for elsewhere in [
            "NSTemporaryDirectory", "temporaryDirectory", "applicationSupportDirectory",
            "homeDirectoryForCurrentUser", "URL(filePath: \"/"
        ] {
            XCTAssertFalse(
                staging.contains(elsewhere),
                """
                AudioExportStaging mentions \(elsewhere). Staging must sit beside the \
                destination: anywhere else is either a cross-filesystem move, which is not \
                atomic, or a location the app has no entitlement for.
                """
            )
        }
    }

    private static func entitlements() throws -> [String: Any] {
        var candidate = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = candidate.appending(path: "Synth.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                let url = candidate
                    .appending(path: "Synth")
                    .appending(path: "Synth.entitlements")
                let data = try Data(contentsOf: url)
                return try XCTUnwrap(
                    PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    "Synth.entitlements is not a plist dictionary"
                )
            }
            candidate = candidate.deletingLastPathComponent()
        }
        // Never skipped: a guard that cannot find what it guards is a failure.
        throw AudioExportTests.SourceFileNotFound(
            name: "Synth.entitlements", searchedUpwardsFrom: #filePath
        )
    }
}
