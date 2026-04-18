import Foundation

// JSON-RPC 2.0 envelope types used by the MCP stdio transport.
//
// Kept framing-only: this file defines the Request/Response shapes and
// standard JSON-RPC error codes. Dispatch, tool routing, and handler
// implementations live in follow-up tasks under Feature gargantua-2h06.

/// JSON-RPC request identifier. Per the spec, id MAY be a string, number,
/// or null (an id member explicitly set to null is distinct from an
/// absent id, which denotes a notification).
public enum MCPRequestID: Sendable, Hashable {
    case int(Int64)
    case string(String)
    case null
}

extension MCPRequestID: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "JSON-RPC id must be string, number, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i):    try c.encode(i)
        case .string(let s): try c.encode(s)
        case .null:          try c.encodeNil()
        }
    }
}

/// Arbitrary JSON value, used to carry `params` and `result` payloads
/// through the framing layer without imposing a schema at this layer.
public enum MCPJSONAny: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case number(Double)
    case string(String)
    case array([MCPJSONAny])
    case object([String: MCPJSONAny])
}

extension MCPJSONAny: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self = .number(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? c.decode([MCPJSONAny].self) {
            self = .array(arr)
            return
        }
        if let obj = try? c.decode([String: MCPJSONAny].self) {
            self = .object(obj)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .number(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}

/// Standard JSON-RPC 2.0 error codes (see https://www.jsonrpc.org/specification#error_object).
public enum MCPErrorCode {
    public static let parseError      = -32_700
    public static let invalidRequest  = -32_600
    public static let methodNotFound  = -32_601
    public static let invalidParams   = -32_602
    public static let internalError   = -32_603
}

/// Error member of a JSON-RPC response.
public struct MCPResponseError: Sendable, Equatable, Codable {
    public let code: Int
    public let message: String
    public let data: MCPJSONAny?

    public init(code: Int, message: String, data: MCPJSONAny? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A decoded JSON-RPC 2.0 request or notification.
///
/// When `id` is `nil` the message is a notification and MUST NOT receive
/// a response. An `id` of `.null` is a well-formed request whose response
/// id is also null.
public struct MCPRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let method: String
    public let params: MCPJSONAny?

    public init(
        jsonrpc: String = "2.0",
        id: MCPRequestID?,
        method: String,
        params: MCPJSONAny? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

extension MCPRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(String.self, forKey: .jsonrpc)
        guard version == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: c,
                debugDescription: "jsonrpc must be \"2.0\", got \"\(version)\""
            )
        }
        // An absent id member denotes a notification; id present-but-null
        // is a well-formed request whose response echoes null.
        let id: MCPRequestID?
        if c.contains(.id) {
            id = try c.decode(MCPRequestID.self, forKey: .id)
        } else {
            id = nil
        }
        let method = try c.decode(String.self, forKey: .method)
        // Preserve explicit null params so dispatch can distinguish "no
        // params" from "params: null"; parallels the id handling above.
        let params: MCPJSONAny?
        if c.contains(.params) {
            params = try c.decode(MCPJSONAny.self, forKey: .params)
        } else {
            params = nil
        }
        self.init(jsonrpc: version, id: id, method: method, params: params)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        if let id {
            try c.encode(id, forKey: .id)
        }
        try c.encode(method, forKey: .method)
        if let params {
            try c.encode(params, forKey: .params)
        }
    }
}

/// A JSON-RPC 2.0 response. Exactly one of `result` or `error` must be set.
public struct MCPResponse: Sendable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestID
    public let result: MCPJSONAny?
    public let error: MCPResponseError?

    private init(
        jsonrpc: String,
        id: MCPRequestID,
        result: MCPJSONAny?,
        error: MCPResponseError?
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: MCPRequestID, result: MCPJSONAny) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    public static func failure(id: MCPRequestID, error: MCPResponseError) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: nil, error: error)
    }

    public static func failure(
        id: MCPRequestID,
        code: Int,
        message: String,
        data: MCPJSONAny? = nil
    ) -> MCPResponse {
        .failure(id: id, error: MCPResponseError(code: code, message: message, data: data))
    }
}

extension MCPResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(String.self, forKey: .jsonrpc)
        guard version == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: .jsonrpc,
                in: c,
                debugDescription: "jsonrpc must be \"2.0\", got \"\(version)\""
            )
        }
        let id = try c.decode(MCPRequestID.self, forKey: .id)
        // Distinguish success from error by key PRESENCE, not by value,
        // so a well-formed `{"result": null}` decodes as a success with
        // `.null` rather than being rejected as an empty response.
        let hasResult = c.contains(.result)
        let hasError = c.contains(.error)
        switch (hasResult, hasError) {
        case (false, false):
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: c,
                debugDescription: "JSON-RPC response must contain either result or error"
            )
        case (true, true):
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: c,
                debugDescription: "JSON-RPC response must not contain both result and error"
            )
        default:
            break
        }
        let result: MCPJSONAny? = hasResult
            ? try c.decode(MCPJSONAny.self, forKey: .result)
            : nil
        let error: MCPResponseError? = hasError
            ? try c.decode(MCPResponseError.self, forKey: .error)
            : nil
        self.init(jsonrpc: version, id: id, result: result, error: error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        if let result {
            try c.encode(result, forKey: .result)
        }
        if let error {
            try c.encode(error, forKey: .error)
        }
    }
}
