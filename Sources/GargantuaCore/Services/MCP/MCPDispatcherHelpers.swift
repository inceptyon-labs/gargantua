import Foundation

// MARK: - Dispatch errors

/// Internal error type that carries the JSON-RPC code to use.
enum MCPDispatchError: Error {
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
func encodeAsJSONAny<T: Encodable>(_ value: T) throws -> MCPJSONAny {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(MCPJSONAny.self, from: data)
}

/// Inverse of `encodeAsJSONAny`. Lets the dispatcher decode strongly-typed
/// params out of the untyped `MCPJSONAny` payload.
func decodeFromJSONAny<T: Decodable>(_ type: T.Type, from any: MCPJSONAny) throws -> T {
    let data = try JSONEncoder().encode(any)
    return try JSONDecoder().decode(type, from: data)
}

/// Produces a compact one-line description of a decoding error. Avoids the
/// multi-line Swift error descriptions that would muddy JSON-RPC messages.
func describe(_ error: Error) -> String {
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
