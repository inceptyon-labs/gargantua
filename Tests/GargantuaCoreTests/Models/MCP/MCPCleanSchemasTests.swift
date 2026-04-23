import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean tool schemas")
struct MCPCleanSchemasTests {

    // MARK: Registry

    @Test("Phase 3 registry contains exactly the clean tool")
    func phase3RegistryContents() {
        let names = MCPPhase3Tools.all.map(\.name)
        #expect(names == [.clean])
    }

    @Test("clean is absent from the Phase 2 registry")
    func cleanAbsentFromPhase2() {
        let rawNames = Set(MCPPhase2Tools.all.map { $0.name.rawValue })
        #expect(!rawNames.contains("clean"))
    }

    @Test("MCPToolName includes the clean case")
    func toolNameIncludesClean() {
        #expect(MCPToolName.allCases.contains(.clean))
    }

    @Test("clean tool name encodes as 'clean'")
    func cleanToolNameEncoding() throws {
        let data = try JSONEncoder().encode(MCPToolName.clean)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"clean\"")
    }

    // MARK: Schema invariants

    @Test("clean schema pins confirm to constant true")
    func cleanSchemaPinsConfirm() {
        let clean = MCPPhase3Tools.clean
        let confirm = clean.inputSchema.properties?["confirm"]
        #expect(confirm?.const == .bool(true))
    }

    @Test("clean schema method property uses enum [trash, delete]")
    func cleanSchemaMethodEnum() {
        let clean = MCPPhase3Tools.clean
        let method = clean.inputSchema.properties?["method"]
        #expect(method?.enumValues == ["trash", "delete"])
    }

    @Test("clean schema requires item_ids and confirm")
    func cleanSchemaRequired() {
        let required = Set(MCPPhase3Tools.clean.inputSchema.required ?? [])
        #expect(required == ["item_ids", "confirm"])
    }

    @Test("clean schema item_ids is a string array")
    func cleanSchemaItemIDsArray() {
        let itemIDs = MCPPhase3Tools.clean.inputSchema.properties?["item_ids"]
        #expect(itemIDs?.type == .array)
        #expect(itemIDs?.items?.value.type == .string)
    }

    // MARK: Input decoding — happy path

    @Test("clean input decodes a minimal well-formed payload")
    func cleanInputMinimalDecode() throws {
        let json = Data(#"{"item_ids":["chrome_cache_001"],"confirm":true}"#.utf8)
        let input = try JSONDecoder().decode(MCPCleanInput.self, from: json)
        #expect(input.itemIDs == ["chrome_cache_001"])
        #expect(input.method == "trash")  // default
        #expect(input.confirm == true)
        #expect(input.dryRun == false)    // default
    }

    @Test("clean input decodes a full payload with all fields")
    func cleanInputFullDecode() throws {
        let json = Data(#"{"item_ids":["a","b"],"method":"delete","confirm":true,"dry_run":true}"#.utf8)
        let input = try JSONDecoder().decode(MCPCleanInput.self, from: json)
        #expect(input.itemIDs == ["a", "b"])
        #expect(input.method == "delete")
        #expect(input.confirm == true)
        #expect(input.dryRun == true)
    }

    // MARK: Input decoding — rejections

    @Test("clean input rejects confirm=false")
    func cleanInputRejectsConfirmFalse() {
        let json = Data(#"{"item_ids":["x"],"confirm":false}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPCleanInput.self, from: json)
        }
    }

    @Test("clean input rejects missing confirm")
    func cleanInputRejectsMissingConfirm() {
        let json = Data(#"{"item_ids":["x"]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPCleanInput.self, from: json)
        }
    }

    @Test("clean input rejects empty item_ids")
    func cleanInputRejectsEmptyItemIDs() {
        let json = Data(#"{"item_ids":[],"confirm":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPCleanInput.self, from: json)
        }
    }

    @Test("clean input rejects missing item_ids")
    func cleanInputRejectsMissingItemIDs() {
        let json = Data(#"{"confirm":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPCleanInput.self, from: json)
        }
    }

    // MARK: Input encoding — snake_case keys

    @Test("clean input uses snake_case keys on encode")
    func cleanInputEncodesSnakeCase() throws {
        let input = MCPCleanInput(itemIDs: ["x"], method: "trash", confirm: true, dryRun: true)
        let data = try JSONEncoder().encode(input)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"item_ids\""))
        #expect(s.contains("\"dry_run\""))
    }

    // MARK: Output round-trips

    @Test("clean output round-trip preserves snake_case keys")
    func cleanOutputRoundTrip() throws {
        let output = MCPCleanOutput(
            cleaned: 2,
            freed: "15.3 GB",
            method: "trash",
            auditID: "audit_2026-04-23_001",
            perItem: [
                MCPCleanItemResult(id: "a", outcome: "moved", reason: nil, bytesFreed: 10_000),
                MCPCleanItemResult(id: "b", outcome: "failed", reason: "permission denied", bytesFreed: nil),
            ]
        )

        let encoded = try JSONEncoder().encode(output)
        let string = String(data: encoded, encoding: .utf8) ?? ""
        #expect(string.contains("\"audit_id\""))
        #expect(string.contains("\"per_item\""))
        #expect(string.contains("\"bytes_freed\""))

        let decoded = try JSONDecoder().decode(MCPCleanOutput.self, from: encoded)
        #expect(decoded == output)
    }

    @Test("clean item result round-trip omits nil optionals")
    func cleanItemResultOmitsNilOptionals() throws {
        let item = MCPCleanItemResult(id: "a", outcome: "skipped")
        let data = try JSONEncoder().encode(item)
        let s = String(data: data, encoding: .utf8) ?? ""
        // Default JSONEncoder omits nil-valued optional properties.
        #expect(!s.contains("\"reason\""))
        #expect(!s.contains("\"bytes_freed\""))
    }
}
