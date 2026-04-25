import Foundation
import Network

public struct MCPHTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            normalizedHeaders[key.lowercased()] = value
        }
        self.headers = normalizedHeaders
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct MCPHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    public func serialized() -> Data {
        var output = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        var allHeaders = headers
        let isStreaming = allHeaders["Content-Type"] == "text/event-stream"
        if !isStreaming && allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = isStreaming ? "keep-alive" : "close"
        }
        for key in allHeaders.keys.sorted() {
            guard let value = allHeaders[key] else { continue }
            output += "\(key): \(value)\r\n"
        }
        output += "\r\n"
        var data = Data(output.utf8)
        data.append(body)
        return data
    }

    public static func text(
        _ statusCode: Int,
        _ reasonPhrase: String,
        _ message: String
    ) -> MCPHTTPResponse {
        MCPHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }
}

public enum MCPSSEEvent {
    public static func encode(event: String, data: String) -> String {
        var output = "event: \(event)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            output += "data: \(line)\n"
        }
        output += "\n"
        return output
    }
}

public enum MCPHTTPRequestParser {
    public static let maximumHeaderBytes = 65_536
    public static let maximumBodyBytes = 1_048_576
    public static let maximumBufferedBytes = maximumHeaderBytes + maximumBodyBytes

    public static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        guard data.count <= maximumBufferedBytes else {
            throw MCPHTTPParseError.bodyTooLarge
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes {
                throw MCPHTTPParseError.headerTooLarge
            }
            return nil
        }
        guard separatorRange.lowerBound <= maximumHeaderBytes else {
            throw MCPHTTPParseError.headerTooLarge
        }

        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MCPHTTPParseError.invalidHeaderEncoding
        }

        let lines = headerText.components(separatedBy: "\r\n")
        let (method, target) = try parseRequestLine(lines.first)
        let headers = try parseHeaders(from: lines.dropFirst())

        guard let body = try extractBody(
            from: data,
            bodyStart: separatorRange.upperBound,
            headers: headers
        ) else {
            return nil
        }

        let (path, query) = parseTarget(target)
        return MCPHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func parseRequestLine(_ line: String?) throws -> (method: String, target: String) {
        guard let line else {
            throw MCPHTTPParseError.invalidRequestLine
        }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw MCPHTTPParseError.invalidRequestLine
        }
        return (parts[0], parts[1])
    }

    private static func parseHeaders(from lines: ArraySlice<String>) throws -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw MCPHTTPParseError.invalidHeader
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key.lowercased()] = value
        }
        return headers
    }

    private static func extractBody(
        from data: Data,
        bodyStart: Data.Index,
        headers: [String: String]
    ) throws -> Data? {
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0
        else {
            throw MCPHTTPParseError.invalidHeader
        }
        guard contentLength <= maximumBodyBytes else {
            throw MCPHTTPParseError.bodyTooLarge
        }

        let availableBodyBytes = data.distance(from: bodyStart, to: data.endIndex)
        guard availableBodyBytes >= contentLength else {
            return nil
        }
        return Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])
    }

    private static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        return (path, query)
    }
}

public enum MCPHTTPParseError: Error, LocalizedError, Equatable, Sendable {
    case invalidHeaderEncoding
    case invalidRequestLine
    case invalidHeader
    case headerTooLarge
    case bodyTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidHeaderEncoding:
            return "HTTP request headers were not valid UTF-8."
        case .invalidRequestLine:
            return "HTTP request line was malformed."
        case .invalidHeader:
            return "HTTP request headers were malformed."
        case .headerTooLarge:
            return "HTTP request headers exceeded the MCP SSE limit."
        case .bodyTooLarge:
            return "HTTP request body exceeded the MCP SSE limit."
        }
    }
}

public enum MCPSSEOpenStreamResult: Sendable, Equatable {
    case opened(sessionID: String, response: MCPHTTPResponse)
    case rejected(MCPHTTPResponse)
}

public final class MCPSSERequestRouter: @unchecked Sendable {
    public typealias EventSink = @Sendable (_ event: String, _ data: String) -> Void

    private let handler: MCPMessageHandler
    private let log: MCPTransportLog?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var sessions: [String: EventSink] = [:]

    public init(
        handler: @escaping MCPMessageHandler,
        log: MCPTransportLog? = nil
    ) {
        self.handler = handler
        self.log = log
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
    }

    public func openStream(
        request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?,
        eventSink: @escaping EventSink
    ) -> MCPSSEOpenStreamResult {
        guard request.method == "GET", request.path == "/sse" else {
            return .rejected(.text(404, "Not Found", "Unknown MCP SSE endpoint."))
        }
        guard authorize(request, configuration: configuration, storedToken: storedToken) else {
            return .rejected(Self.unauthorizedResponse())
        }

        let sessionID = UUID().uuidString
        lock.lock()
        sessions[sessionID] = eventSink
        lock.unlock()

        let initialEvents = MCPSSEEvent.encode(
            event: "endpoint",
            data: "/message?sessionId=\(sessionID)"
        )
        let response = MCPHTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Cache-Control": "no-cache, no-transform",
                "Content-Type": "text/event-stream",
                "X-Accel-Buffering": "no",
            ],
            body: Data(initialEvents.utf8)
        )
        return .opened(sessionID: sessionID, response: response)
    }

    public func closeStream(sessionID: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
    }

    public func handleRequest(
        _ request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> MCPHTTPResponse {
        if request.method == "OPTIONS" {
            return .text(403, "Forbidden", "CORS preflight is not allowed.")
        }
        guard request.method == "POST", request.path == "/message" else {
            return .text(404, "Not Found", "Unknown MCP SSE endpoint.")
        }
        guard authorize(request, configuration: configuration, storedToken: storedToken) else {
            return Self.unauthorizedResponse()
        }
        guard let sessionID = request.query["sessionId"] else {
            return .text(400, "Bad Request", "Missing SSE session id.")
        }

        let sink: EventSink? = {
            lock.lock()
            defer { lock.unlock() }
            return sessions[sessionID]
        }()
        guard let sink else {
            return .text(404, "Not Found", "SSE session is not connected.")
        }

        let rpcRequest: MCPRequest
        do {
            rpcRequest = try decoder.decode(MCPRequest.self, from: request.body)
        } catch {
            log?("SSE JSON-RPC decode failed: \(error)")
            return .text(400, "Bad Request", "Invalid JSON-RPC request.")
        }

        if let response = handler(rpcRequest) {
            sink("message", encodedResponseLine(response, fallbackID: rpcRequest.id ?? .null))
        }
        return MCPHTTPResponse(statusCode: 202, reasonPhrase: "Accepted")
    }

    private func authorize(
        _ request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> Bool {
        MCPSSEAuthorization.isAuthorized(
            authorizationHeader: request.header("authorization"),
            configuration: configuration,
            storedToken: storedToken
        )
    }

    private func encodedResponseLine(_ response: MCPResponse, fallbackID: MCPRequestID) -> String {
        if let data = try? encoder.encode(response),
           let line = String(data: data, encoding: .utf8) {
            return line
        }
        let fallback = MCPResponse.failure(
            id: fallbackID,
            code: MCPErrorCode.internalError,
            message: "Response payload failed to encode"
        )
        let data = (try? encoder.encode(fallback)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
    }

    private static func unauthorizedResponse() -> MCPHTTPResponse {
        MCPHTTPResponse(
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "WWW-Authenticate": #"Bearer realm="Gargantua MCP""#,
            ],
            body: Data("Bearer token required.".utf8)
        )
    }
}

public final class MCPSSETransport: @unchecked Sendable {
    public typealias TokenProvider = @Sendable () throws -> String?

    private let configuration: MCPSSEServerConfiguration
    private let tokenProvider: TokenProvider
    private let router: MCPSSERequestRouter
    private let log: MCPTransportLog?
    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(
        configuration: MCPSSEServerConfiguration,
        tokenProvider: @escaping TokenProvider,
        handler: @escaping MCPMessageHandler,
        log: MCPTransportLog? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.gargantua.mcp.sse")
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.router = MCPSSERequestRouter(handler: handler, log: log)
        self.log = log
        self.queue = queue
    }

    public func start() throws {
        try configuration.validate(hasBearerToken: tokenProvider() != nil)
        let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.bindHost),
            port: port
        )

        let listener = try NWListener(using: parameters)
        let bindDescription = "\(configuration.bindHost):\(configuration.port)"
        listener.stateUpdateHandler = { [log] state in
            switch state {
            case .ready:
                log?("SSE transport listening on \(bindDescription)")
            case .failed(let error):
                log?("SSE transport failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(from: connection, buffer: Data())
    }

    private func readRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let error {
                self.log?("SSE connection read failed: \(error)")
                connection.cancel()
                return
            }

            do {
                if let request = try MCPHTTPRequestParser.parse(nextBuffer) {
                    self.handle(request, on: connection)
                    return
                }
            } catch {
                let response = MCPHTTPResponse.text(400, "Bad Request", error.localizedDescription)
                self.write(response, to: connection, closeAfterWrite: true)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.readRequest(from: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: MCPHTTPRequest, on connection: NWConnection) {
        let storedToken = (try? tokenProvider()) ?? nil
        if request.method == "GET", request.path == "/sse" {
            var sessionID: String?
            let sink: MCPSSERequestRouter.EventSink = { [weak connection] event, data in
                let payload = MCPSSEEvent.encode(event: event, data: data)
                connection?.send(
                    content: Data(payload.utf8),
                    completion: .contentProcessed { _ in }
                )
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed(_):
                    if let sessionID {
                        self?.router.closeStream(sessionID: sessionID)
                    }
                default:
                    break
                }
            }

            switch router.openStream(
                request: request,
                configuration: configuration,
                storedToken: storedToken,
                eventSink: sink
            ) {
            case .opened(let openedSessionID, let response):
                sessionID = openedSessionID
                write(response, to: connection, closeAfterWrite: false)
            case .rejected(let response):
                write(response, to: connection, closeAfterWrite: true)
            }
            return
        }

        let response = router.handleRequest(
            request,
            configuration: configuration,
            storedToken: storedToken
        )
        write(response, to: connection, closeAfterWrite: true)
    }

    private func write(
        _ response: MCPHTTPResponse,
        to connection: NWConnection,
        closeAfterWrite: Bool
    ) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { error in
                if let error {
                    self.log?("SSE response write failed: \(error)")
                }
                if closeAfterWrite {
                    connection.cancel()
                }
            }
        )
    }
}
