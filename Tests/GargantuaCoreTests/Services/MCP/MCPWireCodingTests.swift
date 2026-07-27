import Foundation
import Testing
@testable import GargantuaCore

@Suite("MCP wire coding")
struct MCPWireCodingTests {
    private struct Payload: Encodable {
        let zulu: String
        let alpha: String
    }

    @Test("wire encoder sorts keys and leaves slashes unescaped")
    func wireEncoderFormatting() throws {
        let data = try MCPWireCoding.encoder
            .encode(Payload(zulu: "tools/call", alpha: "1"))

        // Exact match, deliberately. `alpha` before `zulu` is `.sortedKeys`;
        // the bare `/` is `.withoutEscapingSlashes`. Dropping either flag
        // changes these bytes.
        #expect(
            String(data: data, encoding: .utf8)
                == #"{"alpha":"1","zulu":"tools/call"}"#
        )
    }

    @Test("wire coding round-trips a JSON-RPC response")
    func wireCodingRoundTrip() throws {
        let response = MCPResponse.failure(
            id: .int(9),
            code: MCPErrorCode.methodNotFound,
            message: "Method not found: tools/unknown"
        )
        let data = try MCPWireCoding.encoder.encode(response)
        let decoded = try MCPWireCoding.decoder.decode(MCPResponse.self, from: data)

        #expect(decoded.id == .int(9))
        #expect(decoded.error?.code == MCPErrorCode.methodNotFound)
        #expect(decoded.error?.message == "Method not found: tools/unknown")
    }
}
