import Foundation
import Network
import XCTest
@testable import SynthKit

/// A real HTTPS-shaped HTTP server on loopback, for the download tests.
///
/// Every failure the download manager has to survive — a killed transfer that
/// resumes, a server that ignores `Range`, a checksum that does not match, a
/// source that is simply not there — is a property of what comes back over a
/// socket. Faking `AssetTransferring` would test the manager against my idea of
/// HTTP; this tests it against `URLSession` talking to a server that really does
/// answer `206 Partial Content` with a real `Content-Range`.
///
/// It lives in the test target on purpose. `NoNetworkBaselineTests` scans
/// `Synth/` and `SynthKit/` only, so a listener here is not a hole in REQ-028 —
/// nothing that ships can accept a connection, and the app's entitlements do not
/// permit one.
///
/// Plain HTTP on `127.0.0.1`, because a self-signed TLS certificate would need
/// either a trust override in the app's transfer — a real hole in the real
/// thing — or a keychain the test cannot rely on. So the fixture is driven
/// through `makeFixtureTransfer()` below, which is the shipped
/// `AssetTransferURLSession` with only its internal, app-unreachable scheme
/// guard pointed at `http`.
final class CatalogFixtureServer: @unchecked Sendable {
    /// What the server should do with a request.
    enum Behavior {
        /// Serve the bytes, honouring `Range`.
        case serve

        /// Serve the bytes but ignore `Range` — always `200`, always from zero.
        /// This is the case that would silently corrupt a resumed file.
        case ignoreRangeRequests

        /// Serve only the first `count` bytes of whatever was asked for, then
        /// close. Simulates a dropped connection mid-transfer.
        case truncateAfter(count: Int)

        /// Answer with a status and no body.
        case refuse(statusCode: Int)

        /// Serve bytes that are the right length but the wrong content.
        case serveCorruptedBytes

        /// Serve normally, but slowly: `chunkByteCount` at a time with
        /// `delayMilliseconds` between chunks, so a transfer is still running
        /// when the test wants to pause it.
        case throttle(chunkByteCount: Int, delayMilliseconds: Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "synth.catalog.fixture")
    private let lock = NSLock()

    private var routes: [String: Data] = [:]
    private var behavior: Behavior = .serve
    private var requestLog: [(path: String, rangeHeader: String?)] = []

    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    // MARK: Lifecycle

    func start() throws {
        let ready = XCTestExpectation(description: "fixture server listening")
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        try ready.waitUpToSeconds(10)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: Configuration

    /// Registers `data` at `/<name>`.
    func serve(_ data: Data, at name: String) {
        lock.lock(); routes["/" + name] = data; lock.unlock()
    }

    func setBehavior(_ newBehavior: Behavior) {
        lock.lock(); behavior = newBehavior; lock.unlock()
    }

    /// Every request the server has answered, in order.
    var requests: [(path: String, rangeHeader: String?)] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    func url(for name: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(name)")!
    }

    // MARK: Serving

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, accumulated: buffer)
                }
                return
            }

            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            self.respond(to: header, on: connection)
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let path = String(parts[1])

        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        lock.lock()
        requestLog.append((path, rangeHeader))
        let body = routes[path]
        let currentBehavior = behavior
        lock.unlock()

        guard let body else {
            send(status: 404, reason: "Not Found", headers: [:], body: Data(), on: connection)
            return
        }

        if case .refuse(let statusCode) = currentBehavior {
            send(
                status: statusCode, reason: "Refused", headers: [:], body: Data(), on: connection
            )
            return
        }

        let payload: Data
        if case .serveCorruptedBytes = currentBehavior {
            // Same length, one byte different — exactly the shape of a
            // corrupted transfer that a length check cannot catch.
            var mutated = body
            if !mutated.isEmpty {
                let index = mutated.startIndex
                mutated[index] = mutated[index] ^ 0xFF
            }
            payload = mutated
        } else {
            payload = body
        }

        var start = 0
        var isPartial = false
        if case .ignoreRangeRequests = currentBehavior {
            start = 0
        } else if let rangeHeader, let parsed = Self.parseRangeStart(rangeHeader) {
            guard parsed <= payload.count else {
                send(
                    status: 416, reason: "Range Not Satisfiable",
                    headers: ["Content-Range": "bytes */\(payload.count)"],
                    body: Data(), on: connection
                )
                return
            }
            start = parsed
            isPartial = true
        }

        var slice = Data(payload.suffix(from: payload.startIndex + start))
        var closeEarly = false
        if case .truncateAfter(let count) = currentBehavior, slice.count > count {
            slice = Data(slice.prefix(count))
            closeEarly = true
        }

        var headers: [String: String] = [
            "Accept-Ranges": "bytes",
            "Content-Type": "application/octet-stream"
        ]
        if isPartial {
            headers["Content-Range"] = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
        }
        // Deliberately truthful about the *whole* remaining length even when the
        // body is cut short, because that is what a dropped connection looks
        // like: the promise was kept until it was not.
        headers["Content-Length"] = String(payload.count - start)

        if case .throttle(let chunkByteCount, let delayMilliseconds) = currentBehavior {
            sendThrottled(
                status: isPartial ? 206 : 200,
                reason: isPartial ? "Partial Content" : "OK",
                headers: headers,
                body: slice,
                chunkByteCount: chunkByteCount,
                delayMilliseconds: delayMilliseconds,
                on: connection
            )
            return
        }

        send(
            status: isPartial ? 206 : 200,
            reason: isPartial ? "Partial Content" : "OK",
            headers: headers,
            body: slice,
            on: connection,
            closeWithoutFinishing: closeEarly
        )
    }

    /// Writes the head, then dribbles the body out so the transfer stays open
    /// long enough to be cancelled.
    private func sendThrottled(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        chunkByteCount: Int,
        delayMilliseconds: Int,
        on connection: NWConnection
    ) {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        connection.send(content: Data(text.utf8), completion: .idempotent)

        var offset = 0
        func sendNext() {
            guard offset < body.count else {
                connection.cancel()
                return
            }
            let end = min(offset + chunkByteCount, body.count)
            let chunk = Data(body[(body.startIndex + offset)..<(body.startIndex + end)])
            offset = end
            connection.send(
                content: chunk,
                completion: .contentProcessed { [queue] error in
                    guard error == nil else { connection.cancel(); return }
                    queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
                        sendNext()
                    }
                }
            )
        }
        sendNext()
    }

    private func send(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        on connection: NWConnection,
        closeWithoutFinishing: Bool = false
    ) {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(value)\r\n"
        }
        if headers["Content-Length"] == nil {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "Connection: close\r\n\r\n"

        var response = Data(text.utf8)
        response.append(body)

        connection.send(
            content: response,
            completion: .contentProcessed { [queue] _ in
                guard closeWithoutFinishing else {
                    connection.cancel()
                    return
                }
                // A truncated response promises more bytes in `Content-Length`
                // than it sends, and then hangs up. Cancelling the instant the
                // write completes races URLSession's own delivery of those
                // bytes to its delegate — the connection error can arrive first
                // and the partial data be dropped, which would make the resume
                // test flaky rather than wrong. A real dropped connection has a
                // gap before it too, so waiting is the faithful thing as well
                // as the stable one.
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    connection.cancel()
                }
            }
        )
    }

    /// `bytes=100-` → `100`.
    static func parseRangeStart(_ value: String) -> Int? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int(spec[spec.startIndex..<dash])
    }
}

// MARK: - Talking to the fixture

/// The real `AssetTransferURLSession`, pointed at the loopback fixture.
///
/// This is the shipped transfer — same request building, same `Range` header,
/// same `206`/`200` interpretation, same `TransferSink`, same error
/// translation. The only thing that differs is the scheme its guard accepts,
/// through the `internal` initialiser that exists for exactly this and that the
/// app target cannot reach. So what the download tests exercise is the code that
/// ships, not a stand-in for it.
func makeFixtureTransfer(stallTimeout: TimeInterval = 10) -> AssetTransferring {
    AssetTransferURLSession(
        permittedScheme: "http", stallTimeout: stallTimeout, resourceTimeout: 120,
        maximumConnectionsPerHost: 6
    )
}

// MARK: - Small helpers

extension XCTestExpectation {
    /// `XCTWaiter` without needing a test case instance, so the fixture server
    /// can wait for its own listener.
    func waitUpToSeconds(_ seconds: TimeInterval) throws {
        let result = XCTWaiter().wait(for: [self], timeout: seconds)
        guard result == .completed else {
            throw NSError(
                domain: "CatalogFixtureServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(expectationDescription) timed out"]
            )
        }
    }
}
