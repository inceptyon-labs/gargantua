import Foundation

/// Server identity returned in the `initialize` handshake.
public struct MCPServerInfo: Sendable, Codable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Client identity learned from the MCP `initialize` handshake.
///
/// Populated by the dispatcher once the client sends `initialize`, read by
/// destructive tool handlers (e.g. `MCPCleanToolHandler`) to stamp audit
/// entries and shard per-client rate limits. Tool handlers that see `nil`
/// should fall back to the literal `"unknown"` for their audit/limit key so
/// a misbehaving client cannot slip past per-client isolation by omitting
/// `clientInfo`.
public struct MCPClientIdentity: Sendable, Equatable {
    /// `clientInfo.name` from the handshake. Not guaranteed unique across
    /// clients — two distinct Claude Code processes both identify as
    /// `"claude-code"`, for example — but stable within a single server
    /// lifetime and sufficient for audit attribution.
    public let name: String

    /// `clientInfo.version` from the handshake, if the client advertised
    /// one. Recorded verbatim; not parsed.
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// Identifies the transport connection a request arrived on, so the
/// dispatcher can key captured client identity per connection instead of in a
/// single process-wide slot.
///
/// The stdio transport is single-session for the process lifetime, so it uses
/// the shared `.stdio` key. Each SSE session gets its own key derived from the
/// per-connection session id. In dual-transport (`.both`) mode both run at
/// once; without per-connection keying, a later `initialize` on one transport
/// would overwrite the other's captured identity and mis-attribute the next
/// destructive tool call's audit entry and rate-limit shard.
public struct MCPConnectionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The single stdio session shared by the whole process.
    public static let stdio = MCPConnectionID("stdio")

    /// A distinct SSE session, namespaced by its session id so it can never
    /// collide with `.stdio` or another session.
    public static func sse(_ sessionID: String) -> MCPConnectionID {
        MCPConnectionID("sse:\(sessionID)")
    }

    /// The clean rate-limit bucket for this connection. All SSE sessions
    /// share one: any client can open a new session (a new id) whenever it
    /// likes, so a per-session budget would reset on demand.
    public var rateLimitShard: String {
        rawValue.hasPrefix("sse:") ? "sse" : rawValue
    }
}

/// Optional diagnostic log sink for dispatcher-side events (unexpected
/// handler errors, etc.). stderr-bound in production; swallowed in tests.
public typealias MCPDispatcherLog = @Sendable (String) -> Void
