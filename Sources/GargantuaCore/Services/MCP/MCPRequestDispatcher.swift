import Foundation

// Dispatch for the MCP stdio server. Implements the three protocol methods
// (`initialize`, `tools/list`, `tools/call`) on top of the framing layer in
// `MCPStdioTransport`. Tool implementations register by name; the dispatcher
// owns the routing and the JSON-RPC error mapping, tools own the work.

/// Synchronous tool handler. Given the raw `arguments` payload from a
/// `tools/call`, return the JSON value to embed in the response `result`.
///
/// Handlers that need to signal a client-side error should throw
/// `MCPToolError.invalidParams(...)`; unexpected failures should throw
/// `MCPToolError.internalError(...)`. Anything else is wrapped as an
/// internal error by the dispatcher.
public typealias MCPToolHandler = @Sendable (MCPJSONAny?) throws -> MCPJSONAny

/// Errors a tool handler can raise to produce specific JSON-RPC error codes.
public enum MCPToolError: Error, Equatable {
    case invalidParams(String)
    case internalError(String)
}

/// Server identity returned in the `initialize` handshake.
public struct MCPServerInfo: Sendable, Codable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

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
    private let lock = NSLock()
    private var handlers: [MCPToolName: MCPToolHandler] = [:]

    public init(
        serverInfo: MCPServerInfo,
        protocolVersion: String = MCPRequestDispatcher.defaultProtocolVersion,
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all
    ) {
        self.serverInfo = serverInfo
        self.protocolVersion = protocolVersion
        self.tools = tools
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
            return .failure(
                id: requestID,
                code: MCPErrorCode.internalError,
                message: "Internal error: \(error)"
            )
        }
    }

    // MARK: - Method routing

    private func handle(method: String, params: MCPJSONAny?) throws -> MCPJSONAny {
        switch method {
        case "initialize":
            return handleInitialize()
        case "tools/list":
            return try handleToolsList()
        case "tools/call":
            return try handleToolsCall(params: params)
        default:
            throw MCPDispatchError.methodNotFound(method)
        }
    }

    private func handleInitialize() -> MCPJSONAny {
        // MCP spec §initialize: return protocolVersion, capabilities,
        // serverInfo. We advertise `tools` with no extra flags (we do not
        // support dynamic list-changed notifications).
        .object([
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
        do {
            return try handler(call.arguments)
        } catch MCPToolError.invalidParams(let message) {
            throw MCPDispatchError.invalidParams(message)
        } catch MCPToolError.internalError(let message) {
            throw MCPDispatchError.internalError(message)
        } catch {
            throw MCPDispatchError.internalError(
                "Tool \(toolName.rawValue) failed: \(describe(error))"
            )
        }
    }
}

// MARK: - Internal wire shapes

/// `tools/call` params per MCP spec: `{ name: string, arguments?: any }`.
private struct ToolCallParams: Decodable {
    let name: String
    let arguments: MCPJSONAny?

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        // Preserve explicit-null arguments so handlers can distinguish
        // `{}` (no args) from `{"arguments": null}` (explicit null) if they
        // care; same rationale as MCPRequest.params.
        if c.contains(.arguments) {
            self.arguments = try c.decode(MCPJSONAny.self, forKey: .arguments)
        } else {
            self.arguments = nil
        }
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
