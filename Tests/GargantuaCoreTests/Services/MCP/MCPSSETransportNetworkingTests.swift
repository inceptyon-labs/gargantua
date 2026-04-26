import Foundation
import Darwin
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
                            return String(bytes: data, encoding: .utf8) ?? ""
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

            throw TestSocketError.timedOut(String(bytes: data, encoding: .utf8) ?? "")
        }
    }

    private enum TestSocketError: Error {
        case writeFailed
        case readFailed
        case timedOut(String)
        case noFreePort
    }

    private static let validToken = "gtua_test_token_12345678901234567890"

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
