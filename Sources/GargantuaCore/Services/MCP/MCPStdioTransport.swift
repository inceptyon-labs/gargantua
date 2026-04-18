import Foundation

// Newline-delimited JSON-RPC 2.0 transport for the stdio MCP server.
//
// Framing only. Messages are single-line JSON objects separated by "\n".
// The transport is agnostic to dispatch: callers supply a handler closure
// that turns decoded `MCPRequest` values into `MCPResponse` values.
// Notifications (id absent) never produce a response, per the JSON-RPC
// spec.

/// Line-oriented source of JSON-RPC messages. Returning `nil` denotes EOF.
public protocol MCPMessageSource: AnyObject {
    func readLine() -> String?
}

/// Line-oriented sink for JSON-RPC messages. Implementations are
/// responsible for appending a trailing newline.
public protocol MCPMessageSink: AnyObject {
    func writeLine(_ line: String)
}

/// Synchronous handler contract. Returning `nil` is reserved for future
/// use; notification responses are suppressed by the transport regardless.
public typealias MCPMessageHandler = @Sendable (MCPRequest) -> MCPResponse?

/// Diagnostic log sink. stderr-bound in production; swallowed in tests.
public typealias MCPTransportLog = @Sendable (String) -> Void

/// Upper bound for how many characters of a malformed message we include
/// in diagnostic logs. Keeps stderr output bounded and prevents control
/// characters in attacker-controlled payloads from scrambling a terminal.
private let mcpLogExcerptLimit = 512

/// Runs a blocking read/dispatch/write loop. The transport decodes each
/// line into an `MCPRequest`, invokes the handler, and writes any
/// resulting `MCPResponse` as a single JSON line.
public final class MCPStdioTransport {
    private let source: MCPMessageSource
    private let sink: MCPMessageSink
    private let handler: MCPMessageHandler
    private let log: MCPTransportLog?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        source: MCPMessageSource,
        sink: MCPMessageSink,
        handler: @escaping MCPMessageHandler,
        log: MCPTransportLog? = nil
    ) {
        self.source = source
        self.sink = sink
        self.handler = handler
        self.log = log
        self.encoder = JSONEncoder()
        // Deterministic output keeps integration tests and client diffs stable.
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
    }

    /// Reads lines until EOF, dispatching each complete message.
    public func run() {
        while let rawLine = source.readLine() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            process(line: trimmed)
        }
    }

    // MARK: - Per-line dispatch

    private func process(line: String) {
        guard let data = line.data(using: .utf8) else {
            // A String built from readLine() is always UTF-8, so this is
            // effectively unreachable; guard anyway for completeness.
            emit(
                .failure(
                    id: .null,
                    code: MCPErrorCode.parseError,
                    message: "Message was not valid UTF-8"
                ),
                fallbackID: .null
            )
            return
        }

        let request: MCPRequest
        do {
            request = try decoder.decode(MCPRequest.self, from: data)
        } catch {
            // On parse failure, try to salvage the request id so a misnamed
            // method (valid JSON, wrong shape) still gets a correlatable
            // response. Otherwise fall back to a null id per the spec.
            let salvagedID = salvageID(from: data)
            let (code, message) = classify(decodeError: error, rawMessage: line)
            emit(.failure(id: salvagedID, code: code, message: message), fallbackID: salvagedID)
            log?(truncateForLog("decode failed: \(error) — input: \(line)"))
            return
        }

        if request.isNotification {
            // Call the handler for side effects; never write a response.
            _ = handler(request)
            return
        }

        // id is non-nil here because isNotification guards it.
        guard let requestID = request.id else { return }
        if let response = handler(request) {
            emit(response, fallbackID: requestID)
        } else {
            // A handler that returns nil for a non-notification is a bug on
            // the handler side. Surface it as an internal error so clients
            // are not left waiting forever.
            emit(
                .failure(
                    id: requestID,
                    code: MCPErrorCode.internalError,
                    message: "Handler produced no response"
                ),
                fallbackID: requestID
            )
            log?("handler returned nil for non-notification method \(request.method)")
        }
    }

    /// Encodes and writes a response. If encoding fails — for instance
    /// because a handler-provided payload contains a non-finite `Double`
    /// — falls back to an internal-error response built from values that
    /// are guaranteed to encode, so the client is never left waiting.
    private func emit(_ response: MCPResponse, fallbackID: MCPRequestID) {
        if writeEncoded(response) { return }
        let fallback = MCPResponse.failure(
            id: fallbackID,
            code: MCPErrorCode.internalError,
            message: "Response payload failed to encode"
        )
        _ = writeEncoded(fallback)
    }

    @discardableResult
    private func writeEncoded(_ response: MCPResponse) -> Bool {
        do {
            let data = try encoder.encode(response)
            guard let line = String(data: data, encoding: .utf8) else {
                log?("unable to decode response as UTF-8 string")
                return false
            }
            sink.writeLine(line)
            return true
        } catch {
            log?("failed to encode response: \(error)")
            return false
        }
    }

    /// Trims excerpt-length logs and escapes control characters so a
    /// malicious client cannot smuggle terminal control sequences into
    /// stderr output.
    private func truncateForLog(_ input: String) -> String {
        let escaped = input.unicodeScalars.map { scalar -> String in
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return String(format: "\\u%04X", scalar.value)
            }
            return String(scalar)
        }.joined()
        if escaped.count <= mcpLogExcerptLimit {
            return escaped
        }
        let prefix = escaped.prefix(mcpLogExcerptLimit)
        return "\(prefix)… (truncated, \(escaped.count - mcpLogExcerptLimit) more chars)"
    }

    /// Best-effort extraction of an `id` from a request that failed strict
    /// decode. Used so clients get a correlatable response when the error
    /// is something other than a malformed id.
    private func salvageID(from data: Data) -> MCPRequestID {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? [String: Any]
        else {
            return .null
        }
        guard dict.keys.contains("id") else {
            return .null
        }
        let raw = dict["id"]
        if raw is NSNull { return .null }
        if let s = raw as? String { return .string(s) }
        if let n = raw as? NSNumber {
            // NSNumber covers Int, Int64, Double, Bool. Treat bool as invalid id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .null }
            return .int(n.int64Value)
        }
        return .null
    }

    private func classify(decodeError: Error, rawMessage: String) -> (Int, String) {
        // JSONDecoder throws DecodingError even when the underlying JSON is
        // itself malformed (the parser surfaces .dataCorrupted). We treat
        // invalid JSON as parseError and well-formed JSON that fails our
        // shape constraints as invalidRequest.
        if !isValidJSON(rawMessage) {
            return (MCPErrorCode.parseError, "Parse error: invalid JSON")
        }
        return (MCPErrorCode.invalidRequest, "Invalid Request: \(summarize(decodeError))")
    }

    private func isValidJSON(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    private func summarize(_ error: Error) -> String {
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

// MARK: - Concrete stdio adapters

/// Blocking line reader backed by `Swift.readLine`. Returns `nil` on EOF.
public final class StandardInputMessageSource: MCPMessageSource {
    public init() {}

    public func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }
}

/// Writes lines to `FileHandle.standardOutput` with a trailing newline.
///
/// stdout is reserved for protocol traffic; the main entry point routes
/// log output and banners to stderr instead.
public final class StandardOutputMessageSink: MCPMessageSink {
    public init() {}

    public func writeLine(_ line: String) {
        let payload = line + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
}
