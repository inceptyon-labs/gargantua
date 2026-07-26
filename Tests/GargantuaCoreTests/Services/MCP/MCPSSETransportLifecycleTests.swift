import Foundation
import Testing
@testable import GargantuaCore

/// End-to-end lifecycle coverage for `MCPSSETransport` over a real socket:
/// open an SSE stream, sever the client connection, then drive it hard
/// enough that `NWConnection` notices — and assert the session is cleaned up
/// on the server side rather than leaked.
///
/// This is **not** a data-race regression test. It runs against a real
/// listening socket in the order "open, then die" — by the time
/// `connection.state` is checked in `MCPSSETransport.handle(_:on:)`, the
/// connection is still alive, so the code takes the `default:` branch and
/// writes the response normally. The eventual close is observed later, via
/// `NWConnection`'s pre-existing `stateUpdateHandler` path, not via the
/// `.cancelled`/`.failed` branch taken when the connection has already died
/// by the time the SSE stream response would be written. Nothing here
/// exercises that branch; it verifies SSE session cleanup on peer
/// disconnect instead.
@Suite("MCP SSE transport lifecycle")
struct MCPSSETransportLifecycleTests {
    private typealias TCPClient = MCPSSETransportTestSupport.TCPClient

    /// Records `onConnectionClose` invocations from a background NWConnection
    /// queue so the test can assert every opened SSE session was eventually
    /// closed, without racing on a bare `var`/`Set` itself.
    private final class ConnectionCloseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var closedRawValues: Set<String> = []

        func record(_ connection: MCPConnectionID) {
            lock.lock()
            closedRawValues.insert(connection.rawValue)
            lock.unlock()
        }

        func contains(_ rawValue: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return closedRawValues.contains(rawValue)
        }
    }

    private static let echoHandler: MCPConnectionMessageHandler = { request, _ in
        guard !request.isNotification else { return nil }
        return .success(
            id: request.id ?? .null,
            result: .object(["ok": .bool(true)])
        )
    }

    /// This test exercises the full, real lifecycle end to end: open an SSE
    /// stream over a real socket, sever the client connection, then drive a
    /// `/message` POST for that session id so the router's event sink
    /// attempts to write to the now-dead connection. That failed write is
    /// what causes `NWConnection` to transition to `.failed` and invoke
    /// `stateUpdateHandler`, which must read the session id back out of the
    /// box and call `router.closeStream(sessionID:)` — otherwise the
    /// session is leaked forever (never evicted from the router's session
    /// table, and `onConnectionClose` never fires for it).
    @Test("a connection that fails after its SSE stream opens still closes the session")
    func failedConnectionAfterOpenClosesItsSession() throws {
        let port = try MCPSSETransportTestSupport.findFreePort()
        let recorder = ConnectionCloseRecorder()
        let transport = MCPSSETransport(
            configuration: MCPSSEServerConfiguration(isEnabled: true, port: Int(port)),
            tokenProvider: { nil },
            handler: Self.echoHandler,
            onConnectionClose: { connection in recorder.record(connection) }
        )
        try transport.start()
        defer { transport.stop() }
        usleep(150_000)

        let opened = try Self.openSSEStreamThenDisconnect(port: port)
        let sessionID = try #require(opened, "expected the SSE stream to open and return a session id")

        // Nothing notices the peer disappearing until something tries to
        // use the connection again, so drive a POST for that session: the
        // router's event sink will attempt to write the resulting
        // JSON-RPC response to the now-dead connection, which is what
        // surfaces the failure to NWConnection's stateUpdateHandler.
        try Self.postMessage(port: port, sessionID: sessionID)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !recorder.contains("sse:\(sessionID)") {
            usleep(20_000)
        }

        #expect(recorder.contains("sse:\(sessionID)"), "the failed connection's SSE session was never closed (leaked)")
    }

    /// Opens an SSE stream over a real socket, reads the initial `endpoint`
    /// event to learn the session id, then closes the client connection.
    /// Returns the session id, or `nil` if the stream never opened.
    private static func openSSEStreamThenDisconnect(port: UInt16) throws -> String? {
        let client = try TCPClient(port: Int(port))
        try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let response = try client.read(until: "\n\n")
        // `client` goes out of scope at the end of this function, which
        // closes its streams (and the underlying socket) — that is the
        // "sever the client connection" step.
        return extractSessionID(from: response)
    }

    /// Sends a JSON-RPC `ping` to `/message?sessionId=` over a fresh
    /// connection. The response isn't asserted on: the point of this call
    /// is to make the router attempt an event-sink write to the dead SSE
    /// connection above, not to inspect this POST's own reply.
    private static func postMessage(port: UInt16, sessionID: String) throws {
        let client = try TCPClient(port: Int(port))
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        try client.write(
            "POST /message?sessionId=\(sessionID) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
        _ = try? client.read(until: "\r\n\r\n")
    }

    private static func extractSessionID(from response: String) -> String? {
        guard let range = response.range(of: "sessionId=") else { return nil }
        let suffix = response[range.upperBound...]
        let id = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return id.isEmpty ? nil : String(id)
    }
}
