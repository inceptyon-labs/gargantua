import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP tool schemas")
struct MCPToolSchemasTests {

    // MARK: Registry

    @Test("Phase 2 registry has exactly the five PRD §7.3 tools")
    func phase2RegistryContents() {
        let names = MCPPhase2Tools.all.map(\.name)
        #expect(names == [.scan, .analyze, .explain, .listProfiles, .status])
    }

    @Test("No clean tool exists in the Phase 2 registry")
    func noCleanToolInPhase2() {
        let rawNames = Set(MCPPhase2Tools.all.map { $0.name.rawValue })
        #expect(!rawNames.contains("clean"))
    }

    @Test("list_profiles tool name encodes with snake case")
    func snakeCaseToolName() throws {
        let data = try JSONEncoder().encode(MCPToolName.listProfiles)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"list_profiles\"")
    }

    // MARK: scan schema invariants

    @Test("scan schema pins dry_run to constant true")
    func scanSchemaPinsDryRun() throws {
        let scan = MCPPhase2Tools.scan
        let dryRun = scan.inputSchema.properties?["dry_run"]
        #expect(dryRun?.const == .bool(true))
        #expect(scan.inputSchema.required?.contains("dry_run") == true)
    }

    @Test("scan schema profile property uses PRD enum values")
    func scanSchemaProfileEnum() {
        let scan = MCPPhase2Tools.scan
        let profile = scan.inputSchema.properties?["profile"]
        #expect(profile?.enumValues == ["developer", "light", "deep", "custom"])
    }

    // MARK: scan input decoding

    @Test("scan input decodes when dry_run is absent (defaults to true)")
    func scanInputDefaultsDryRunTrue() throws {
        let json = Data(#"{"profile":"developer"}"#.utf8)
        let input = try JSONDecoder().decode(MCPScanInput.self, from: json)
        #expect(input.dryRun == true)
        #expect(input.profile == "developer")
    }

    @Test("scan input decodes when dry_run is explicitly true")
    func scanInputAcceptsDryRunTrue() throws {
        let json = Data(#"{"dry_run":true}"#.utf8)
        let input = try JSONDecoder().decode(MCPScanInput.self, from: json)
        #expect(input.dryRun == true)
    }

    @Test("scan input rejects dry_run=false — MCP cannot disable dry-run")
    func scanInputRejectsDryRunFalse() {
        let json = Data(#"{"dry_run":false}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPScanInput.self, from: json)
        }
    }

    @Test("scan input uses snake_case dry_run key on encode")
    func scanInputEncodesSnakeCase() throws {
        let input = MCPScanInput(profile: "light")
        let data = try JSONEncoder().encode(input)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"dry_run\""))
    }

    // MARK: explain input validation

    @Test("explain input accepts a bare path")
    func explainAcceptsPath() throws {
        let json = Data(#"{"path":"~/Library/Caches/com.apple.dt.Xcode"}"#.utf8)
        let input = try JSONDecoder().decode(MCPExplainInput.self, from: json)
        #expect(input.path == "~/Library/Caches/com.apple.dt.Xcode")
        #expect(input.itemId == nil)
    }

    @Test("explain input accepts an item_id and exposes snake_case key")
    func explainAcceptsItemID() throws {
        let json = Data(#"{"item_id":"chrome_cache_001"}"#.utf8)
        let input = try JSONDecoder().decode(MCPExplainInput.self, from: json)
        #expect(input.itemId == "chrome_cache_001")
    }

    @Test("explain input rejects empty payload")
    func explainRejectsEmpty() {
        let json = Data("{}".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPExplainInput.self, from: json)
        }
    }

    @Test("explain input rejects both path and item_id")
    func explainRejectsBoth() {
        let json = Data(#"{"path":"/tmp","item_id":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPExplainInput.self, from: json)
        }
    }

    // MARK: output round-trips

    @Test("scan output round-trip preserves snake_case keys")
    func scanOutputRoundTrip() throws {
        let output = MCPScanOutput(
            totalReclaimable: "23.5 GB",
            items: [
                MCPScanItem(
                    id: "chrome_cache_001",
                    name: "Chrome Browser Cache",
                    path: "~/Library/Caches/Google/Chrome",
                    size: "10.5 GB",
                    safety: "safe",
                    confidence: 99,
                    explanation: "Browser cache files. Regenerated automatically.",
                    source: "Google Chrome",
                    lastAccessed: Date(timeIntervalSince1970: 1_700_000_000),
                    category: "browser_cache"
                ),
            ],
            summary: MCPScanSummary(
                safeCount: 45, safeSize: "18.2 GB",
                reviewCount: 12, reviewSize: "5.3 GB",
                protectedCount: 3
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(output)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"total_reclaimable\""))
        #expect(s.contains("\"safe_count\""))
        #expect(s.contains("\"last_accessed\""))

        let decoded = try decoder.decode(MCPScanOutput.self, from: data)
        #expect(decoded == output)
    }

    @Test("analyze output uses health_score and top_consumers snake_case")
    func analyzeOutputKeys() throws {
        let output = MCPAnalyzeOutput(
            healthScore: 85,
            disk: MCPDiskUsage(total: "500 GB", used: "380 GB", free: "120 GB"),
            topConsumers: [MCPTopConsumer(name: "node_modules", path: "/tmp/app", size: "2 GB")],
            recommendations: ["Prune Docker cache"]
        )
        let data = try JSONEncoder().encode(output)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"health_score\""))
        #expect(s.contains("\"top_consumers\""))
    }

    @Test("status output round-trip")
    func statusOutputRoundTrip() throws {
        let output = MCPStatusOutput(
            healthScore: 92,
            cpu: MCPStatusCPU(usage: 45.2, cores: 10),
            memory: MCPStatusMemory(used: "14.2 GB", total: "32 GB", percent: 44.4),
            disk: MCPStatusDisk(used: "380 GB", total: "500 GB", percent: 76.0),
            uptime: "6d 12h"
        )
        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(MCPStatusOutput.self, from: data)
        #expect(decoded == output)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"health_score\""))
    }

    @Test("list_profiles output round-trip")
    func listProfilesRoundTrip() throws {
        let output = MCPListProfilesOutput(
            profiles: [
                MCPProfileSummary(name: "developer", categories: ["dev_artifacts"], description: "…"),
                MCPProfileSummary(name: "light", categories: ["browser_cache"], description: "…"),
            ],
            active: "developer"
        )
        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(MCPListProfilesOutput.self, from: data)
        #expect(decoded == output)
    }

    // MARK: explain schema oneOf advertising

    @Test("explain schema advertises oneOf for path/item_id mutual exclusion")
    func explainSchemaAdvertisesOneOf() {
        let oneOf = MCPPhase2Tools.explain.inputSchema.oneOf
        #expect(oneOf?.count == 2)
        #expect(oneOf?[0].required == ["path"])
        #expect(oneOf?[1].required == ["item_id"])
        #expect(oneOf?[0].type == .object)
        #expect(oneOf?[1].type == .object)
    }

    @Test("explain descriptor JSON exposes oneOf branches for schema-driven clients")
    func explainDescriptorOneOfJSON() throws {
        let data = try JSONEncoder().encode(MCPPhase2Tools.explain)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = obj?["inputSchema"] as? [String: Any]
        let oneOf = schema?["oneOf"] as? [[String: Any]]
        #expect(oneOf?.count == 2)
        let requiredSets = Set(oneOf?.compactMap { $0["required"] as? [String] } ?? [])
        #expect(requiredSets == [["path"], ["item_id"]])
    }

    @Test("MCPJSONSchema round-trips a schema carrying oneOf")
    func oneOfRoundTrip() throws {
        let original = MCPJSONSchema(
            type: .object,
            properties: [
                "a": MCPJSONSchema(type: .string),
                "b": MCPJSONSchema(type: .string),
            ],
            required: [],
            oneOf: [
                MCPJSONSchema(type: .object, required: ["a"]),
                MCPJSONSchema(type: .object, required: ["b"]),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPJSONSchema.self, from: data)
        #expect(decoded == original)
    }

    @Test("MCPJSONSchema omits oneOf when not provided")
    func oneOfOmittedWhenNil() throws {
        let schema = MCPJSONSchema(type: .string, description: "x")
        let data = try JSONEncoder().encode(schema)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(!s.contains("oneOf"))
    }

    // MARK: tool descriptor JSON shape

    @Test("Tool descriptor encodes inputSchema alongside name and description")
    func toolDescriptorShape() throws {
        let data = try JSONEncoder().encode(MCPPhase2Tools.scan)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "scan")
        #expect(obj?["description"] is String)
        let schema = obj?["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        let props = schema?["properties"] as? [String: Any]
        let dryRun = props?["dry_run"] as? [String: Any]
        #expect(dryRun?["const"] as? Bool == true)
    }
}
