import Foundation
import Darwin
import CoreFoundation
import Testing
@testable import GargantuaCore

// MARK: - Shared MCP SSE transport test networking helpers

/// Shared raw-socket helpers used across the MCP SSE transport test suites
/// that drive a real socket (`MCPSSETransportNetworkingTests`,
/// `MCPSSETransportLifecycleTests`). `MCPSSETransportTests` exercises
/// `MCPSSERequestRouter` directly, in-process, and has no references to
/// anything in this file. Kept at file scope, nested under this enum
/// namespace to avoid colliding with other test files that declare their own
/// file-private `TCPClient` / `findFreePort` helpers.
enum MCPSSETransportTestSupport {
    /// Errors raised by `findFreePort()` and `TCPClient`.
    enum SocketError: Error {
        case writeFailed
        case readFailed
        case timedOut(String)
        case noFreePort
        case closeAbortivelyFailed(String)
    }

    /// Shared echo handler: replies to every non-notification JSON-RPC
    /// request with `{"ok": true}`. Used by every test suite in this file
    /// group that just needs *a* working handler and doesn't care about its
    /// content.
    static let echoHandler: MCPConnectionMessageHandler = { request, _ in
        guard !request.isNotification else { return nil }
        return .success(
            id: request.id ?? .null,
            result: .object(["ok": .bool(true)])
        )
    }

    /// Pulls the `sessionId` query value out of the `endpoint` event's
    /// `data:` line in a raw SSE open response, e.g.
    /// `data: /message?sessionId=<uuid>`.
    static func extractSessionID(from response: String) -> String? {
        guard let range = response.range(of: "sessionId=") else { return nil }
        let suffix = response[range.upperBound...]
        let id = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return id.isEmpty ? nil : String(id)
    }

    /// Binds an ephemeral loopback socket, reads back the port the kernel
    /// assigned, then releases it so `MCPSSETransport` (or a raw test
    /// socket) can bind that same port a moment later.
    static func findFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.noFreePort }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.noFreePort }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw SocketError.noFreePort }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Polls the real MCP SSE handshake against `127.0.0.1:port` until it
    /// succeeds or `timeout` elapses, returning whether `MCPSSETransport`'s
    /// listener is actually the one accepting connections yet.
    ///
    /// `MCPSSETransport.start()` returns before its `NWListener` has
    /// finished binding (or reported an async bind failure — that arrives
    /// later via the listener's state handler), so a fixed `usleep` after
    /// `start()` is both slower than necessary on a fast machine and not
    /// long enough on a loaded CI box. This probes the real thing instead of
    /// guessing a sleep duration.
    ///
    /// A bare TCP connect (the previous implementation) cannot tell
    /// `MCPSSETransport`'s listener apart from any other process that
    /// happens to be bound to the same port — including the losing side of
    /// a bind-conflict race, whose own listener answers a plain connect
    /// identically. Speaking the actual protocol (an unauthenticated `GET
    /// /sse`) and requiring one of our router's two possible replies to it
    /// proves the peer is our router, not just something squatting the
    /// port: either the `event: endpoint` SSE preamble (localhost bind, or
    /// LAN bind with no token configured), or a `WWW-Authenticate: Bearer`
    /// 401 (LAN bind that requires a token this unauthenticated probe
    /// doesn't send). Both strings are specific to
    /// `MCPSSERequestRouter`'s wire format; no squatter produces either one.
    ///
    /// Uses `TCPClient`, whose connect is `CFStream`-backed and therefore
    /// asynchronous: a connection that cannot succeed (nothing listening,
    /// or a bind conflict) surfaces as a stream error within milliseconds
    /// rather than blocking for the kernel's ~75s SYN timeout, so this
    /// cannot overrun `timeout` the way a raw blocking `connect()` could.
    static func waitUntilAcceptingConnections(port: UInt16, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            if speaksSSEProtocol(port: port, timeout: remaining) {
                return true
            }
            guard deadline.timeIntervalSinceNow > 0 else { return false }
            usleep(10_000)
        }
    }

    /// One readiness attempt: opens a fresh connection, sends an
    /// unauthenticated `GET /sse`, and requires one of the two responses
    /// documented on `waitUntilAcceptingConnections` within `timeout`. The
    /// connection is always torn down (via `TCPClient.deinit`) before
    /// returning, using the plain graceful close rather than
    /// `closeAbortively()` — see the note on this probe's session at the
    /// call site in `startTransport`.
    ///
    /// Reads only to the end of the HTTP headers (`\r\n\r\n`), not to the
    /// end of the SSE body: `WWW-Authenticate` is a header and never
    /// followed by a body, so waiting for `event: endpoint` specifically
    /// would spin for the full `timeout` on every attempt against a
    /// bearer-required LAN bind. The 200 response's `event: endpoint` line
    /// is body content immediately after the header terminator in the same
    /// small `connection.send(content:)` call, so by the time `\r\n\r\n` is
    /// found in the accumulated buffer it is already present too.
    private static func speaksSSEProtocol(port: UInt16, timeout: TimeInterval) -> Bool {
        guard let client = try? TCPClient(port: Int(port)) else { return false }
        do {
            try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let response = try client.read(until: "\r\n\r\n", timeout: timeout)
            return response.contains("event: endpoint")
                || response.contains("WWW-Authenticate: Bearer")
        } catch {
            return false
        }
    }

    /// Allocates a fresh loopback port, builds a transport for it via
    /// `makeTransport`, starts it, and blocks until it is actually accepting
    /// connections (see `waitUntilAcceptingConnections`).
    ///
    /// `findFreePort()` hands back a port number after closing the probe
    /// socket that reserved it, which leaves a gap where a parallel test (or
    /// another process) can claim the same port before the listener binds.
    /// `MCPSSETransport.start()` itself never throws on a bind conflict —
    /// `NWListener(using:)` only builds parameters, the actual bind happens
    /// in `listener.start(queue:)` and a conflict is reported asynchronously
    /// via the listener's state handler, not as a thrown error here. So the
    /// readiness probe below, not a caught `start()` error, is what detects
    /// that case; if it never becomes ready within `readinessTimeout`, this
    /// retries with a freshly allocated port up to `attempts` times before
    /// giving up.
    ///
    /// Session-isolation note: `waitUntilAcceptingConnections` opens a real
    /// `GET /sse` against the transport under construction, which registers a
    /// session with `MCPSSETransport` the same as any other client. Because
    /// the transport arms a receive on an opened SSE connection, the probe's
    /// graceful close *is* observed, so a test's own `onConnectionClose`
    /// recorder (e.g.
    /// `MCPSSETransportLifecycleTests.ConnectionCloseRecorder`) will see the
    /// probe's session id alongside the one the test opened itself. That is
    /// harmless: every recorder-based assertion in this suite is a
    /// `contains(_:)` check for one specific session id, never an exhaustive
    /// count, so an incidental extra entry cannot flip a passing assertion to
    /// a failing one.
    static func startTransport(
        attempts: Int = 3,
        readinessTimeout: TimeInterval = 5,
        makeTransport: (UInt16) -> MCPSSETransport
    ) throws -> (transport: MCPSSETransport, port: UInt16) {
        var lastError: Error = SocketError.noFreePort
        for _ in 0 ..< attempts {
            let port = try findFreePort()
            let transport = makeTransport(port)
            do {
                try transport.start()
            } catch {
                lastError = error
                continue
            }
            if waitUntilAcceptingConnections(port: port, timeout: readinessTimeout) {
                return (transport, port)
            }
            transport.stop()
            lastError = SocketError.timedOut(
                "MCPSSETransport on port \(port) never accepted a connection within \(readinessTimeout)s"
            )
        }
        throw lastError
    }

    /// Deadline-bounded TCP client used to drive `MCPSSETransport`'s raw
    /// HTTP/SSE wire protocol from tests.
    ///
    /// Every `read(until:)` call is bounded by `timeout` (default 2s) and
    /// throws `SocketError.timedOut` instead of blocking forever. Without
    /// this, a peer that never replies — or a port `findFreePort()` handed
    /// back that another process grabbed in the gap before the listener
    /// bound it — hangs the calling test in a raw `recv`/stream read
    /// forever. swift-testing has no per-test timeout, so that hang runs
    /// until the CI job's outer timeout kills the whole run instead of
    /// failing just this test.
    final class TCPClient {
        private let input: InputStream
        private let output: OutputStream
        private var isClosed = false

        init(port: Int) throws {
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(
                nil,
                "127.0.0.1" as CFString,
                UInt32(port),
                &readStream,
                &writeStream
            )
            self.input = try #require(readStream?.takeRetainedValue() as InputStream?)
            self.output = try #require(writeStream?.takeRetainedValue() as OutputStream?)
            input.open()
            output.open()
        }

        deinit {
            closeGracefully()
        }

        func closeGracefully() {
            guard !isClosed else { return }
            isClosed = true
            input.close()
            output.close()
        }

        /// Forces the client's TCP connection closed with `SO_LINGER` set to
        /// a zero timeout, so the kernel sends an RST instead of a graceful
        /// FIN.
        ///
        /// A plain close (what `deinit` does) is a half-close: the peer can
        /// keep sending successfully for a while after, so a test that needs
        /// the *server's* next write to fail immediately can't rely on it —
        /// that makes the observed disconnect dependent on network-stack
        /// timing. Forcing an RST here makes the peer's next write fail
        /// deterministically. Only tests that specifically need that
        /// guarantee should call this; everything else keeps the graceful
        /// close via `deinit`.
        ///
        /// Throws rather than silently degrading to a graceful close if any
        /// step fails (no `socketNativeHandle` property, a too-small handle,
        /// a negative fd, or `setsockopt` itself failing). A determinism
        /// helper that can silently stop providing determinism is worse than
        /// one that fails loudly: a caller relying on the RST to make a
        /// subsequent assertion deterministic would otherwise get a
        /// timing-dependent test with no signal that the guarantee was lost.
        func closeAbortively() throws {
            defer { closeGracefully() }
            guard let handle = CFWriteStreamCopyProperty(
                output as CFWriteStream,
                .socketNativeHandle
            ) as? Data else {
                throw SocketError.closeAbortivelyFailed(
                    "output stream has no socketNativeHandle property"
                )
            }
            guard handle.count >= MemoryLayout<Int32>.size else {
                throw SocketError.closeAbortivelyFailed(
                    "socketNativeHandle property (\(handle.count) bytes) is too small for a file descriptor"
                )
            }
            var fd: Int32 = -1
            _ = withUnsafeMutableBytes(of: &fd) { destination in
                handle.copyBytes(to: destination, count: MemoryLayout<Int32>.size)
            }
            guard fd >= 0 else {
                throw SocketError.closeAbortivelyFailed("socketNativeHandle was negative (\(fd))")
            }
            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            let result = setsockopt(
                fd, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size)
            )
            guard result == 0 else {
                throw SocketError.closeAbortivelyFailed("setsockopt(SO_LINGER) failed with errno \(errno)")
            }
        }

        func write(_ string: String) throws {
            let bytes = Array(string.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    output.write(
                        buffer.baseAddress!.advanced(by: offset),
                        maxLength: bytes.count - offset
                    )
                }
                guard written > 0 else {
                    throw SocketError.writeFailed
                }
                offset += written
            }
        }

        func read(until marker: String, timeout: TimeInterval = 2) throws -> String {
            let markerData = Data(marker.utf8)
            var data = Data()
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4_096)

            while Date() < deadline {
                if input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count > 0 {
                        data.append(buffer, count: count)
                        if data.range(of: markerData) != nil {
                            return String(bytes: data, encoding: .utf8) ?? ""
                        }
                    } else if count < 0 {
                        throw SocketError.readFailed
                    }
                } else {
                    RunLoop.current.run(
                        mode: .default,
                        before: Date().addingTimeInterval(0.01)
                    )
                }
            }

            throw SocketError.timedOut(String(bytes: data, encoding: .utf8) ?? "")
        }
    }
}
