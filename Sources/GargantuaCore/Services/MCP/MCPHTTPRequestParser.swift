import Foundation

/// Streaming-safe HTTP request parser used by the MCP SSE transport.
public enum MCPHTTPRequestParser {
    /// Maximum bytes allowed in the request header section.
    public static let maximumHeaderBytes = 65_536
    /// Maximum bytes allowed in the request body.
    public static let maximumBodyBytes = 1_048_576
    /// Combined header and body byte limit per buffered request.
    public static let maximumBufferedBytes = maximumHeaderBytes + maximumBodyBytes

    /// Parses a request from the supplied buffer or returns `nil` when more data is needed.
    public static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        guard data.count <= maximumBufferedBytes else {
            throw MCPHTTPParseError.bodyTooLarge
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes {
                throw MCPHTTPParseError.headerTooLarge
            }
            return nil
        }
        guard separatorRange.lowerBound <= maximumHeaderBytes else {
            throw MCPHTTPParseError.headerTooLarge
        }

        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MCPHTTPParseError.invalidHeaderEncoding
        }

        let lines = headerText.components(separatedBy: "\r\n")
        let (method, target) = try parseRequestLine(lines.first)
        let headers = try parseHeaders(from: lines.dropFirst())

        guard let body = try extractBody(
            from: data,
            bodyStart: separatorRange.upperBound,
            headers: headers
        ) else {
            return nil
        }

        let (path, query) = parseTarget(target)
        return MCPHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func parseRequestLine(_ line: String?) throws -> (method: String, target: String) {
        guard let line else {
            throw MCPHTTPParseError.invalidRequestLine
        }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            throw MCPHTTPParseError.invalidRequestLine
        }
        return (parts[0], parts[1])
    }

    private static func parseHeaders(from lines: ArraySlice<String>) throws -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw MCPHTTPParseError.invalidHeader
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key.lowercased()] = value
        }
        return headers
    }

    private static func extractBody(
        from data: Data,
        bodyStart: Data.Index,
        headers: [String: String]
    ) throws -> Data? {
        guard let contentLength = Int(headers["content-length"] ?? "0"),
              contentLength >= 0
        else {
            throw MCPHTTPParseError.invalidHeader
        }
        guard contentLength <= maximumBodyBytes else {
            throw MCPHTTPParseError.bodyTooLarge
        }

        let availableBodyBytes = data.distance(from: bodyStart, to: data.endIndex)
        guard availableBodyBytes >= contentLength else {
            return nil
        }
        return Data(data[bodyStart ..< data.index(bodyStart, offsetBy: contentLength)])
    }

    private static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }
        return (path, query)
    }
}

/// Errors thrown by `MCPHTTPRequestParser`.
public enum MCPHTTPParseError: Error, LocalizedError, Equatable, Sendable {
    /// Headers contained bytes that were not valid UTF-8.
    case invalidHeaderEncoding
    /// Request line was missing or malformed.
    case invalidRequestLine
    /// One or more headers were missing a colon or had invalid syntax.
    case invalidHeader
    /// Header section exceeded `MCPHTTPRequestParser.maximumHeaderBytes`.
    case headerTooLarge
    /// Body exceeded `MCPHTTPRequestParser.maximumBodyBytes`.
    case bodyTooLarge

    /// Localized user-facing error description.
    public var errorDescription: String? {
        switch self {
        case .invalidHeaderEncoding:
            return "HTTP request headers were not valid UTF-8."
        case .invalidRequestLine:
            return "HTTP request line was malformed."
        case .invalidHeader:
            return "HTTP request headers were malformed."
        case .headerTooLarge:
            return "HTTP request headers exceeded the MCP SSE limit."
        case .bodyTooLarge:
            return "HTTP request body exceeded the MCP SSE limit."
        }
    }
}
