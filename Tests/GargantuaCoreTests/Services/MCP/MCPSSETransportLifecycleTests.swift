import Foundation
import Testing
@testable import GargantuaCore

/// End-to-end lifecycle coverage for `MCPSSETransport` over a real socket:
/// open an SSE stream, sever the client connection, then drive it hard
/// enough that `NWConnection` notices — and assert the session is cleaned up
/// on the server side rather than leaked. Covers two ways a client can go
/// away: an RST surfaced by a failed write after a `/message` POST, and a
/// plain graceful FIN with no POST at all.
///
/// This is **not** a data-race regression test. It runs against a real
/// listening socket in the order "open, then die," so the close is observed
/// via `NWConnection`'s ordinary `stateUpdateHandler` path — the `default:`
/// branch in `MCPSSETransport.handle(_:on:)`. See that file for the one
/// branch this test does not reach and why.
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
        let recorder = ConnectionCloseRecorder()
        let (transport, port) = try MCPSSETransportTestSupport.startTransport { port in
            MCPSSETransport(
                configuration: MCPSSEServerConfiguration(isEnabled: true, port: Int(port)),
                tokenProvider: { nil },
                handler: MCPSSETransportTestSupport.echoHandler,
                onConnectionClose: { connection in recorder.record(connection) }
            )
        }
        defer { transport.stop() }

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

    /// The companion to the test above, for the case where *nothing* ever
    /// writes to the connection again: a client GETs `/sse`, reads its
    /// endpoint event, and closes the socket without ever POSTing to
    /// `/message`. Only a receive armed on the SSE connection can observe that
    /// FIN — with none outstanding, `NWConnection` never transitions,
    /// `stateUpdateHandler` never fires, and both the router session and the
    /// connection leak for the process lifetime.
    @Test("a client that disconnects without posting still closes its session")
    func disconnectWithoutPostClosesItsSession() throws {
        let recorder = ConnectionCloseRecorder()
        let (transport, port) = try MCPSSETransportTestSupport.startTransport { port in
            MCPSSETransport(
                configuration: MCPSSEServerConfiguration(isEnabled: true, port: Int(port)),
                tokenProvider: { nil },
                handler: MCPSSETransportTestSupport.echoHandler,
                onConnectionClose: { connection in recorder.record(connection) }
            )
        }
        defer { transport.stop() }

        let client = try TCPClient(port: Int(port))
        try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let response = try client.read(until: "\n\n")
        let sessionID = try #require(
            MCPSSETransportTestSupport.extractSessionID(from: response),
            "expected the SSE stream to open and return a session id"
        )
        // A plain graceful close (FIN), deliberately — unlike the RST forced
        // by the test above. This is how a client ordinarily goes away, and
        // nothing else will ever touch this connection to surface it.
        client.closeGracefully()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !recorder.contains("sse:\(sessionID)") {
            usleep(20_000)
        }

        #expect(
            recorder.contains("sse:\(sessionID)"),
            "the disconnected client's SSE session was never closed (leaked)"
        )
    }

    /// Opens an SSE stream over a real socket, reads the initial `endpoint`
    /// event to learn the session id, then severs the client connection.
    /// Returns the session id, or `nil` if the stream never opened.
    private static func openSSEStreamThenDisconnect(port: UInt16) throws -> String? {
        let client = try TCPClient(port: Int(port))
        try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let response = try client.read(until: "\n\n")
        // A plain close is a half-close (TCP FIN): the server's next write
        // can still land, so whether it observes the disconnect depends on
        // network-stack timing. Force an RST instead so the server's next
        // write to this connection fails deterministically.
        try client.closeAbortively()
        return MCPSSETransportTestSupport.extractSessionID(from: response)
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
}
