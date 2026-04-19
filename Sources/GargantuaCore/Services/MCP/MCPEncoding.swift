import Foundation

/// Shared helpers for MCP tool handlers that need to materialise a typed
/// output as the untyped `MCPJSONAny` the dispatcher embeds in `tools/call`
/// results.
///
/// All MCP tool payloads go through this helper so date fields land on the
/// wire as ISO-8601 strings (e.g. `"2026-04-11T14:30:00Z"`) rather than the
/// `JSONEncoder` default (numeric seconds since a Foundation reference date),
/// which a generic MCP client wouldn't parse as a timestamp. Even handlers
/// whose current output shape has no `Date` field use this helper so adding a
/// date later doesn't require remembering to switch strategies.
enum MCPEncoding {
    /// Round-trips an `Encodable` through JSON into the untyped `MCPJSONAny`
    /// shape. Dates are encoded as ISO-8601 strings.
    static func encodeAsJSONAny<T: Encodable>(_ value: T) throws -> MCPJSONAny {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(MCPJSONAny.self, from: data)
    }

    /// Client-safe message for an error propagated to the MCP client. Only
    /// `LocalizedError.errorDescription` values cross the MCP boundary;
    /// unknown errors get a generic message so plain `Error` reflections
    /// (which can include paths or internal state via NSError userInfo)
    /// never leak to clients. The raw detail should be sent to stderr by
    /// the caller via the handler's log hook.
    static func clientFacingMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.isEmpty {
            return localized
        }
        return "internal error"
    }
}
