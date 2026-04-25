import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCPRequestDispatcher tools listing and envelope")
struct MCPRequestDispatcherToolsTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private func makeDispatcher(
        tools: [MCPToolDescriptor] = MCPPhase2Tools.all,
        log: MCPDispatcherLog? = nil
    ) -> MCPRequestDispatcher {
        MCPRequestDispatcher(serverInfo: Self.serverInfo, tools: tools, log: log)
    }

    private func request(
        id: MCPRequestID? = .int(1),
        method: String,
        params: MCPJSONAny? = nil
    ) -> MCPRequest {
        MCPRequest(id: id, method: method, params: params)
    }

    // MARK: tools/list

    @Test("tools/list advertises all Phase 2 tools")
    func toolsListContainsAllPhase2Tools() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"] else {
            Issue.record("tools/list result missing tools array: \(result)")
            return
        }
        let names = tools.compactMap { entry -> String? in
            guard case .object(let obj) = entry, case .string(let name) = obj["name"] else { return nil }
            return name
        }
        #expect(Set(names) == Set(MCPPhase2Tools.all.map(\.name.rawValue)))
    }

    @Test("tools/list encodes the schema in MCP shape (name/description/inputSchema)")
    func toolsListEntryShape() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"], let first = tools.first,
              case .object(let entry) = first else {
            Issue.record("tools/list missing entries")
            return
        }
        #expect(entry.keys.contains("name"))
        #expect(entry.keys.contains("description"))
        #expect(entry.keys.contains("inputSchema"))

        guard case .object(let inputSchema) = entry["inputSchema"] else {
            Issue.record("inputSchema missing")
            return
        }
        #expect(inputSchema["type"] == .string("object"))
    }

    @Test("tools/list preserves scan.dry_run const=true")
    func toolsListPreservesScanDryRunConstant() throws {
        let dispatcher = makeDispatcher()
        let response = dispatcher.dispatch(request(method: "tools/list"))
        let result = try #require(response?.result)
        guard case .object(let root) = result, case .array(let tools) = root["tools"] else {
            Issue.record("missing tools array")
            return
        }
        let scanEntry = tools.first { entry in
            guard case .object(let obj) = entry, case .string(let name) = obj["name"] else { return false }
            return name == "scan"
        }
        guard let scanEntry, case .object(let obj) = scanEntry,
              case .object(let schema) = obj["inputSchema"],
              case .object(let properties) = schema["properties"],
              case .object(let dryRun) = properties["dry_run"] else {
            Issue.record("scan.dry_run schema missing")
            return
        }
        #expect(dryRun["const"] == .bool(true))
    }

    // MARK: tools/call — result envelope (MCP CallToolResult shape)

    @Test("tools/call result wraps handler output in MCP CallToolResult envelope")
    func toolsCallResultHasContentEnvelope() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .analyze) { _ in
            .structured(.object(["health_score": .int(99)]), summary: "Healthy")
        }
        let params: MCPJSONAny = .object([
            "name": .string("analyze"),
            "arguments": .object([:]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        #expect(response?.error == nil)
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        // `content` must be present as an array of blocks; the first block
        // must be a text block with the summary we provided.
        guard case .array(let content) = root["content"],
              let firstBlock = content.first,
              case .object(let block) = firstBlock else {
            Issue.record("content[] missing or malformed")
            return
        }
        #expect(block["type"] == .string("text"))
        #expect(block["text"] == .string("Healthy"))
        // The typed payload rides along under `structuredContent`.
        guard case .object(let structured) = root["structuredContent"] else {
            Issue.record("structuredContent missing")
            return
        }
        #expect(structured["health_score"] == .int(99))
        // Success responses do not emit isError.
        #expect(root["isError"] == nil)
    }

    @Test("tools/call result omits structuredContent for plain-text handlers")
    func toolsCallTextOnlyResult() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .status) { _ in .text("ok") }
        let params: MCPJSONAny = .object(["name": .string("status")])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        #expect(root["structuredContent"] == nil)
        #expect(root["isError"] == nil)
        guard case .array(let content) = root["content"], case .object(let block) = content.first else {
            Issue.record("content missing")
            return
        }
        #expect(block["type"] == .string("text"))
        #expect(block["text"] == .string("ok"))
    }

    @Test("tool-domain failure returns isError:true success result, not a JSON-RPC error")
    func toolsCallFailureIsReportedAsIsError() throws {
        let dispatcher = makeDispatcher()
        dispatcher.register(tool: .explain) { _ in .failure("item not found") }
        let params: MCPJSONAny = .object([
            "name": .string("explain"),
            "arguments": .object(["path": .string("/missing")]),
        ])
        let response = dispatcher.dispatch(request(method: "tools/call", params: params))
        // Tool-domain failures ride the result, not the JSON-RPC error slot.
        #expect(response?.error == nil)
        guard case .object(let root) = try #require(response?.result) else {
            Issue.record("result was not an object")
            return
        }
        #expect(root["isError"] == .bool(true))
        guard case .array(let content) = root["content"], case .object(let block) = content.first else {
            Issue.record("content missing")
            return
        }
        #expect(block["text"] == .string("item not found"))
    }
}
