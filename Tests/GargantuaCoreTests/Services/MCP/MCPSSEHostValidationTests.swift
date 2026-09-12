import Foundation
import Testing
@testable import GargantuaCore

/// The `Host` check runs before bearer-token authorization and is what keeps a
/// DNS-rebound web page — one the browser has been tricked into treating as
/// same-origin — from reaching the endpoint at all, even to read the 401
/// challenge. Every request here carries the token so only the header under
/// test decides the outcome.
@Suite("MCP SSE Host header validation")
struct MCPSSEHostValidationTests {

    private static let token = "gtua_test_token_12345678901234567890"
    private static let authorization = ["Authorization": "Bearer \(token)"]

    private static let echoHandler: MCPConnectionMessageHandler = { request, _ in
        guard !request.isNotification else { return nil }
        return .success(id: request.id ?? .null, result: .object(["ok": .bool(true)]))
    }

    private func openStream(host: String?) -> MCPSSEOpenStreamResult {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        return router.openStream(
            request: MCPHTTPRequest(
                method: "GET",
                path: "/sse",
                headers: Self.authorization.merging(host.map { ["Host": $0] } ?? [:]) { _, new in new }
            ),
            configuration: MCPSSEServerConfiguration(),
            storedToken: Self.token,
            eventSink: { _, _ in }
        )
    }

    @Test(
        "loopback Host values open the stream",
        arguments: [
            "127.0.0.1",
            "127.0.0.1:7493",
            "localhost",
            "localhost:7493",
            "[::1]",
            "[::1]:7493",
            "LocalHost:7493",
        ]
    )
    func loopbackHostsAccepted(host: String) {
        guard case .opened = openStream(host: host) else {
            Issue.record("expected Host \(host) to be accepted")
            return
        }
    }

    @Test(
        "a foreign Host is rejected with 403",
        arguments: [
            "evil.example",
            "evil.example:7493",
            "127.0.0.1.evil.example",
            "localhost.evil.example",
        ]
    )
    func foreignHostsRejected(host: String) {
        guard case .rejected(let response) = openStream(host: host) else {
            Issue.record("expected Host \(host) to be rejected")
            return
        }
        #expect(response.statusCode == 403)
    }

    @Test("a missing Host header is rejected")
    func missingHostRejected() {
        guard case .rejected(let response) = openStream(host: nil) else {
            Issue.record("expected a missing Host header to be rejected")
            return
        }
        #expect(response.statusCode == 403)
    }

    @Test("a foreign Host is rejected on POST /message too")
    func foreignHostRejectedOnMessagePost() {
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let open = router.openStream(
            request: MCPHTTPRequest(
                method: "GET",
                path: "/sse",
                headers: Self.authorization.merging(["Host": "127.0.0.1:7493"]) { _, new in new }
            ),
            configuration: MCPSSEServerConfiguration(),
            storedToken: Self.token,
            eventSink: { _, _ in }
        )
        guard case .opened(let sessionID, _) = open else {
            Issue.record("expected stream to open")
            return
        }

        let response = router.handleRequest(
            MCPHTTPRequest(
                method: "POST",
                path: "/message",
                query: ["sessionId": sessionID],
                headers: Self.authorization.merging(["Host": "evil.example"]) { _, new in new },
                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
            ),
            configuration: MCPSSEServerConfiguration(),
            storedToken: Self.token
        )

        #expect(response.statusCode == 403)
    }

    @Test("a LAN bind is unaffected by hostname — it is reached by name on purpose")
    func lanBindIgnoresHostname() {
        let token = "gtua_test_token_12345678901234567890"
        let router = MCPSSERequestRouter(handler: Self.echoHandler)
        let result = router.openStream(
            request: MCPHTTPRequest(
                method: "GET",
                path: "/sse",
                headers: ["Host": "titan.local:7493", "Authorization": "Bearer \(token)"]
            ),
            configuration: MCPSSEServerConfiguration(isEnabled: true, bindScope: .lan),
            storedToken: token,
            eventSink: { _, _ in }
        )

        guard case .opened = result else {
            Issue.record("expected a token-bearing LAN request to be accepted by hostname")
            return
        }
    }
}
