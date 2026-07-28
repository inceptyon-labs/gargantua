import Testing
import Foundation
@testable import GargantuaCore

/// A stand-in for the date-bearing tool payload the MCP surface does not have
/// today. The point of the suite is that adding one later cannot regress the
/// wire format back to reference-date numbers.
private struct DateBearingPayload: Codable, Equatable {
    let label: String
    let recordedAt: Date
}

@Suite("MCPEncoding date strategy")
struct MCPEncodingTests {

    /// 2026-04-11T14:30:00Z
    private static let fixedDate = Date(timeIntervalSince1970: 1_775_917_800)
    private static let fixedISO = "2026-04-11T14:30:00Z"

    @Test("encodeAsJSONAny writes Date fields as ISO-8601 strings")
    func encodesDatesAsISO8601() throws {
        let encoded = try MCPEncoding.encodeAsJSONAny(
            DateBearingPayload(label: "scan", recordedAt: Self.fixedDate)
        )
        guard case .object(let fields) = encoded else {
            Issue.record("expected an object, got \(encoded)")
            return
        }
        #expect(fields["recordedAt"] == .string(Self.fixedISO))
    }

    @Test("decodeFromJSONAny reads ISO-8601 strings back into Date")
    func decodesISO8601IntoDate() throws {
        let any: MCPJSONAny = .object([
            "label": .string("scan"),
            "recordedAt": .string(Self.fixedISO),
        ])
        let decoded = try MCPEncoding.decodeFromJSONAny(DateBearingPayload.self, from: any)
        #expect(decoded == DateBearingPayload(label: "scan", recordedAt: Self.fixedDate))
    }

    @Test("a Date-bearing tool payload survives dispatch as an ISO-8601 string")
    func datePayloadSurvivesDispatch() throws {
        let dispatcher = MCPRequestDispatcher(
            serverInfo: MCPServerInfo(name: "gargantua", version: "0.0.1"),
            tools: MCPPhase2Tools.all
        )
        dispatcher.register(tool: .status) { _ in
            let payload = try MCPEncoding.encodeAsJSONAny(
                DateBearingPayload(label: "scan", recordedAt: Self.fixedDate)
            )
            return .structured(payload, summary: "ok")
        }
        let response = try #require(
            dispatcher.dispatch(
                MCPRequest(
                    id: .int(1),
                    method: "tools/call",
                    params: .object(["name": .string("status")])
                )
            )
        )
        #expect(response.error == nil)
        // Assert on the bytes a client actually receives, not on the
        // intermediate MCPJSONAny — the regression this guards is a wire-format
        // one.
        let wire = try MCPWireCoding.encoder.encode(response)
        let json = try #require(String(data: wire, encoding: .utf8))
        #expect(json.contains("\"\(Self.fixedISO)\""))
        #expect(!json.contains("797610600"))  // reference-date seconds
    }
}
