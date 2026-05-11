import Foundation

/// Minimal HTTP request value used by the MCP SSE transport.
public struct MCPHTTPRequest: Sendable, Equatable {
    /// HTTP method, normalized to uppercase.
    public let method: String
    /// URL path component (without query string).
    public let path: String
    /// Parsed query string parameters.
    public let query: [String: String]
    /// Request headers, with names lowercased for case-insensitive lookup.
    public let headers: [String: String]
    /// Raw request body bytes.
    public let body: Data

    /// Creates an HTTP request value, normalizing method and header casing.
    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            normalizedHeaders[key.lowercased()] = value
        }
        self.headers = normalizedHeaders
        self.body = body
    }

    /// Returns the header value for `name`, using case-insensitive lookup.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Minimal HTTP response value used by the MCP SSE transport.
public struct MCPHTTPResponse: Sendable, Equatable {
    /// HTTP status code (e.g. 200, 404).
    public let statusCode: Int
    /// HTTP reason phrase paired with `statusCode`.
    public let reasonPhrase: String
    /// Response headers (case-preserving — emitted verbatim during serialization).
    public let headers: [String: String]
    /// Response body bytes.
    public let body: Data

    /// Creates an HTTP response value.
    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    /// Serializes the response into a buffer ready to write to a TCP connection.
    public func serialized() -> Data {
        var output = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        var allHeaders = headers
        let isStreaming = allHeaders["Content-Type"] == "text/event-stream"
        if !isStreaming && allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = isStreaming ? "keep-alive" : "close"
        }
        for key in allHeaders.keys.sorted() {
            guard let value = allHeaders[key] else { continue }
            output += "\(key): \(value)\r\n"
        }
        output += "\r\n"
        var data = Data(output.utf8)
        data.append(body)
        return data
    }

    /// Builds a `text/plain` HTTP response with the supplied status and message.
    public static func text(
        _ statusCode: Int,
        _ reasonPhrase: String,
        _ message: String
    ) -> MCPHTTPResponse {
        MCPHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }
}

/// Helpers for encoding Server-Sent Events frames used by the MCP transport.
public enum MCPSSEEvent {
    /// Encodes one SSE frame with the supplied event name and multi-line data body.
    public static func encode(event: String, data: String) -> String {
        var output = "event: \(event)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            output += "data: \(line)\n"
        }
        output += "\n"
        return output
    }
}
