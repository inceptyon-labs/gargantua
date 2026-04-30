import Foundation
import Testing
@testable import GargantuaCore

@Suite("ClaudeCodeStreamJSONParser")
struct ClaudeCodeStreamJSONParserTests {
    private let parser = ClaudeCodeStreamJSONParser()

    @Test("blank and non-JSON lines parse as nil")
    func blankAndNonJSONLines() {
        #expect(parser.parse(line: "") == nil)
        #expect(parser.parse(line: "   ") == nil)
        #expect(parser.parse(line: "not json at all") == nil)
        #expect(parser.parse(line: "[1, 2, 3]") == nil) // top-level non-object
    }

    @Test("system init surfaces model and connected MCP server names")
    func systemInit() throws {
        let line = """
        {"type":"system","subtype":"init","model":"claude-sonnet-4-6","mcp_servers":[{"name":"gargantua","status":"connected"},{"name":"other","status":"connected"}]}
        """
        guard case let .sessionInit(model, servers) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected sessionInit")
            return
        }
        #expect(model == "claude-sonnet-4-6")
        #expect(servers == ["gargantua", "other"])
    }

    @Test("system non-init events fall back to .unknown(system)")
    func systemNonInit() {
        let line = #"{"type":"system","subtype":"telemetry","payload":{}}"#
        if case .unknown(let type) = parser.parse(line: line) {
            #expect(type == "system")
        } else {
            Issue.record("Expected .unknown")
        }
    }

    @Test("assistant text content emits assistantText with the joined text")
    func assistantText() throws {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at caches now."}]}}
        """#
        guard case let .assistantText(text) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected assistantText")
            return
        }
        #expect(text == "Looking at caches now.")
    }

    @Test("assistant tool_use takes precedence over text in the same message")
    func assistantToolUseTakesPrecedence() throws {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[
            {"type":"text","text":"I'll scan now."},
            {"type":"tool_use","id":"toolu_1","name":"mcp__gargantua__scan","input":{"profile":"default","dry_run":true}}
        ]}}
        """#
        guard case let .toolUse(name, summary, payload) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolUse")
            return
        }
        #expect(name == "mcp__gargantua__scan")
        // Summary should contain the input keys, on a single line, and not be empty.
        #expect(summary.contains("profile"))
        #expect(!summary.contains("\n"))
        // Scan tool calls don't carry a structured payload — only `clean` does.
        #expect(payload == nil)
    }

    @Test("assistant tool_use for mcp__gargantua__clean exposes the requested item_ids as a structured payload")
    func cleanToolUseExposesItemIDs() throws {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[
            {"type":"tool_use","id":"toolu_clean_1","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-1","chrome_cache-2","npm_cache-7"],"method":"trash","confirm":true}}
        ]}}
        """#
        guard case let .toolUse(name, _, payload) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolUse")
            return
        }
        #expect(name == "mcp__gargantua__clean")
        guard case let .cleanRequest(itemIDs) = try #require(payload) else {
            Issue.record("Expected cleanRequest payload")
            return
        }
        #expect(itemIDs == ["chrome_cache-1", "chrome_cache-2", "npm_cache-7"])
    }

    @Test("clean tool_use with no item_ids field surfaces a nil payload rather than crashing")
    func cleanToolUseMissingItemIDs() throws {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[
            {"type":"tool_use","id":"toolu_clean_2","name":"mcp__gargantua__clean","input":{"method":"trash"}}
        ]}}
        """#
        guard case let .toolUse(_, _, payload) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolUse")
            return
        }
        #expect(payload == nil)
    }

    @Test("user tool_result emits toolResult with id, error flag, and clipped summary")
    func userToolResult() throws {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[
            {"type":"tool_result","tool_use_id":"toolu_1","content":"Found 482 cache items totaling 2.1 GB.","is_error":false}
        ]}}
        """#
        guard case let .toolResult(id, isError, summary) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolResult")
            return
        }
        #expect(id == "toolu_1")
        #expect(isError == false)
        #expect(summary == "Found 482 cache items totaling 2.1 GB.")
    }

    @Test("user tool_result honours is_error true")
    func userToolResultError() throws {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[
            {"type":"tool_result","tool_use_id":"toolu_2","content":"Profile not found","is_error":true}
        ]}}
        """#
        guard case let .toolResult(_, isError, summary) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolResult")
            return
        }
        #expect(isError == true)
        #expect(summary == "Profile not found")
    }

    @Test("result subtype=success becomes a terminal with kind=success")
    func resultSuccess() throws {
        let line = #"""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":4500,"num_turns":3,"result":"All caches reviewed.","total_cost_usd":0.12,"modelUsage":{"claude-sonnet-4-6":{"inputTokens":100}}}
        """#
        guard case let .terminal(result) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected terminal")
            return
        }
        #expect(result.kind == .success)
        #expect(result.subtype == "success")
        #expect(result.isError == false)
        #expect(result.durationMs == 4500)
        #expect(result.numTurns == 3)
        #expect(result.totalCostUsd == 0.12)
        #expect(result.resultText == "All caches reviewed.")
        #expect(result.errors.isEmpty)
        #expect(result.model == "claude-sonnet-4-6")
    }

    @Test("real-world error_max_turns payload classifies as kind=maxTurns")
    func realMaxTurnsPayload() throws {
        // Lifted verbatim (modulo whitespace) from the user-reported failure.
        let line = #"""
        {"type":"result","subtype":"error_max_turns","duration_ms":136279,"duration_api_ms":22187,"is_error":true,"num_turns":6,"stop_reason":"tool_use","session_id":"caf4963d-3b31-4129-918a-0299b42733e9","total_cost_usd":0.45851450000000005,"usage":{"input_tokens":15,"cache_creation_input_tokens":57180,"cache_read_input_tokens":132079,"output_tokens":1401},"modelUsage":{"claude-opus-4-7[1m]":{"inputTokens":15,"outputTokens":1401}},"permission_denials":[],"terminal_reason":"max_turns","fast_mode_state":"off","errors":["Reached maximum number of turns (5)"]}
        """#
        guard case let .terminal(result) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected terminal")
            return
        }
        #expect(result.kind == .maxTurns)
        #expect(result.subtype == "error_max_turns")
        #expect(result.isError)
        #expect(result.numTurns == 6)
        #expect(result.durationMs == 136_279)
        #expect(result.totalCostUsd == 0.45851450000000005)
        #expect(result.errors == ["Reached maximum number of turns (5)"])
        #expect(result.model == "claude-opus-4-7[1m]")
    }

    @Test("real-world API-error payload (subtype=success but is_error=true) keeps subtype=success and otherError kind")
    func realAPIErrorPayload() throws {
        let line = #"""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":400,"duration_ms":4574,"duration_api_ms":3717,"num_turns":2,"result":"API Error: 400 ...","stop_reason":"stop_sequence","session_id":"d5229c64-d639-4445-8cc6-11c66cf50251","total_cost_usd":0.2313175,"modelUsage":{"claude-opus-4-7[1m]":{"inputTokens":6}}}
        """#
        guard case let .terminal(result) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected terminal")
            return
        }
        #expect(result.subtype == "success")
        #expect(result.isError) // SDK flagged the API error
        #expect(result.kind == .otherError) // not maxTurns
        #expect(result.resultText?.hasPrefix("API Error") == true)
    }

    @Test("unknown event types surface as .unknown so the raw transcript can render them")
    func unknownEventType() {
        let line = #"{"type":"future_telemetry","payload":{"foo":1}}"#
        if case .unknown(let type) = parser.parse(line: line) {
            #expect(type == "future_telemetry")
        } else {
            Issue.record("Expected .unknown")
        }
    }

    @Test("summary truncates to summaryLimit with an ellipsis suffix")
    func summarizeLength() throws {
        let huge = String(repeating: "x", count: ClaudeCodeStreamJSONParser.summaryLimit + 50)
        let line = #"""
        {"type":"user","message":{"role":"user","content":[
            {"type":"tool_result","tool_use_id":"toolu_long","content":"\#(huge)","is_error":false}
        ]}}
        """#
        guard case let .toolResult(_, _, summary) = try #require(parser.parse(line: line)) else {
            Issue.record("Expected toolResult")
            return
        }
        #expect(summary.count == ClaudeCodeStreamJSONParser.summaryLimit + 1) // limit + ellipsis
        #expect(summary.hasSuffix("…"))
    }
}
