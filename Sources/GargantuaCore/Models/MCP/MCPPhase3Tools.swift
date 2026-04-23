import Foundation

// MARK: - Phase 3 Tool Registry

/// The Phase 3 tool registry — destructive tools that are never exposed via
/// Phase 2 code paths.
///
/// This registry is intentionally separate from `MCPPhase2Tools.all` so Phase
/// 2 server entry points cannot accidentally advertise the `clean` tool or
/// any future destructive capability. Phase 3 consumers opt in explicitly by
/// passing `MCPPhase3Tools.all` (or merging it with Phase 2's) when
/// constructing a dispatcher.
///
/// See PRD §7.3 for the tool contracts and §7.4 for the safety guardrails
/// every Phase 3 tool must respect: protected hard-reject, review confirm,
/// rate limit, audit entry with client identifier, user notification with a
/// cancel window. Most of those guardrails live in the handler layer; the
/// schema here only encodes what can be expressed declaratively (`confirm`
/// constant-true, `item_ids` required, `method` enum).
public enum MCPPhase3Tools {
    public static let all: [MCPToolDescriptor] = [clean]

    // MARK: clean

    /// `clean` executes cleanup on specified item IDs from a prior scan.
    ///
    /// Schema-level guardrails:
    /// - `item_ids` is required; the handler resolves each ID against the
    ///   scan-session cache and rejects unknowns.
    /// - `method` is constrained to `"trash" | "delete"`; the handler treats
    ///   a missing value as `"trash"` (MCP schema can't express defaults for
    ///   arbitrary string enums, so the default lives in `MCPCleanInput`).
    /// - `confirm` is required and pinned to the constant `true`. The
    ///   handler cannot be reached without an explicit affirmative from the
    ///   caller — this is enforced both by the schema advertising `const` and
    ///   by `MCPCleanInput`'s custom decoder.
    /// - `dry_run` is optional; when `true`, the handler returns the plan
    ///   without touching the filesystem.
    public static let clean = MCPToolDescriptor(
        name: .clean,
        description: "Clean specified items. Only accepts item IDs from a prior scan; moves to Trash by default. "
            + "Server rejects protected items and requires confirm:true for review items.",
        inputSchema: MCPJSONSchema(
            type: .object,
            description: "Inputs for the clean tool. confirm must be literal true; MCP cannot bypass confirmation.",
            properties: [
                "item_ids": MCPJSONSchema(
                    type: .array,
                    description: "Item IDs from a prior scan result. Must be non-empty.",
                    items: MCPJSONSchema(type: .string)
                ),
                "method": MCPJSONSchema(
                    type: .string,
                    description: "Cleanup method. Defaults to trash when absent.",
                    enumValues: ["trash", "delete"]
                ),
                "confirm": MCPJSONSchema(
                    type: .boolean,
                    description: "Must be true; MCP cannot bypass confirmation.",
                    const: .bool(true)
                ),
                "dry_run": MCPJSONSchema(
                    type: .boolean,
                    description: "If true, return the cleanup plan without touching the filesystem."
                ),
            ],
            required: ["item_ids", "confirm"]
        )
    )
}
