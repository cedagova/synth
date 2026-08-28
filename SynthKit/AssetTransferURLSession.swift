import Foundation

/// **The one file in Synth that is allowed to touch the network.**
///
/// REQ-028 says the app makes no network requests except fetching pinned
/// catalog assets over HTTPS. That is enforced two ways, and this file is the
/// hole in both of them, deliberately and visibly:
///
/// 1. `Synth.entitlements` declares `com.apple.security.network.client` and
///    nothing else in the `com.apple.security.network.*` family — outbound
///    only, no listener, no incoming connections.
/// 2. `NoNetworkBaselineTests.testNoSourceFileUsesANetworkingAPI` scans every
///    Swift file under `Synth/` and `SynthKit/` for networking symbols and
///    fails on any hit. Its allow-list has exactly one entry: this file's name.
///    Adding a second is a deliberate, reviewable act.
///
/// So everything above this — the catalog, the staging area, the digest
/// checks, the installer, the asset store the playback engine reads through —
/// is structurally incapable of reaching the network, and the offline
/// guarantee (REQ-022) is a property of the code rather than a promise about
/// it.
///
/// Nothing is ever *sent* here beyond an HTTP GET for a URL the build itself
/// pins: no account, no telemetry, no user data, no request body. D9 and
/// increment 001's "local only, no cloud storage" are untouched.
public enum ShippedAssetTransfer {
    /// The transfer the app runs downloads through.
    ///
    /// A factory, and it lives here, because this is the only file permitted to
    /// name a networking type — so the app and the download manager can ask for
    /// the shipped transfer without either of them mentioning one. That is not
    /// ceremony: `NoNetworkBaselineTests` found this exact leak when the catalog
    /// screen's model spelled the class out in a default argument, which is how
    /// the guard is supposed to behave.
    public static func make() -> AssetTransferring { AssetTransferURLSession() }
}

public final class AssetTransferURLSession: NSObject, AssetTransferring, @unchecked Sendable {
    /// How long a transfer may go without receiving a byte before it is
    /// treated as a dead connection.
    private let stallTimeout: TimeInterval

    /// Ceiling on one asset's whole transfer. Generous: the curated set
    /// includes a 400 MB archive and the owner may be on a slow line.
    private let resourceTimeout: TimeInterval

    /// The only URL scheme this transfer will fetch.
    ///
    /// **`internal`, and there is exactly one reason it is not a constant.**
    /// The download tests drive this class against a loopback fixture server,
    /// and a loopback server cannot speak HTTPS without either a self-signed
    /// certificate the test cannot install or a TLS trust override in this
    /// file — and a trust override *would* be a hole in the shipped app. A
    /// scheme that only `@testable import SynthKit` can change is not: the app
    /// target imports SynthKit normally, so no shipping call site can reach the
    /// initialiser below, and the public one hard-codes `https`.
    ///
    /// `NoNetworkBaselineTests` asserts that nothing under `Synth/` mentions it.
    let permittedScheme: String

    /// How many connections to open to one host at a time.
    private let maximumConnectionsPerHost: Int

    /// One session for the whole run, and one router demultiplexing its
    /// callbacks by task.
    ///
    /// **This started life as a session per asset, and that was a real bug.**
    /// The orchestral library is 2,539 files; downloading it for real stalled
    /// dead at file 1,649 with 162 established and 83 half-closed sockets held
    /// open and the process at zero per cent CPU. A session owns its connection
    /// pool, and `finishTasksAndInvalidate()` retires it *asynchronously*, so
    /// creating and dropping one per file leaks connections faster than the
    /// system reclaims them until nothing can connect at all. It also threw away
    /// every chance of connection reuse, which is most of the cost of fetching
    /// two and a half thousand small files.
    ///
    /// One session fixes both: connections are pooled and reused, and
    /// `httpMaximumConnectionsPerHost` is a real ceiling rather than a hope.
    ///
    /// Built in `init` rather than lazily, because six transfers start at once
    /// and Swift's `lazy var` has no synchronisation at all — two of them
    /// racing would build two sessions and route half the callbacks into the
    /// one nobody is listening to.
    private let session: URLSession

    /// Demultiplexes the one session's callbacks back to the right transfer.
    private let router: TransferRouter

    public convenience override init() {
        self.init(permittedScheme: "https")
    }

    public convenience init(
        stallTimeout: TimeInterval,
        resourceTimeout: TimeInterval = 6 * 60 * 60,
        maximumConnectionsPerHost: Int = 6
    ) {
        self.init(
            permittedScheme: "https",
            stallTimeout: stallTimeout,
            resourceTimeout: resourceTimeout,
            maximumConnectionsPerHost: maximumConnectionsPerHost
        )
    }

    /// The one initialiser. `permittedScheme` is `internal`, which is what keeps
    /// the app unable to ask for anything but HTTPS — see the property above.
    init(
        permittedScheme: String,
        stallTimeout: TimeInterval = 45,
        resourceTimeout: TimeInterval = 6 * 60 * 60,
        maximumConnectionsPerHost: Int = 6
    ) {
        self.stallTimeout = stallTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumConnectionsPerHost = maximumConnectionsPerHost
        self.permittedScheme = permittedScheme

        let router = TransferRouter()
        self.router = router

        let configuration = URLSessionConfiguration.ephemeral
        // A 400 MB asset must not also be written into a URL cache; the staging
        // file is the only copy that should exist while it downloads.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // An offline machine should say so immediately rather than sit waiting
        // for a network that is not coming.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = stallTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "synth.asset-transfer"
        self.session = URLSession(
            configuration: configuration, delegate: router, delegateQueue: queue
        )

        super.init()
    }

    deinit {
        // Lets in-flight tasks finish, then retires the connection pool. A
        // session keeps its delegate alive until this is called, so skipping it
        // would leak the router as well as the sockets.
        session.finishTasksAndInvalidate()
    }

    @discardableResult
    public func fetch(
        _ url: URL,
        startingAtByteOffset: Int64,
        began: @escaping @Sendable (AssetTransferResponse) throws -> Void,
        receive: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64 {
        let host = url.host() ?? url.absoluteString

        // Belt and braces with `CatalogAsset.httpsURL`: the catalog refuses a
        // non-HTTPS URL at validation time, and the transfer refuses one again
        // here, so no future caller can route plain HTTP through this file.
        guard url.scheme?.lowercased() == permittedScheme else {
            throw AssetTransferError.sourceRefused(host: host, statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = stallTimeout
        if startingAtByteOffset > 0 {
            request.setValue("bytes=\(startingAtByteOffset)-", forHTTPHeaderField: "Range")
        }

        let sink = TransferSink(host: host, began: began, receive: receive)
        let task = session.dataTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sink.attach(continuation)
                // Registered before `resume()`, because a response can arrive
                // before the next line would otherwise have run.
                router.register(sink, for: task.taskIdentifier)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Routes one shared session's delegate callbacks to the right transfer.
private final class TransferRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: TransferSink] = [:]

    func register(_ sink: TransferSink, for taskIdentifier: Int) {
        lock.lock(); sinks[taskIdentifier] = sink; lock.unlock()
    }

    private func sink(for task: URLSessionTask) -> TransferSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) -> TransferSink? {
        lock.lock(); defer { lock.unlock() }
        return sinks.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let sink = sink(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        sink.received(response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink(for: dataTask)?.received(data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        remove(task)?.completed(with: error)
    }
}

/// Bridges one task's callbacks to one `async` call.
///
/// Every mutable field is touched only from the session's serial delegate
/// queue, or once from `attach` before `resume()` starts anything — which is
/// why the lock is only around the continuation, the one field two threads can
/// race for.
private final class TransferSink: @unchecked Sendable {
    private let host: String
    private let began: @Sendable (AssetTransferResponse) throws -> Void
    private let receive: @Sendable (Data) throws -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?

    /// Set when `receive` or `began` throws. It is the real reason the transfer
    /// stopped, so it wins over the cancellation `URLSession` reports next.
    private var sinkError: Error?

    private var deliveredByteCount: Int64 = 0

    init(
        host: String,
        began: @escaping @Sendable (AssetTransferResponse) throws -> Void,
        receive: @escaping @Sendable (Data) throws -> Void
    ) {
        self.host = host
        self.began = began
        self.receive = receive
    }

    func attach(_ continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Int64, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    // MARK: What the router hands over

    func received(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            sinkError = AssetTransferError.notAnHTTPResponse(host: host)
            completionHandler(.cancel)
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            sinkError = AssetTransferError.sourceRefused(host: host, statusCode: http.statusCode)
            completionHandler(.cancel)
            return
        }

        // 206 with a `Content-Range` is the only honest "yes, resuming". A 200
        // means the server ignored the Range header and is sending the whole
        // thing, and the caller has to be told so it discards what it had
        // rather than appending a second copy of the head.
        let isResumedRange = http.statusCode == 206
        let total: Int64?
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            total = Self.totalByteCount(fromContentRange: contentRange)
        } else if http.expectedContentLength >= 0 {
            total = http.expectedContentLength
        } else {
            total = nil
        }

        do {
            try began(AssetTransferResponse(isResumedRange: isResumedRange, totalByteCount: total))
        } catch {
            sinkError = error
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func received(_ data: Data, task: URLSessionDataTask) {
        guard sinkError == nil else { return }
        do {
            try receive(data)
            deliveredByteCount += Int64(data.count)
        } catch {
            sinkError = error
            task.cancel()
        }
    }

    func completed(with error: Error?) {
        if let sinkError {
            finish(.failure(sinkError))
            return
        }
        guard let error else {
            finish(.success(deliveredByteCount))
            return
        }
        finish(.failure(Self.translate(error, host: host)))
    }

    // MARK: Translation

    /// `bytes 100-999/1000` → `1000`. `bytes 100-999/*` → nil.
    static func totalByteCount(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return total == "*" ? nil : Int64(total)
    }

    /// Foundation's URL errors, sorted into the two cases that matter: the
    /// owner paused it, or the network could not deliver it.
    static func translate(_ error: Error, host: String) -> Error {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return AssetTransferError.sourceUnreachable(host: host, reason: nsError.localizedDescription)
        }
        if nsError.code == NSURLErrorCancelled {
            return AssetTransferError.cancelled
        }
        return AssetTransferError.sourceUnreachable(host: host, reason: nsError.localizedDescription)
    }
}
