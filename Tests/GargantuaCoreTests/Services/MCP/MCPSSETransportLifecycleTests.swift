import Foundation
import Testing
@testable import GargantuaCore

/// End-to-end lifecycle coverage for `MCPSSETransport` over a real socket:
/// open an SSE stream, sever the client connection, then drive it hard
/// enough that `NWConnection` notices — and assert the session is cleaned up
/// on the server side rather than leaked. Covers three ways a client can go
/// away: an RST surfaced by a failed write after a `/message` POST, a plain
/// graceful FIN with no POST at all, and a graceful FIN after the client has
/// written on the SSE socket — which is what forces the drain loop to re-arm
/// rather than get by on its first receive. Also covers the server-initiated
/// case: the client stays connected and the transport itself is stopped.
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

    /// Guards the *re-arm* arm of the transport's drain loop, which the test
    /// above cannot reach: it never writes on the SSE socket, so one receive
    /// is enough to see its FIN. A client that sends anything at all after the
    /// handshake consumes that receive, and if the loop does not arm another
    /// the connection is back to having none pending — its later FIN goes
    /// unobserved and the session leaks exactly as it did before the drain
    /// loop existed. Without this test, deleting the recursive re-arm leaves
    /// the whole SSE suite green.
    ///
    /// The byte written is deliberately not a valid HTTP request: the SSE
    /// response has no `Content-Length` and an unterminated body, so the
    /// connection is not reusable and the transport is right to discard
    /// whatever arrives. What is asserted is only that discarding it does not
    /// cost us the disconnect.
    ///
    /// Writing the byte and immediately closing would NOT prove anything: TCP
    /// is free to carry that byte and the FIN in one segment, which the
    /// transport sees as a single receive completion with both data and
    /// `isComplete` — and that completion cancels the connection whether or
    /// not the loop re-arms, so a broken re-arm would still pass. The POST
    /// round trip below is the barrier that separates them, and it is
    /// ordering, not timing: every connection callback runs on the transport's
    /// one serial queue, so the receive completion carrying "X" is enqueued
    /// (and run) before the POST's bytes can even be accepted on that same
    /// queue. By the time the resulting `message` event arrives back here, the
    /// drain loop has provably already decided whether to re-arm, and only
    /// then does the client close.
    @Test("a client that writes on its SSE socket before disconnecting still closes its session")
    func writeThenDisconnectClosesItsSession() throws {
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
        // Consume the receive armed after the `.opened` write. Only a re-armed
        // one can go on to observe the close below.
        try client.write("X")

        // Barrier — see the note above. Reading this event proves the "X"
        // receive completion has already run on the transport's serial queue,
        // so the close below lands on a connection with either a re-armed
        // receive or none at all, never on the same completion as the byte.
        try Self.postMessage(port: port, sessionID: sessionID)
        _ = try client.read(until: "\n\n")

        client.closeGracefully()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !recorder.contains("sse:\(sessionID)") {
            usleep(20_000)
        }

        #expect(
            recorder.contains("sse:\(sessionID)"),
            "the session leaked: the drain loop did not re-arm after the client's write"
        )
    }

    /// The server-initiated counterpart to the three tests above, which all
    /// cover the *client* going away. Here the client stays put and the
    /// transport is stopped underneath it: `stop()` used to cancel only the
    /// `NWListener`, so a connected client's `NWConnection` and its entry in
    /// `router.sessions` both survived the transport that owned them.
    ///
    /// Cancelling the connection is what evicts the session — it reaches the
    /// same `stateUpdateHandler` the client-disconnect tests rely on — so this
    /// asserts on the recorder rather than on the socket.
    @Test("stopping the transport closes the session of a client still connected")
    func stopClosesLiveSessions() throws {
        let recorder = ConnectionCloseRecorder()
        let (transport, port) = try MCPSSETransportTestSupport.startTransport { port in
            MCPSSETransport(
                configuration: MCPSSEServerConfiguration(isEnabled: true, port: Int(port)),
                tokenProvider: { nil },
                handler: MCPSSETransportTestSupport.echoHandler,
                onConnectionClose: { connection in recorder.record(connection) }
            )
        }
        // Still deferred even though the body stops it: a `#require` failure
        // below would otherwise leave the listener bound. Stopping twice is a
        // no-op — the listener is already nil and the registry already empty.
        defer { transport.stop() }

        let client = try TCPClient(port: Int(port))
        try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let response = try client.read(until: "\n\n")
        let sessionID = try #require(
            MCPSSETransportTestSupport.extractSessionID(from: response),
            "expected the SSE stream to open and return a session id"
        )

        // The client is deliberately left connected and untouched, and the
        // lifetime has to be made explicit: `client`'s last use is the read
        // above, so ARC is free to release it here. Its `deinit` closes the
        // socket, which the drain loop would observe as EOF and close the
        // session on its own — the assertion below would then pass against a
        // transport whose `stop()` did nothing at all.
        withExtendedLifetime(client) {
            transport.stop()

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && !recorder.contains("sse:\(sessionID)") {
                usleep(20_000)
            }

            #expect(
                recorder.contains("sse:\(sessionID)"),
                "stop() left the connected client's SSE session standing (leaked)"
            )
        }
    }

    /// Guards the two properties that keep the shutdown registry from becoming
    /// a second leak in place of the one this file's other tests cover: the
    /// boxes are weak, and `trackForShutdown` prunes dead ones. Neither is
    /// observable through the transport's behaviour — make the box strong, or
    /// delete the prune, and every other test in the suite still passes while
    /// the registry grows once per connection for the process lifetime.
    ///
    /// Counting is the only available signal, hence the internal
    /// `trackedConnectionCount`. The bound is loose on purpose: a connection
    /// whose session has just closed may not have deallocated yet, so one or
    /// two live boxes are expected. Either mutant lands at `clientCount + 2`,
    /// far outside it.
    @Test("the shutdown registry does not accumulate connections that have gone away")
    func shutdownRegistryPrunesDeadConnections() throws {
        let clientCount = 6
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

        for _ in 0 ..< clientCount {
            let client = try TCPClient(port: Int(port))
            try client.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let response = try client.read(until: "\n\n")
            let sessionID = try #require(
                MCPSSETransportTestSupport.extractSessionID(from: response),
                "expected the SSE stream to open and return a session id"
            )
            client.closeGracefully()

            // Wait for the server to observe this disconnect before opening
            // the next client, so each iteration leaves a dead connection
            // behind for the following accept to prune.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && !recorder.contains("sse:\(sessionID)") {
                usleep(20_000)
            }
            #expect(recorder.contains("sse:\(sessionID)"), "client's session never closed")
        }

        // Only an accept runs the prune, and deallocation is not synchronized
        // with `onConnectionClose` — the framework can hold a just-closed
        // connection's receive closure a moment longer — so a single probe
        // could sample before the last corpses are collectable and report a
        // high count on a loaded machine. Drive prune passes until the count
        // settles instead of trusting one shot.
        //
        // This converges rather than merely retrying: with the registry
        // working, each pass reaps the previous pass's probe and the count
        // stays at one or two. With a strong box or no prune, every pass adds
        // an entry and the count only climbs, so the loop runs out the clock
        // and fails — which is the behaviour being guarded.
        let bound = 3
        var tracked = transport.trackedConnectionCount
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && tracked > bound {
            let probe = try TCPClient(port: Int(port))
            try probe.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let probeResponse = try probe.read(until: "\n\n")
            let probeSessionID = try #require(
                MCPSSETransportTestSupport.extractSessionID(from: probeResponse),
                "expected the probe's SSE stream to open and return a session id"
            )
            probe.closeGracefully()
            while Date() < deadline && !recorder.contains("sse:\(probeSessionID)") {
                usleep(20_000)
            }
            tracked = transport.trackedConnectionCount
        }

        #expect(
            tracked <= bound,
            "the shutdown registry held \(tracked) entries after \(clientCount) clients came and went; dead connections are accumulating instead of being pruned"
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
