import Foundation

// Dispatch for the MCP stdio server. Implements the three protocol methods
// (`initialize`, `tools/list`, `tools/call`) on top of the framing layer in
// `MCPStdioTransport`. Tool implementations register by name; the dispatcher
// owns the routing and the JSON-RPC error mapping, tools own the work.

/// Errors a tool handler can raise to produce specific JSON-RPC error codes.
///
/// Use `invalidParams` for client-side mistakes (malformed arguments) and
/// `internalError` for server-side misconfiguration. Tool-domain failures
/// (e.g. "file not found") should be returned as
/// `MCPToolCallResult.failure(...)` so the error surfaces in the result
/// payload rather than as a JSON-RPC error, per MCP spec.
public enum MCPToolError: Error, Equatable {
    case invalidParams(String)
    case internalError(String)
}

/// Content block in a `tools/call` result. MCP supports text, image, and
/// resource content; Phase 2 only emits text (structured tool payloads ride
/// along in `MCPToolCallResult.structuredContent`).
public enum MCPToolContent: Sendable, Equatable {
    case text(String)
}

extension MCPToolContent: Encodable {
    private enum CodingKeys: String, CodingKey { case type, text }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .type)
            try c.encode(value, forKey: .text)
        }
    }
}

/// MCP `CallToolResult`. `content` is required (at least one block) so the
/// client always has a human-readable string to display; `structuredContent`
/// carries the tool's typed JSON payload; `isError` is `true` when the tool
/// failed for reasons the client should surface as a tool-domain error (not
/// a transport-level JSON-RPC error).
public struct MCPToolCallResult: Sendable, Equatable {
    public let content: [MCPToolContent]
    public let structuredContent: MCPJSONAny?
    public let isError: Bool

    public init(
        content: [MCPToolContent],
        structuredContent: MCPJSONAny? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    /// Success with a single text block. Use this when the tool's output is
    /// already a human-facing string.
    public static func text(_ text: String) -> MCPToolCallResult {
        .init(content: [.text(text)], structuredContent: nil, isError: false)
    }

    /// Success with a structured payload plus a short text summary. Clients
    /// that don't inspect `structuredContent` still get something readable
    /// in `content`.
    public static func structured(
        _ payload: MCPJSONAny,
        summary: String
    ) -> MCPToolCallResult {
        .init(content: [.text(summary)], structuredContent: payload, isError: false)
    }

    /// Tool-domain failure: reported to the client via `isError: true`, not
    /// as a JSON-RPC error. Use for "operation failed" cases where the
    /// protocol call itself was well-formed.
    public static func failure(_ message: String) -> MCPToolCallResult {
        .init(content: [.text(message)], structuredContent: nil, isError: true)
    }
}

extension MCPToolCallResult: Encodable {
    private enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        if let structuredContent {
            try c.encode(structuredContent, forKey: .structuredContent)
        }
        // Emit `isError` only when true so success responses stay compact
        // and match the shape MCP clients expect by default.
        if isError {
            try c.encode(true, forKey: .isError)
        }
    }
}

/// Validated `tools/call` arguments. MCP requires `arguments` to be an
/// object when present; `raw` is an empty dictionary if the client omitted
/// the field entirely.
public struct MCPToolArguments: Sendable, Equatable {
    public let raw: [String: MCPJSONAny]

    public init(_ raw: [String: MCPJSONAny] = [:]) { self.raw = raw }

    public var isEmpty: Bool { raw.isEmpty }

    /// Decodes the arguments into a typed `Decodable` struct. Maps decode
    /// failures to `MCPToolError.invalidParams` so the dispatcher reports
    /// them as JSON-RPC `-32602`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(MCPJSONAny.object(raw))
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MCPToolError.invalidParams("Invalid arguments: \(describe(error))")
        }
    }
}

/// Synchronous tool handler. Given the validated `arguments` payload, return
/// an `MCPToolCallResult`.
///
/// Handlers should throw `MCPToolError.invalidParams(...)` for client-side
/// mistakes (bad arguments) and return `.failure(...)` for tool-domain
/// failures. Any other thrown error is reported to the client as a generic
/// internal error without leaking the error's text.
public typealias MCPToolHandler = @Sendable (MCPToolArguments) throws -> MCPToolCallResult

/// Server identity returned in the `initialize` handshake.
public struct MCPServerInfo: Sendable, Codable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Optional diagnostic log sink for dispatcher-side events (unexpected
/// handler errors, etc.). stderr-bound in production; swallowed in tests.
public typealias MCPDispatcherLog = @Sendable (String) -> Void

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
    private let lock = NSLock()
    private var handlers: [MCPToolName: MCPToolHandler] = [:]

    public init(
        serverInfo: MCPServerInfo,
        protocolVersion: String = MCPRequestDispatcher.defaultProtocolVersion,
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all,
        log: MCPDispatcherLog? = nil
    ) {
        self.serverInfo = serverInfo
        self.protocolVersion = protocolVersion
        self.tools = tools
        self.log = log
    }

    /// Registers (or replaces) a handler for a tool. Safe to call from any
    /// thread; the lock serialises against in-flight `dispatch(_:)` calls.
    public func register(tool name: MCPToolName, handler: @escaping MCPToolHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = handler
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
        do {
            _ = try decodeFromJSONAny(InitializeParams.self, from: params)
        } catch {
            throw MCPDispatchError.invalidParams(
                "initialize params malformed: \(describe(error))"
            )
        }
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
        let toolResult: MCPToolCallResult
        do {
            toolResult = try handler(arguments)
        } catch MCPToolError.invalidParams(let message) {
            // Handler explicitly signalled a client-side error.
            throw MCPDispatchError.invalidParams(message)
        } catch MCPToolError.internalError(let message) {
            // Handler explicitly signalled a server-side error it chose to
            // expose. The message is considered sanitised by the handler.
            throw MCPDispatchError.internalError(message)
        } catch {
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
/// `capabilities` and `clientInfo` are accepted as-is and ignored for now.
private struct InitializeParams: Decodable {
    let protocolVersion: String
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
        case .invalidParams(let m):  return "Invalid params: \(m)"
        case .internalError(let m):  return "Internal error: \(m)"
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
fileprivate func describe(_ error: Error) -> String {
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
