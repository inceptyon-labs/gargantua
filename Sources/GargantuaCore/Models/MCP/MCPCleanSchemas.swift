import Foundation

// MARK: - clean

/// Input for the MCP `clean` tool.
///
/// `confirm` is modeled as a non-optional constant `true`; decoding a payload
/// with `confirm: false` or a missing `confirm` key fails, enforcing the
/// PRD §7.4 guardrail at the type boundary rather than relying on the handler
/// to remember. `itemIDs` must be a non-empty array — an empty clean request
/// is treated as a malformed payload, not a successful no-op.
///
/// `method` is a plain `String` rather than a typed enum so the decode path
/// matches `MCPScanInput.profile`: the JSON Schema advertises the allowed
/// values, but the handler is the one that maps the string to a concrete
/// cleanup method and rejects anything outside `{"trash", "delete"}`.
public struct MCPCleanInput: Codable, Sendable, Equatable {
    public let itemIDs: [String]
    public let method: String
    public let confirm: Bool
    public let dryRun: Bool

    public init(
        itemIDs: [String],
        method: String = "trash",
        confirm: Bool = true,
        dryRun: Bool = false
    ) {
        self.itemIDs = itemIDs
        self.method = method
        self.confirm = confirm
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case method, confirm
        case itemIDs = "item_ids"
        case dryRun = "dry_run"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let itemIDs = try c.decode([String].self, forKey: .itemIDs)
        guard !itemIDs.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .itemIDs,
                in: c,
                debugDescription: "MCP clean.item_ids must be a non-empty array."
            )
        }
        self.itemIDs = itemIDs

        self.method = try c.decodeIfPresent(String.self, forKey: .method) ?? "trash"

        let raw = try c.decodeIfPresent(Bool.self, forKey: .confirm)
        guard raw == true else {
            throw DecodingError.dataCorruptedError(
                forKey: .confirm,
                in: c,
                debugDescription: "MCP clean.confirm must be present and true; MCP cannot bypass confirmation."
            )
        }
        self.confirm = true

        self.dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }
}

/// Per-item outcome in an `MCPCleanOutput.perItem` list.
///
/// `outcome` is one of "moved", "skipped", or "failed"; it is modeled as a
/// `String` to match the idiom used by `MCPScanItem.safety` and other Phase 2
/// output fields. Handlers map their internal enum to these strings on the way
/// out, and consumers inspect the string directly.
public struct MCPCleanItemResult: Codable, Sendable, Equatable {
    public let id: String
    public let outcome: String
    public let reason: String?
    public let bytesFreed: Int64?

    public init(
        id: String,
        outcome: String,
        reason: String? = nil,
        bytesFreed: Int64? = nil
    ) {
        self.id = id
        self.outcome = outcome
        self.reason = reason
        self.bytesFreed = bytesFreed
    }

    enum CodingKeys: String, CodingKey {
        case id, outcome, reason
        case bytesFreed = "bytes_freed"
    }
}

/// Output for the MCP `clean` tool.
///
/// `freed` is the human-readable formatted total (same idiom as
/// `MCPScanOutput.totalReclaimable`); consumers that need byte-accurate data
/// can sum `perItem[].bytesFreed`. `auditID` references the audit log entry
/// the handler writes on every clean invocation (success or failure) so
/// agents can link back to the trail for post-hoc inspection.
public struct MCPCleanOutput: Codable, Sendable, Equatable {
    public let cleaned: Int
    public let freed: String
    public let method: String
    public let auditID: String
    public let perItem: [MCPCleanItemResult]

    public init(
        cleaned: Int,
        freed: String,
        method: String,
        auditID: String,
        perItem: [MCPCleanItemResult]
    ) {
        self.cleaned = cleaned
        self.freed = freed
        self.method = method
        self.auditID = auditID
        self.perItem = perItem
    }

    enum CodingKeys: String, CodingKey {
        case cleaned, freed, method
        case auditID = "audit_id"
        case perItem = "per_item"
    }
}
