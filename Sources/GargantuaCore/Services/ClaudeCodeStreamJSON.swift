import Foundation

/// Structured event derived from a single Claude Code stream-json line.
///
/// Claude Code's `--output-format stream-json` emits one JSON object per
/// stdout line. Each object has a `type` discriminator (`system`, `assistant`,
/// `user`, `result`) and the agent UI renders these as user-friendly cards
/// rather than dumping raw JSON. Lines that don't parse or that we don't model
/// surface as `.unknown` so the UI can fall back to the raw transcript.
public enum ClaudeCodeStreamEvent: Sendable, Equatable {
    /// Initial handshake: the model that will run the session and the names of
    /// the MCP servers Claude Code successfully connected to.
    case sessionInit(model: String?, mcpServers: [String])
    /// A natural-language chunk from the assistant. Multiple text blocks can
    /// arrive across messages; the view appends them in order.
    case assistantText(String)
    /// The assistant requested a tool call. `inputSummary` is a single-line
    /// abbreviation suitable for a status row; the raw input is dropped to
    /// keep memory bounded for long sessions. `payload` carries structured
    /// data the host needs to observe (currently only `mcp__gargantua__clean`
    /// item IDs, used by the destructive-action detector to attach them to
    /// approval gates); nil for every other tool call.
    case toolUse(name: String, inputSummary: String, payload: ClaudeCodeToolUsePayload?)
    /// The MCP server returned a result for a previous `toolUse`.
    /// `summary` is a clipped preview of the response. `payload` carries
    /// structured data the host needs to mirror — currently only
    /// `mcp__gargantua__scan` responses (decoded from the top-level
    /// `tool_use_result.structuredContent` field, which Claude Code retains
    /// even when the inner text content is redacted to a saved-to-disk
    /// pointer for large payloads). Nil for everything else.
    case toolResult(toolUseID: String, isError: Bool, summary: String, payload: ClaudeCodeToolResultPayload?)
    /// Terminal event marking the end of a session.
    case terminal(ClaudeCodeStreamTerminalResult)
    /// A line we recognised as JSON but whose `type` we don't model.
    case unknown(type: String)
}

/// Structured payload extracted from a `tool_use` content block, when the
/// host recognises the tool by name. Currently only the gargantua MCP
/// `clean` request is parsed; everything else surfaces as `nil`.
public enum ClaudeCodeToolUsePayload: Sendable, Equatable {
    /// Item IDs the agent is requesting to clean via `mcp__gargantua__clean`.
    /// Used by `ClaudeCodeDestructiveActionDetector` to attach
    /// `proposedItemIDs` to the approval gate it raises, so the host can
    /// resolve them later against its scan-result mirror.
    case cleanRequest(itemIDs: [String])
}

/// Structured payload extracted from a `tool_use_result` block, when the
/// host recognises the originating tool by the response shape. Currently
/// only `mcp__gargantua__scan` responses are decoded; other tools surface
/// as `nil`.
public enum ClaudeCodeToolResultPayload: Sendable, Equatable {
    /// Wire-shape scan items from a `mcp__gargantua__scan` response.
    /// `MCPScanItem` is what Claude Code's `tool_use_result.structuredContent`
    /// carries verbatim; the consumer (host-side scan-result mirror)
    /// converts to `ScanResult` lazily, accepting the lossy size /
    /// missing-tags round-trip at that layer.
    case scanResults(items: [MCPScanItem])
}

/// Aggregated facts about a finished agent run, parsed from the `result`
/// stream-json line.
public struct ClaudeCodeStreamTerminalResult: Sendable, Equatable {
    /// `success`, `error_max_turns`, `error_during_execution`, or any future
    /// subtype the SDK adds. We compare against the well-known values via the
    /// `kind` helper rather than treating the string as exhaustive.
    public let subtype: String
    /// True for any non-success terminal state. Mirrors the SDK's `is_error`.
    public let isError: Bool
    /// Wall-clock duration of the session in milliseconds.
    public let durationMs: Int?
    /// Number of conversation turns Claude Code went through.
    public let numTurns: Int?
    /// Total billed cost in USD (only present when the SDK can compute it).
    public let totalCostUsd: Double?
    /// Final assistant message, when the SDK supplied one in the `result`
    /// field. Often present on success and empty on error subtypes.
    public let resultText: String?
    /// Free-form error strings the SDK attached to a non-success terminal.
    public let errors: [String]
    /// Model identifier extracted from the `modelUsage` map's first key.
    public let model: String?

    public init(
        subtype: String,
        isError: Bool,
        durationMs: Int?,
        numTurns: Int?,
        totalCostUsd: Double?,
        resultText: String?,
        errors: [String],
        model: String?
    ) {
        self.subtype = subtype
        self.isError = isError
        self.durationMs = durationMs
        self.numTurns = numTurns
        self.totalCostUsd = totalCostUsd
        self.resultText = resultText
        self.errors = errors
        self.model = model
    }

    /// Coarse classification used by the UI to pick error vs. success styling
    /// without hard-coding subtype strings everywhere.
    public enum Kind: Sendable, Equatable {
        case success
        case maxTurns
        case otherError
    }

    public var kind: Kind {
        if !isError { return .success }
        switch subtype {
        case "error_max_turns": return .maxTurns
        default: return .otherError
        }
    }
}

/// Stateless parser for Claude Code's `--output-format stream-json` output.
///
/// One line of stdout in → at most one structured event out. Lines that don't
/// JSON-parse return `nil`; lines whose `type` we don't model return
/// `.unknown` so callers can keep them in the raw transcript.
public struct ClaudeCodeStreamJSONParser: Sendable {
    /// Maximum characters retained for tool-input/result previews. Above this
    /// the string is truncated with an ellipsis. Picked so a typical scan
    /// payload fits on one row of the agent UI.
    public static let summaryLimit = 240

    public init() {}

    public func parse(line: String) -> ClaudeCodeStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        guard let type = obj["type"] as? String else { return nil }
        switch type {
        case "system":   return parseSystem(obj)
        case "assistant": return parseAssistant(obj)
        case "user":     return parseUserMessage(obj)
        case "result":   return parseResult(obj)
        default:         return .unknown(type: type)
        }
    }

    // MARK: - Per-type parsing

    private func parseSystem(_ obj: [String: Any]) -> ClaudeCodeStreamEvent? {
        // Only the init handshake is interesting to render. Other system
        // sub-events stay as .unknown so the UI surfaces them in the raw
        // disclosure if a user wants to see them.
        guard (obj["subtype"] as? String) == "init" else {
            return .unknown(type: "system")
        }
        let model = obj["model"] as? String
        var serverNames: [String] = []
        if let servers = obj["mcp_servers"] as? [[String: Any]] {
            serverNames = servers.compactMap { $0["name"] as? String }
        }
        return .sessionInit(model: model, mcpServers: serverNames)
    }

    private func parseAssistant(_ obj: [String: Any]) -> ClaudeCodeStreamEvent? {
        // Assistant messages may carry text or tool_use content blocks (or
        // both). We emit at most one event per call site and prefer tool_use
        // when present — the UI already shows assistant text inline above
        // tool calls, so emitting both would double-render the same line.
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }

        for block in content {
            if (block["type"] as? String) == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let inputSummary = Self.summarize(json: block["input"])
                let payload = Self.toolUsePayload(name: name, input: block["input"])
                return .toolUse(name: name, inputSummary: inputSummary, payload: payload)
            }
        }
        let texts: [String] = content.compactMap {
            ($0["type"] as? String) == "text" ? $0["text"] as? String : nil
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return .assistantText(joined)
    }

    private func parseUserMessage(_ obj: [String: Any]) -> ClaudeCodeStreamEvent? {
        // `user` events are mostly tool_result wrappers (the SDK frames tool
        // responses as a synthesised user message addressed back to the
        // assistant). Anything else we surface as .unknown.
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        for block in content where (block["type"] as? String) == "tool_result" {
            let id = block["tool_use_id"] as? String ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            let summary = Self.summarize(json: block["content"])
            // The structured payload lives at the TOP level of the line under
            // `tool_use_result.structuredContent` — not inside this content
            // block. Claude Code keeps it intact even when the inline text
            // gets redacted to a saved-to-disk pointer for oversized results.
            let payload = Self.toolResultPayload(topLevel: obj)
            return .toolResult(toolUseID: id, isError: isError, summary: summary, payload: payload)
        }
        return nil
    }

    private func parseResult(_ obj: [String: Any]) -> ClaudeCodeStreamEvent? {
        let subtype = obj["subtype"] as? String ?? "unknown"
        let isError = (obj["is_error"] as? Bool) ?? false
        let durationMs = obj["duration_ms"] as? Int
        let numTurns = obj["num_turns"] as? Int
        let totalCost = (obj["total_cost_usd"] as? Double)
            ?? (obj["total_cost_usd"] as? Int).map(Double.init)
        let resultText = (obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = (obj["errors"] as? [String]) ?? []
        // modelUsage is keyed by model id; surface the first key for display.
        let model: String? = {
            guard let usage = obj["modelUsage"] as? [String: Any] else { return nil }
            return usage.keys.sorted().first
        }()

        return .terminal(ClaudeCodeStreamTerminalResult(
            subtype: subtype,
            isError: isError,
            durationMs: durationMs,
            numTurns: numTurns,
            totalCostUsd: totalCost,
            resultText: (resultText?.isEmpty ?? true) ? nil : resultText,
            errors: errors,
            model: model
        ))
    }

    // MARK: - Helpers

    /// Extract a structured payload for tool calls the host needs to inspect.
    /// Returns nil for every tool we don't model — keeping memory bounded
    /// for long sessions where `Bash`/`Read`/`Grep` calls dominate.
    private static func toolUsePayload(name: String, input: Any?) -> ClaudeCodeToolUsePayload? {
        // Match the wire name exactly. The host only parses gargantua's own
        // `clean` tool; built-in Claude Code tools (Bash, Read, etc.) are
        // not destructive in a way the gate cares about.
        guard name == "mcp__gargantua__clean" else { return nil }
        guard let object = input as? [String: Any] else { return nil }
        // The MCP `clean` schema names the field `item_ids` (snake_case);
        // accept the camelCase variant defensively in case the agent or
        // a future schema migration uses it.
        let raw = object["item_ids"] ?? object["itemIDs"] ?? object["itemIds"]
        guard let array = raw as? [Any] else { return nil }
        let ids = array.compactMap { $0 as? String }
        guard !ids.isEmpty else { return nil }
        return .cleanRequest(itemIDs: ids)
    }

    /// Decode the structured response payload for a tool_result line. Looks
    /// at the top-level `tool_use_result.structuredContent` field that
    /// Claude Code surfaces alongside the message-content text. Currently
    /// recognises only the `MCPScanOutput` shape (presence of an `items`
    /// array of objects with id/path/safety keys); other tools — analyze,
    /// status, list_profiles, explain — could be added here as needed.
    private static func toolResultPayload(topLevel obj: [String: Any]) -> ClaudeCodeToolResultPayload? {
        guard let result = obj["tool_use_result"] as? [String: Any],
              let structured = result["structuredContent"] as? [String: Any]
        else { return nil }
        // Disambiguate from other tools that happen to use an `items` array
        // (none today, but defensively): require the per-item shape that
        // uniquely identifies a scan result.
        guard let items = structured["items"] as? [[String: Any]],
              !items.isEmpty,
              items.first?["id"] is String,
              items.first?["path"] is String,
              items.first?["safety"] is String
        else { return nil }
        let decoded = items.compactMap(decodeMCPScanItem(_:))
        guard !decoded.isEmpty else { return nil }
        return .scanResults(items: decoded)
    }

    /// Round-trip one wire-shape item through `JSONSerialization` and the
    /// `MCPScanItem` Codable so we get the same struct the host uses for
    /// its own MCP responses, with the same coding-key conventions
    /// (snake_case `last_accessed`). Returns nil when required fields are
    /// missing or types mismatch.
    private static func decodeMCPScanItem(_ raw: [String: Any]) -> MCPScanItem? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPScanItem.self, from: data)
    }

    /// Stringify an arbitrary JSON value into a single-line, length-capped
    /// preview suitable for a status row. Strings round-trip directly so we
    /// don't surround them with extra quotes; structured values get encoded as
    /// JSON for compactness.
    private static func summarize(json: Any?) -> String {
        let raw: String
        switch json {
        case let s as String:
            raw = s
        case .none:
            raw = ""
        default:
            if let value = json,
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                raw = text
            } else {
                raw = String(describing: json ?? "")
            }
        }
        let collapsed = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= summaryLimit {
            return collapsed
        }
        return String(collapsed.prefix(summaryLimit)) + "…"
    }
}
