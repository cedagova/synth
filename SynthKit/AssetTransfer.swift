import Foundation

/// Fetching pinned catalog bytes over HTTPS — the interface, with no
/// networking in it.
///
/// The whole point of the split is REQ-028. Exactly one file in the app is
/// allowed to name a networking API — the transport implementation beside this
/// one, which `NoNetworkBaselineTests` names in its allow-list. That test fails
/// the build if any other file does, which is also why this comment does not
/// spell the transport's file name out: the scan is deliberately dumb, so a
/// prose mention of a forbidden symbol trips it exactly as code would. Everything
/// that decides *what* to fetch, *where* to put it and *whether it is intact*
/// lives behind this protocol and therefore cannot reach the network even by
/// accident — which is also what makes the download manager testable against a
/// local fixture server instead of the real internet.

// MARK: - What a transfer reports

/// What the server said when the transfer opened.
public struct AssetTransferResponse: Sendable, Equatable {
    /// True when the server honoured a range request and is sending only the
    /// tail we asked for. False means it sent the whole asset, and anything
    /// already on disk has to be thrown away rather than appended to.
    public let isResumedRange: Bool

    /// Total size of the complete asset, as the server reports it — from
    /// `Content-Range` for a partial response, `Content-Length` otherwise. Nil
    /// when the server declined to say.
    public let totalByteCount: Int64?

    public init(isResumedRange: Bool, totalByteCount: Int64?) {
        self.isResumedRange = isResumedRange
        self.totalByteCount = totalByteCount
    }
}

// MARK: - What a transfer can go wrong with

/// Every way fetching pinned bytes can fail, separated by what the owner can
/// do about it.
public enum AssetTransferError: Error, Equatable, Sendable {
    /// The host could not be reached, the connection dropped, or it timed out.
    /// Nothing is wrong with the catalog or the disk; trying again later is the
    /// whole remedy.
    case sourceUnreachable(host: String, reason: String)

    /// The server answered, but not with the bytes: 404 for a source that
    /// moved, 403 for one that closed, 5xx for one that is broken.
    case sourceRefused(host: String, statusCode: Int)

    /// The response was not an HTTP response at all.
    case notAnHTTPResponse(host: String)

    /// The asset is not the size the catalog pins. The pinned bytes and the
    /// served bytes have diverged, so this is a catalog problem, not a
    /// transient one.
    case unexpectedByteCount(expected: Int64, received: Int64)

    /// The transfer was cancelled — the owner paused it, or the app is
    /// quitting. Not a failure; whatever arrived stays on disk for the resume.
    case cancelled
}

extension AssetTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnreachable(let host, let reason):
            return "Synth could not reach \(host). \(reason)"
        case .sourceRefused(let host, let statusCode):
            return "\(host) refused the download (HTTP \(statusCode))."
        case .notAnHTTPResponse(let host):
            return "\(host) answered with something that was not an HTTPS response."
        case .unexpectedByteCount(let expected, let received):
            return """
                The download was \(received) bytes, but this version of Synth expects \
                \(expected). The source has changed since this build pinned it.
                """
        case .cancelled:
            return "The download was paused."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .sourceUnreachable:
            return "Check your internet connection and try again. Anything already downloaded is kept."
        case .sourceRefused, .notAnHTTPResponse:
            return "Try again later. If it keeps happening, the source may have moved and Synth needs an update."
        case .unexpectedByteCount:
            return "Update Synth to a version whose catalog matches what the source now publishes."
        case .cancelled:
            return "Press Resume to carry on from where it stopped."
        }
    }

    /// True when trying the same thing again could reasonably work.
    ///
    /// This is what separates "your café Wi-Fi dropped" from "this build is
    /// wrong about the world", and the catalog UI shows a Retry button for
    /// exactly the first kind.
    public var isRetryable: Bool {
        switch self {
        case .sourceUnreachable, .cancelled:
            return true
        case .sourceRefused(_, let statusCode):
            // 5xx and 429 are the server having a bad day; 4xx otherwise means
            // the resource is not there for us and retrying is just noise.
            return statusCode >= 500 || statusCode == 429
        case .notAnHTTPResponse:
            return true
        case .unexpectedByteCount:
            return false
        }
    }
}

// MARK: - The interface

/// Streams the bytes of one pinned catalog asset.
///
/// Implementations must:
///
/// * refuse any URL that is not `https`;
/// * send `Range: bytes=<offset>-` when `startingAtByteOffset > 0`, and report
///   truthfully through `AssetTransferResponse.isResumedRange` whether the
///   server honoured it;
/// * deliver every byte to `receive` in order, and never call it again after it
///   throws; and
/// * translate cancellation into `AssetTransferError.cancelled`.
public protocol AssetTransferring: Sendable {
    /// Fetches `url`, optionally resuming, delivering chunks to `receive`.
    ///
    /// - Parameters:
    ///   - url: an HTTPS URL. Anything else must throw.
    ///   - startingAtByteOffset: how many bytes the caller already has.
    ///   - began: called once, before the first chunk, with what the server
    ///     said. The caller uses it to decide whether to append or restart.
    ///   - receive: called with each chunk, in order, on an unspecified thread.
    /// - Returns: the number of bytes delivered to `receive`.
    @discardableResult
    func fetch(
        _ url: URL,
        startingAtByteOffset: Int64,
        began: @escaping @Sendable (AssetTransferResponse) throws -> Void,
        receive: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64
}
