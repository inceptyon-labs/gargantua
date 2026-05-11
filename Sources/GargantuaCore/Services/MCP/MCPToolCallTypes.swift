import Foundation

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
            throw MCPToolError.invalidParams("Invalid arguments: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
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
}

/// Synchronous tool handler. Given the validated `arguments` payload, return
/// an `MCPToolCallResult`.
///
/// Handlers should throw `MCPToolError.invalidParams(...)` for client-side
/// mistakes (bad arguments) and return `.failure(...)` for tool-domain
/// failures. Any other thrown error is reported to the client as a generic
/// internal error without leaking the error's text.
public typealias MCPToolHandler = @Sendable (MCPToolArguments) throws -> MCPToolCallResult
