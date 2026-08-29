import Foundation

/// Turns a pinned git tree listing into `CatalogAsset` values.
///
/// The two GitHub-hosted libraries in the catalog are downloaded file by file
/// from `raw.githubusercontent.com` at a pinned commit, rather than as one
/// archive, and the reason is worth stating because it looks like the harder
/// choice:
///
/// * GitHub's generated tag and commit archives
///   (`codeload.github.com/.../zip/refs/tags/1.1.0`) advertise **neither**
///   `Accept-Ranges` **nor** `Content-Length`, so a transfer cannot be resumed
///   and progress cannot be shown; and their bytes are **not stable over
///   time**, so a pinned checksum would eventually start failing for a library
///   that had not changed. Both of those are acceptance criteria here.
/// * `raw.githubusercontent.com` at a **commit SHA** does answer
///   `Accept-Ranges: bytes`, does report a stable `Content-Length`, and serves
///   exactly the git blob the commit names — which is also where the digest
///   comes from, rather than from us having downloaded 2.6 GB once and hashed
///   it.
///
/// So per-file is what makes resume, progress and integrity real for these two
/// libraries, and the index below is the price.
enum PinnedGitHubAssets {
    /// Parses `<git blob SHA-1>\t<byte count>\t<path>` lines.
    ///
    /// Blank lines are skipped; a malformed line is skipped rather than
    /// trapping, and `InstrumentCatalogTests` asserts the parsed count against
    /// the line count so a silent loss is a test failure rather than a
    /// mysteriously short download.
    static func parse(repositoryRawPrefix: String, index: String) -> [CatalogAsset] {
        var assets: [CatalogAsset] = []
        assets.reserveCapacity(2_600)

        for line in index.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let byteCount = Int64(fields[1])
            else { continue }

            let sha = String(fields[0])
            let path = String(fields[2])
            guard !sha.isEmpty, !path.isEmpty else { continue }

            assets.append(
                CatalogAsset(
                    identifier: sha,
                    sourceURL: repositoryRawPrefix + encodePath(path),
                    byteCount: byteCount,
                    digest: .gitBlob(sha),
                    payload: .file(path: path)
                )
            )
        }

        return assets
    }

    /// Percent-encodes each path component for a URL path.
    ///
    /// `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` is not
    /// enough on its own: these paths contain spaces, `#`, `,` and `+`, and
    /// `urlPathAllowed` leaves `#` alone — which would truncate the URL at the
    /// fragment and silently fetch a directory listing instead of
    /// `Harpsi2_Normal_A#2_rr1.wav`. So the allowed set is stated explicitly.
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
