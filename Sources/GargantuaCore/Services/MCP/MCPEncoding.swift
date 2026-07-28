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
///
/// The same applies in reverse: `decodeFromJSONAny` reads ISO-8601 strings
/// back into `Date`, so a handler that declares a date-typed argument gets
/// the value a client actually sent rather than a decode failure.
enum MCPEncoding {
    /// Round-trips an `Encodable` through JSON into the untyped `MCPJSONAny`
    /// shape. Dates are encoded as ISO-8601 strings.
    static func encodeAsJSONAny<T: Encodable>(_ value: T) throws -> MCPJSONAny {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(MCPJSONAny.self, from: data)
    }

    /// Inverse of `encodeAsJSONAny`: pulls a strongly-typed value back out of
    /// the untyped `MCPJSONAny` shape, reading ISO-8601 strings as `Date`.
    /// The intermediate encode needs no date strategy — `MCPJSONAny` has no
    /// `Date` case, so by that point a date is already a string.
    static func decodeFromJSONAny<T: Decodable>(
        _ type: T.Type,
        from any: MCPJSONAny
    ) throws -> T {
        let data = try JSONEncoder().encode(any)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
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
