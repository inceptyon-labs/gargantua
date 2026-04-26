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
        let request = MCPHTTPRequest(method: "GET", path: "/sse")

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
            request: MCPHTTPRequest(method: "GET", path: "/sse"),
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

    private static let echoHandler: MCPMessageHandler = { request in
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
}
