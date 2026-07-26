import Foundation
import Darwin
import Testing
@testable import GargantuaCore

@Suite("MCP SSE transport")
struct MCPSSETransportTests {
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(event: String, data: String)] = []

        func append(event: String, data: String) {
            lock.lock()
            stored.append((event, data))
            lock.unlock()
        }

        func events() -> [(event: String, data: String)] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private static let validToken = "gtua_test_token_12345678901234567890"

    @Test("default SSE configuration is localhost on port 7493")
    func defaultConfiguration() {
        let configuration = MCPSSEServerConfiguration()

        #expect(configuration.isEnabled == false)
        #expect(configuration.port == 7_493)
        #expect(configuration.bindScope == .localhost)
        #expect(configuration.bindHost == "127.0.0.1")
        #expect(configuration.requiresBearerToken == false)
    }

    @Test("configuration store normalizes out-of-range ports")
    func configurationStoreNormalizesPort() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MCPSSEConfigurationStore(defaults: defaults)

        store.save(MCPSSEServerConfiguration(isEnabled: true, port: 99_999, bindScope: .lan))
        let loaded = store.load()

        #expect(loaded.isEnabled)
        #expect(loaded.port == 65_535)
        #expect(loaded.bindScope == .lan)
    }

    @Test("LAN authorization requires the configured bearer token")
    func lanAuthorizationRequiresBearerToken() {
        let configuration = MCPSSEServerConfiguration(isEnabled: true, bindScope: .lan)

        #expect(!MCPSSEAuthorization.isAuthorized(
            authorizationHeader: nil,
            configuration: configuration,
            storedToken: Self.validToken
        ))
        #expect(!MCPSSEAuthorization.isAuthorized(
            authorizationHeader: "Bearer wrong-token",
            configuration: configuration,
            storedToken: Self.validToken
        ))
        #expect(MCPSSEAuthorization.isAuthorized(
            authorizationHeader: "Bearer \(Self.validToken)",
            configuration: configuration,
            storedToken: Self.validToken
        ))
    }

    @Test("localhost SSE stream opens without token and does not emit CORS headers")
    func localhostStreamOpensWithoutToken() throws {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let recorder = EventRecorder()
        let request = MCPHTTPRequest(method: "GET", path: "/sse", headers: ["Host": "127.0.0.1:7493"])

        let result = router.openStream(
            request: request,
            configuration: MCPSSEServerConfiguration(),
            storedToken: nil,
            eventSink: { recorder.append(event: $0, data: $1) }
        )

        guard case .opened(let sessionID, let response) = result else {
            Issue.record("expected stream to open")
            return
        }
        #expect(!sessionID.isEmpty)
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "text/event-stream")
        #expect(response.headers["Access-Control-Allow-Origin"] == nil)

        let body = String(bytes: response.body, encoding: .utf8) ?? ""
        #expect(body.contains("event: endpoint"))
        #expect(body.contains("/message?sessionId=\(sessionID)"))
        #expect(recorder.events().isEmpty)
    }

    @Test("CORS preflight is forbidden by default")
    func corsPreflightForbidden() {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let response = router.handleRequest(
            MCPHTTPRequest(method: "OPTIONS", path: "/message"),
            configuration: MCPSSEServerConfiguration(),
            storedToken: nil
        )

        #expect(response.statusCode == 403)
        #expect(response.headers["Access-Control-Allow-Origin"] == nil)
    }

    @Test("LAN stream rejects missing token with bearer challenge")
    func lanStreamRejectsMissingToken() throws {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let result = router.openStream(
            request: MCPHTTPRequest(method: "GET", path: "/sse"),
            configuration: MCPSSEServerConfiguration(isEnabled: true, bindScope: .lan),
            storedToken: Self.validToken,
            eventSink: { _, _ in }
        )

        guard case .rejected(let response) = result else {
            Issue.record("expected missing bearer token to reject")
            return
        }
        #expect(response.statusCode == 401)
        #expect(response.headers["WWW-Authenticate"]?.contains("Bearer") == true)
    }

    @Test("HTTP parser tolerates duplicate normalized header and query keys")
    func parserToleratesDuplicateKeys() throws {
        let raw = "POST /message?sessionId=old&sessionId=new HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Authorization: Bearer first\r\n"
            + "authorization: Bearer second\r\n"
            + "Content-Length: 2\r\n"
            + "\r\n"
            + "{}"
        let request = try #require(try MCPHTTPRequestParser.parse(Data(raw.utf8)))

        #expect(request.query["sessionId"] == "new")
        #expect(request.header("authorization") == "Bearer second")
        #expect(request.body == Data("{}".utf8))
    }

    @Test("HTTP parser rejects negative content length")
    func parserRejectsNegativeContentLength() throws {
        let raw = "POST /message HTTP/1.1\r\n"
            + "Content-Length: -1\r\n"
            + "\r\n"

        #expect(throws: MCPHTTPParseError.invalidHeader) {
            _ = try MCPHTTPRequestParser.parse(Data(raw.utf8))
        }
    }

    @Test("message POST dispatches JSON-RPC response over the SSE stream")
    func postDispatchesResponseOverSSE() throws {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let recorder = EventRecorder()
        let open = router.openStream(
            request: MCPHTTPRequest(method: "GET", path: "/sse", headers: ["Host": "127.0.0.1:7493"]),
            configuration: MCPSSEServerConfiguration(),
            storedToken: nil,
            eventSink: { recorder.append(event: $0, data: $1) }
        )
        guard case .opened(let sessionID, _) = open else {
            Issue.record("expected stream to open")
            return
        }

        let requestBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)
        let response = router.handleRequest(
            MCPHTTPRequest(
                method: "POST",
                path: "/message",
                query: ["sessionId": sessionID],
                headers: ["Host": "127.0.0.1:7493"],
                body: requestBody
            ),
            configuration: MCPSSEServerConfiguration(),
            storedToken: nil
        )

        #expect(response.statusCode == 202)
        let events = recorder.events()
        #expect(events.count == 1)
        #expect(events[0].event == "message")

        let rpcResponse = try JSONDecoder().decode(
            MCPResponse.self,
            from: Data(events[0].data.utf8)
        )
        #expect(rpcResponse.id == .int(7))
        #expect(rpcResponse.result == .object(["ok": .bool(true)]))
    }

    private static let echoHandler: MCPConnectionMessageHandler = { request, _ in
        guard !request.isNotification else { return nil }
        return .success(
            id: request.id ?? .null,
            result: .object(["ok": .bool(true)])
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "GargantuaCoreTests.MCPSSETransport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    // MARK: - Session id synchronization regression

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

        func count() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return closedRawValues.count
        }
    }

    /// Regression test for a data race in `MCPSSETransport.handle(_:on:)`:
    /// the per-connection SSE session id used to be stored in a bare
    /// `var sessionID: String?`, written from the request-handling closure
    /// and read from `NWConnection`'s `stateUpdateHandler` closure with no
    /// synchronization between the two — a pattern the Swift 6 language
    /// mode rejects outright, since it cannot prove the two closures never
    /// run concurrently. The fix stores the session id in an
    /// `OSAllocatedUnfairLock` box instead.
    ///
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
        let port = try Self.findFreePort()
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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError.noFreePort }

        var address = Self.loopbackAddress(port: port)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw TestSocketError.noFreePort
        }

        let request = "GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }

        var buffer = [UInt8](repeating: 0, count: 4_096)
        let readCount = recv(fd, &buffer, buffer.count, 0)
        close(fd)

        guard readCount > 0 else { return nil }
        let responseText = String(bytes: buffer[0 ..< readCount], encoding: .utf8) ?? ""
        return extractSessionID(from: responseText)
    }

    /// Sends a JSON-RPC `ping` to `/message?sessionId=` over a fresh
    /// connection and reads the response.
    private static func postMessage(port: UInt16, sessionID: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError.noFreePort }
        defer { close(fd) }

        var address = Self.loopbackAddress(port: port)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw TestSocketError.noFreePort }

        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let request = "POST /message?sessionId=\(sessionID) HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        _ = recv(fd, &buffer, buffer.count, 0)
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func extractSessionID(from response: String) -> String? {
        guard let range = response.range(of: "sessionId=") else { return nil }
        let suffix = response[range.upperBound...]
        let id = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return id.isEmpty ? nil : String(id)
    }

    private static func findFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError.noFreePort }
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
        guard bindResult == 0 else { throw TestSocketError.noFreePort }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw TestSocketError.noFreePort }
        return UInt16(bigEndian: address.sin_port)
    }

    private enum TestSocketError: Error {
        case noFreePort
    }
}
