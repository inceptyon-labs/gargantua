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

    /// Invoked when an SSE session tears down, so callers can evict any
    /// per-connection state keyed by the session's `MCPConnectionID`.
    public typealias ConnectionCloseHandler = @Sendable (_ connection: MCPConnectionID) -> Void

    private let handler: MCPConnectionMessageHandler
    private let log: MCPTransportLog?
    private let onClose: ConnectionCloseHandler?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var sessions: [String: EventSink] = [:]

    /// Creates a router with the supplied JSON-RPC handler and optional log sink.
    public init(
        handler: @escaping MCPConnectionMessageHandler,
        log: MCPTransportLog? = nil,
        onClose: ConnectionCloseHandler? = nil
    ) {
        self.handler = handler
        self.log = log
        self.onClose = onClose
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
        if let rejection = rejection(for: request, configuration: configuration, storedToken: storedToken) {
            return .rejected(rejection)
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
        // Fire eviction outside the router lock so the callback can take the
        // registry/dispatcher locks without nesting under ours. Fired
        // unconditionally (even when the session was already removed, e.g. a
        // double `.cancelled`/`.failed`) so teardown always evicts the
        // connection's per-connection state; the key is `.sse(sessionID)`, so
        // this can only ever drop that one session's own cache/identity.
        onClose?(.sse(sessionID))
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
        if let rejection = rejection(for: request, configuration: configuration, storedToken: storedToken) {
            return rejection
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

        if let response = handler(rpcRequest, .sse(sessionID)) {
            sink("message", encodedResponseLine(response, fallbackID: rpcRequest.id ?? .null))
        }
        return MCPHTTPResponse(statusCode: 202, reasonPhrase: "Accepted")
    }

    /// Returns the response to send when the request must be refused, or `nil`
    /// when it may proceed. Both entry points funnel through here so neither
    /// can be hardened without the other.
    private func rejection(
        for request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> MCPHTTPResponse? {
        guard Self.hasAllowedHost(request, configuration: configuration) else {
            log?("SSE request rejected: Host header is not a loopback literal.")
            return .text(403, "Forbidden", "Host header must be a loopback address.")
        }
        guard MCPSSEAuthorization.isAuthorized(
            authorizationHeader: request.header("authorization"),
            configuration: configuration,
            storedToken: storedToken
        ) else {
            return Self.unauthorizedResponse()
        }
        return nil
    }

    /// DNS-rebinding defense for localhost binds.
    ///
    /// A localhost bind requires no bearer token, and rejecting CORS preflight
    /// is not enough on its own: an attacker who re-points their own hostname's
    /// DNS record at 127.0.0.1 makes the browser treat the request as
    /// *same-origin*, so no preflight happens and the response — including the
    /// `endpoint` event carrying the session id — is fully readable. The one
    /// field that still carries the attacker's name is `Host`, and a genuine
    /// local client always sends a loopback literal there.
    ///
    /// LAN binds are exempt: they are reached by hostname on purpose and are
    /// already bearer-token gated.
    static func hasAllowedHost(
        _ request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration
    ) -> Bool {
        guard configuration.bindScope == .localhost else { return true }
        guard let host = request.header("host")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased(),
            !host.isEmpty
        else { return false }

        // Strip the optional :port, tolerating a bracketed IPv6 literal.
        let hostname: String
        if host.hasPrefix("[") {
            hostname = String(host.dropFirst().prefix { $0 != "]" })
        } else {
            hostname = String(host.prefix { $0 != ":" })
        }
        return ["127.0.0.1", "::1", "localhost"].contains(hostname)
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
