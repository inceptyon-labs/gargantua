import Foundation

/// Coder configuration for MCP **wire framing** — the JSON-RPC envelope both
/// the stdio and SSE transports read and write.
///
/// Deliberately separate from `MCPEncoding`, which serialises tool *payloads*
/// (ISO-8601 dates, no key ordering). Wire framing instead needs
/// `.sortedKeys` + `.withoutEscapingSlashes` so a response line is
/// byte-stable across runs: integration tests and client diffs assert on
/// those exact bytes.
///
/// `JSONEncoder`/`JSONDecoder` are not `Sendable`, so this vends fresh
/// instances rather than shared statics. Each caller keeps its own
/// concurrency story — build per message, or store behind a lock.
enum MCPWireCoding {
    /// Encoder for outbound JSON-RPC messages. Deterministic output.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decoder for inbound JSON-RPC messages. Foundation defaults are correct
    /// here — the wire format carries no dates.
    static func makeDecoder() -> JSONDecoder { JSONDecoder() }
}
