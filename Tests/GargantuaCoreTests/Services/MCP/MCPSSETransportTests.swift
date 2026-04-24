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

    private final class TCPClient {
        private let input: InputStream
        private let output: OutputStream

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
            input.close()
            output.close()
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
                    throw TestSocketError.writeFailed
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
                            return String(decoding: data, as: UTF8.self)
                        }
                    } else if count < 0 {
                        throw TestSocketError.readFailed
                    }
                } else {
                    RunLoop.current.run(
                        mode: .default,
                        before: Date().addingTimeInterval(0.01)
                    )
                }
            }

            throw TestSocketError.timedOut(String(decoding: data, as: UTF8.self))
        }
    }

    private enum TestSocketError: Error {
        case writeFailed
        case readFailed
        case timedOut(String)
        case noFreePort
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

        let body = String(decoding: response.body, as: UTF8.self)
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

    @Test("running transport serves SSE endpoint and POST dispatch")
    func runningTransportServesEndpoint() throws {
        let port = try findFreePort()
        let transport = MCPSSETransport(
            configuration: MCPSSEServerConfiguration(isEnabled: true, port: port),
            tokenProvider: { nil },
            handler: Self.echoHandler
        )
        try transport.start()
        defer { transport.stop() }
        usleep(150_000)

        let sse = try TCPClient(port: port)
        try sse.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let openResponse = try sse.read(until: "\n\n")

        #expect(openResponse.contains("HTTP/1.1 200 OK"))
        #expect(openResponse.contains("event: endpoint"))
        let sessionID = try #require(extractSessionID(from: openResponse))

        let body = #"{"jsonrpc":"2.0","id":"socket","method":"ping"}"#
        let post = try TCPClient(port: port)
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
        let port = try findFreePort()
        let transport = MCPSSETransport(
            configuration: MCPSSEServerConfiguration(
                isEnabled: true,
                port: port,
                bindScope: .lan
            ),
            tokenProvider: { Self.validToken },
            handler: Self.echoHandler
        )
        try transport.start()
        defer { transport.stop() }
        usleep(150_000)

        let denied = try TCPClient(port: port)
        try denied.write("GET /sse HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let deniedResponse = try denied.read(until: "\r\n\r\n")
        #expect(deniedResponse.contains("HTTP/1.1 401 Unauthorized"))
        #expect(deniedResponse.contains("WWW-Authenticate: Bearer"))

        let allowed = try TCPClient(port: port)
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

    private func findFreePort() throws -> Int {
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
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func extractSessionID(from response: String) -> String? {
        guard let range = response.range(of: "sessionId=") else { return nil }
        let suffix = response[range.upperBound...]
        let id = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return id.isEmpty ? nil : String(id)
    }
}
