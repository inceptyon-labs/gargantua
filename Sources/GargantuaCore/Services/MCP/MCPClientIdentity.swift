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

/// Optional diagnostic log sink for dispatcher-side events (unexpected
/// handler errors, etc.). stderr-bound in production; swallowed in tests.
public typealias MCPDispatcherLog = @Sendable (String) -> Void
