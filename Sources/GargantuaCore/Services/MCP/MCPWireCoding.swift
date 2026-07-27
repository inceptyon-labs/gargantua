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
/// `JSONEncoder`/`JSONDecoder` are `Sendable`, so both transports share these
/// instances rather than rebuilding a coder per message. Neither is mutated
/// after construction.
enum MCPWireCoding {
    /// Encoder for outbound JSON-RPC messages. Deterministic output.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Decoder for inbound JSON-RPC messages. Foundation defaults are correct
    /// here — the wire format carries no dates.
    static let decoder = JSONDecoder()
}
