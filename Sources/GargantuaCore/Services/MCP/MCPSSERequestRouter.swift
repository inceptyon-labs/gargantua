import Foundation

/// Outcome of an `openStream` call on `MCPSSERequestRouter`.
public enum MCPSSEOpenStreamResult: Sendable, Equatable {
    /// Stream opened successfully with the supplied session id and initial response.
    case opened(sessionID: String, response: MCPHTTPResponse)
    /// Stream rejected; the supplied response should be written and the connection closed.
    case rejected(MCPHTTPResponse)
}

/// Routes MCP SSE HTTP requests to either stream creation or per-message dispatch.
public final class MCPSSERequestRouter: @unchecked Sendable {
    /// Callback invoked when an SSE event should be emitted on a session's connection.
    public typealias EventSink = @Sendable (_ event: String, _ data: String) -> Void

    private let handler: MCPMessageHandler
    private let log: MCPTransportLog?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var sessions: [String: EventSink] = [:]

    /// Creates a router with the supplied JSON-RPC handler and optional log sink.
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

    /// Opens a new SSE session if the request authorizes; otherwise returns a rejection response.
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

    /// Removes the supplied session from the routing table.
    public func closeStream(sessionID: String) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        lock.unlock()
    }

    /// Routes a `/message` POST to the matching session's event sink and returns the HTTP response.
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
