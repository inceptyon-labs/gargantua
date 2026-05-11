import Foundation

// Dispatch for the MCP stdio server. Implements the three protocol methods
// (`initialize`, `tools/list`, `tools/call`) on top of the framing layer in
// `MCPStdioTransport`. Tool implementations register by name; the dispatcher
// owns the routing and the JSON-RPC error mapping, tools own the work.

/// Routes decoded `MCPRequest`s to built-in MCP methods and registered tools.
///
/// The dispatcher is safe to share across threads: the handler map is guarded
/// by a lock so follow-up Tasks can register handlers at startup without
/// coordinating with the transport loop.
public final class MCPRequestDispatcher: @unchecked Sendable {

    // Default MCP protocol version this server advertises. Matches the MCP
    // spec revision current at the time of writing; the exact string is what
    // clients key handshake compatibility on.
    public static let defaultProtocolVersion = "2024-11-05"

    private let serverInfo: MCPServerInfo
    private let protocolVersion: String
    private let tools: [MCPToolDescriptor]
    private let log: MCPDispatcherLog?
    private let statusReporter: MCPServerStatusReporting?
    private let lock = NSLock()
    private var handlers: [MCPToolName: MCPToolHandler] = [:]
    private var capturedClientIdentity: MCPClientIdentity?

    public init(
        serverInfo: MCPServerInfo,
        protocolVersion: String = MCPRequestDispatcher.defaultProtocolVersion,
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all,
        log: MCPDispatcherLog? = nil,
        statusReporter: MCPServerStatusReporting? = nil
    ) {
        self.serverInfo = serverInfo
        self.protocolVersion = protocolVersion
        self.tools = tools
        self.log = log
        self.statusReporter = statusReporter
    }

    /// Registers (or replaces) a handler for a tool. Safe to call from any
    /// thread; the lock serialises against in-flight `dispatch(_:)` calls.
    public func register(tool name: MCPToolName, handler: @escaping MCPToolHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = handler
    }

    /// Client identity captured from the most recent `initialize` handshake,
    /// or nil if the client has not completed `initialize` yet. Stdio
    /// transport is single-session, so this is "the client" for the
    /// process's lifetime. Intended for destructive-tool handlers that need
    /// to stamp audit entries / shard rate limits.
    public func currentClientIdentity() -> MCPClientIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return capturedClientIdentity
    }

    /// Normalize a caller-supplied client name. Trims whitespace; returns
    /// `nil` for empty/whitespace-only values so they don't masquerade as
    /// their own rate-limit shard in audit attribution.
    private static func normalizedClientName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Main entry point, designed to be passed as an `MCPMessageHandler` to
    /// `MCPStdioTransport`. Returns `nil` for notifications so the transport
    /// suppresses output, and always returns a response for requests.
    public func dispatch(_ request: MCPRequest) -> MCPResponse? {
        if request.isNotification {
            // MCP has notifications like `notifications/initialized` that
            // carry no response. We accept them silently; future side-effect
            // hooks can be added here without changing the transport.
            return nil
        }
        // id is non-nil here because isNotification guards it.
        guard let requestID = request.id else { return nil }

        do {
            let result = try handle(method: request.method, params: request.params)
            return .success(id: requestID, result: result)
        } catch let err as MCPDispatchError {
            return .failure(id: requestID, code: err.code, message: err.message)
        } catch {
            // Defensive: any throw path we do not explicitly cover becomes a
            // generic internal error. The error's detail is logged to stderr
            // rather than leaked to the client.
            log?("dispatcher caught unexpected error: \(error)")
            return .failure(
                id: requestID,
                code: MCPErrorCode.internalError,
                message: "Internal error"
            )
        }
    }

    // MARK: - Method routing

    private func handle(method: String, params: MCPJSONAny?) throws -> MCPJSONAny {
        switch method {
        case "initialize":
            return try handleInitialize(params: params)
        case "tools/list":
            return try handleToolsList()
        case "tools/call":
            return try handleToolsCall(params: params)
        default:
            throw MCPDispatchError.methodNotFound(method)
        }
    }

    private func handleInitialize(params: MCPJSONAny?) throws -> MCPJSONAny {
        guard let params else {
            throw MCPDispatchError.invalidParams(
                "initialize requires params with protocolVersion"
            )
        }
        // MCP `InitializeRequest` requires `protocolVersion`; `capabilities`
        // and `clientInfo` are also mandatory in the spec but we accept them
        // loosely so Phase 2 stays compatible with minimal clients. Strict
        // version negotiation is deferred to a follow-up.
        let parsed: InitializeParams
        do {
            parsed = try decodeFromJSONAny(InitializeParams.self, from: params)
        } catch {
            throw MCPDispatchError.invalidParams(
                "initialize params malformed: \(describe(error))"
            )
        }
        // Capture client identity for downstream destructive tools (audit,
        // rate limit). Every `initialize` call resets the captured identity
        // first — a re-initialize that omits `clientInfo` (or sends it
        // malformed) MUST clear the prior client rather than keep a stale
        // attribution. Missing/malformed `clientInfo` is tolerated so minimal
        // clients keep working; handlers that query see `nil` and fall back
        // to the `"unknown"` sentinel. Empty or whitespace-only names are
        // normalized to `nil` so an adversarial client can't slip past
        // per-client isolation by sending a blank name.
        let capturedIdentity: MCPClientIdentity?
        lock.lock()
        capturedClientIdentity = nil
        if let client = parsed.clientInfo,
           let normalizedName = Self.normalizedClientName(client.name) {
            capturedClientIdentity = MCPClientIdentity(
                name: normalizedName,
                version: client.version
            )
        }
        capturedIdentity = capturedClientIdentity
        lock.unlock()
        statusReporter?.replaceCurrentClient(capturedIdentity)
        // We advertise the `tools` capability with no extra flags; we do not
        // emit list-changed notifications yet.
        return .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string(serverInfo.name),
                "version": .string(serverInfo.version),
            ]),
        ])
    }

    private func handleToolsList() throws -> MCPJSONAny {
        // The `tools` array shape matches MCP §tools/list: { name, description,
        // inputSchema }. Encode through JSONEncoder so the schema values land
        // on the wire with the same key order/structure as the descriptor
        // types define.
        let entries = tools.map(ToolListEntry.init)
        let encoded = try encodeAsJSONAny(entries)
        return .object(["tools": encoded])
    }

    private func handleToolsCall(params: MCPJSONAny?) throws -> MCPJSONAny {
        guard let params else {
            throw MCPDispatchError.invalidParams("tools/call requires a params object")
        }
        let call: ToolCallParams
        do {
            call = try decodeFromJSONAny(ToolCallParams.self, from: params)
        } catch {
            throw MCPDispatchError.invalidParams(
                "tools/call params malformed: \(describe(error))"
            )
        }
        guard let toolName = MCPToolName(rawValue: call.name) else {
            throw MCPDispatchError.invalidParams("Unknown tool: \(call.name)")
        }
        // Per MCP spec, `arguments` is optional but MUST be an object when
        // present. Reject other shapes with -32602 so we don't route
        // malformed payloads into handlers.
        let arguments: MCPToolArguments
        switch call.arguments {
        case nil:
            arguments = MCPToolArguments()
        case .object(let dict)?:
            arguments = MCPToolArguments(dict)
        default:
            throw MCPDispatchError.invalidParams(
                "tools/call arguments must be an object when present"
            )
        }
        let handler: MCPToolHandler? = {
            lock.lock()
            defer { lock.unlock() }
            return handlers[toolName]
        }()
        guard let handler else {
            throw MCPDispatchError.internalError(
                "Tool not implemented: \(toolName.rawValue)"
            )
        }
        let currentClient = currentClientIdentity()
        let toolResult: MCPToolCallResult
        do {
            toolResult = try handler(arguments)
            statusReporter?.recordToolCall(toolName, client: currentClient)
        } catch MCPToolError.invalidParams(let message) {
            statusReporter?.recordToolCall(toolName, client: currentClient)
            // Handler explicitly signalled a client-side error.
            throw MCPDispatchError.invalidParams(message)
        } catch MCPToolError.internalError(let message) {
            statusReporter?.recordToolCall(toolName, client: currentClient)
            // Handler explicitly signalled a server-side error it chose to
            // expose. The message is considered sanitised by the handler.
            throw MCPDispatchError.internalError(message)
        } catch {
            statusReporter?.recordToolCall(toolName, client: currentClient)
            // Unexpected exception: do not leak the error's textual
            // description to the client (may contain paths, sensitive state).
            // Log details to stderr and return a generic internal error.
            log?("tool \(toolName.rawValue) threw unexpected error: \(error)")
            throw MCPDispatchError.internalError("Tool execution failed")
        }
        return try encodeAsJSONAny(toolResult)
    }
}

// MARK: - Internal wire shapes

/// `tools/call` params per MCP spec: `{ name: string, arguments?: object }`.
private struct ToolCallParams: Decodable {
    let name: String
    let arguments: MCPJSONAny?

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        // Preserve whatever shape the client sent so the dispatcher can
        // validate it (object vs. null vs. array vs. scalar) and produce a
        // precise error. Don't reject at this level — it would lose the
        // distinction between "absent" and "explicit null" before the
        // dispatcher sees it.
        if c.contains(.arguments) {
            self.arguments = try c.decode(MCPJSONAny.self, forKey: .arguments)
        } else {
            self.arguments = nil
        }
    }
}

/// Minimal `initialize` params: only `protocolVersion` is decoded strictly.
/// `capabilities` is accepted as-is and ignored; `clientInfo` is decoded
/// defensively — a missing or malformed block is tolerated so minimal
/// clients keep working, but a well-formed block's `name`/`version` is
/// captured into `capturedClientIdentity`.
private struct InitializeParams: Decodable {
    let protocolVersion: String
    let clientInfo: ClientInfoParam?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, clientInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try c.decode(String.self, forKey: .protocolVersion)
        // Tolerate missing-name or wrong-shaped clientInfo: we want to log
        // an identity when the client provides one, but not fail the
        // handshake for a client that's out of spec on this field.
        self.clientInfo = try? c.decodeIfPresent(ClientInfoParam.self, forKey: .clientInfo)
    }

    struct ClientInfoParam: Decodable {
        let name: String
        let version: String?
    }
}

/// Shape written into the `tools/list` response. Mirrors MCP §tools/list
/// exactly; uses `MCPJSONSchema` directly so the schema types are the single
/// source of truth.
private struct ToolListEntry: Encodable {
    let name: String
    let description: String
    let inputSchema: MCPJSONSchema

    init(_ descriptor: MCPToolDescriptor) {
        self.name = descriptor.name.rawValue
        self.description = descriptor.description
        self.inputSchema = descriptor.inputSchema
    }
}

// MARK: - Dispatch errors

/// Internal error type that carries the JSON-RPC code to use.
private enum MCPDispatchError: Error {
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)

    var code: Int {
        switch self {
        case .methodNotFound: return MCPErrorCode.methodNotFound
        case .invalidParams: return MCPErrorCode.invalidParams
        case .internalError: return MCPErrorCode.internalError
        }
    }

    var message: String {
        switch self {
        case .methodNotFound(let m): return "Method not found: \(m)"
        case .invalidParams(let m): return "Invalid params: \(m)"
        case .internalError(let m): return "Internal error: \(m)"
        }
    }
}

// MARK: - Codable ↔ MCPJSONAny bridges

/// Re-encodes any `Encodable` through `MCPJSONAny` so dispatcher results can
/// be stitched into the `MCPResponse.result` value. Using JSONEncoder keeps
/// the on-wire shape identical to the source type's Codable contract.
private func encodeAsJSONAny<T: Encodable>(_ value: T) throws -> MCPJSONAny {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(MCPJSONAny.self, from: data)
}

/// Inverse of `encodeAsJSONAny`. Lets the dispatcher decode strongly-typed
/// params out of the untyped `MCPJSONAny` payload.
private func decodeFromJSONAny<T: Decodable>(_ type: T.Type, from any: MCPJSONAny) throws -> T {
    let data = try JSONEncoder().encode(any)
    return try JSONDecoder().decode(type, from: data)
}

/// Produces a compact one-line description of a decoding error. Avoids the
/// multi-line Swift error descriptions that would muddy JSON-RPC messages.
private func describe(_ error: Error) -> String {
    if let decodeError = error as? DecodingError {
        switch decodeError {
        case .dataCorrupted(let ctx),
             .keyNotFound(_, let ctx),
             .typeMismatch(_, let ctx),
             .valueNotFound(_, let ctx):
            return ctx.debugDescription
        @unknown default:
            return "decoding failed"
        }
    }
    return "\(error)"
}
