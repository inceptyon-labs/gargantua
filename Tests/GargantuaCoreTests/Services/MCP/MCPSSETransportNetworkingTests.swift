import Foundation
import Testing
@testable import GargantuaCore

@Suite("MCP SSE transport networking")
struct MCPSSETransportNetworkingTests {
    private final class MemoryTokenStore: MCPBearerTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?

        func save(_ token: String) throws {
            lock.lock()
            self.token = MCPBearerTokenValidator.normalized(token)
            lock.unlock()
        }

        func read() throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            return token
        }

        func delete() throws {
            lock.lock()
            token = nil
            lock.unlock()
        }

        func hasToken() throws -> Bool {
            try read() != nil
        }
    }

    private typealias TCPClient = MCPSSETransportTestSupport.TCPClient

    private static let validToken = "gtua_test_token_12345678901234567890"

    @Test("running transport serves SSE endpoint and POST dispatch")
    func runningTransportServesEndpoint() throws {
        let (transport, port) = try MCPSSETransportTestSupport.startTransport { port in
            MCPSSETransport(
                configuration: MCPSSEServerConfiguration(isEnabled: true, port: Int(port)),
                tokenProvider: { nil },
                handler: MCPSSETransportTestSupport.echoHandler
            )
        }
        defer { transport.stop() }

        let sse = try TCPClient(port: Int(port))
        try sse.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let openResponse = try sse.read(until: "\n\n")

        #expect(openResponse.contains("HTTP/1.1 200 OK"))
        #expect(openResponse.contains("event: endpoint"))
        let sessionID = try #require(MCPSSETransportTestSupport.extractSessionID(from: openResponse))

        let body = #"{"jsonrpc":"2.0","id":"socket","method":"ping"}"#
        let post = try TCPClient(port: Int(port))
        try post.write(
            "POST /message?sessionId=\(sessionID) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "\r\n"
                + body
        )
        let postResponse = try post.read(until: "\r\n\r\n")
        #expect(postResponse.contains("HTTP/1.1 202 Accepted"))

        let eventResponse = try sse.read(until: "\n\n")
        #expect(eventResponse.contains("event: message"))
        #expect(eventResponse.contains(#""id":"socket""#))
        #expect(eventResponse.contains(#""ok":true"#))
    }

    @Test("running LAN transport enforces bearer token at endpoint")
    func runningLANTransportEnforcesToken() throws {
        let (transport, port) = try MCPSSETransportTestSupport.startTransport { port in
            MCPSSETransport(
                configuration: MCPSSEServerConfiguration(
                    isEnabled: true,
                    port: Int(port),
                    bindScope: .lan
                ),
                tokenProvider: { Self.validToken },
                handler: MCPSSETransportTestSupport.echoHandler
            )
        }
        defer { transport.stop() }

        let denied = try TCPClient(port: Int(port))
        try denied.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let deniedResponse = try denied.read(until: "\r\n\r\n")
        #expect(deniedResponse.contains("HTTP/1.1 401 Unauthorized"))
        #expect(deniedResponse.contains("WWW-Authenticate: Bearer"))

        let allowed = try TCPClient(port: Int(port))
        try allowed.write(
            "GET /sse HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Authorization: Bearer \(Self.validToken)\r\n"
                + "\r\n"
        )
        let allowedResponse = try allowed.read(until: "\n\n")
        #expect(allowedResponse.contains("HTTP/1.1 200 OK"))
        #expect(allowedResponse.contains("event: endpoint"))
    }

    @Test("token manager creates once and rotates on demand")
    func tokenManagerCreatesAndRotates() throws {
        final class Generator: @unchecked Sendable {
            var counter = 0
            func next() -> String {
                counter += 1
                return "gtua_generated_token_1234567890_\(counter)"
            }
        }
        let generator = Generator()
        let manager = MCPBearerTokenManager(
            store: MemoryTokenStore(),
            generator: { generator.next() }
        )

        let first = try manager.ensureToken()
        let second = try manager.ensureToken()
        let rotated = try manager.rotateToken()

        #expect(first == second)
        #expect(rotated != first)
    }
}
