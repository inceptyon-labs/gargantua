---
# gargantua-7dlu
title: 'Task: MCP explain tool schema oneOf for path/item_id mutual exclusion'
status: in-progress
type: task
priority: normal
created_at: 2026-04-19T02:05:59Z
updated_at: 2026-04-20T00:55:09Z
parent: gargantua-qe4a
---

Close a schema-advertising gap flagged in the Codex Pass 2 review of `gargantua-o4ef` (WARNING #2).

## Problem

`MCPPhase2Tools.explain.inputSchema` advertises both `path` and `item_id` as optional properties with `required: []` and no exclusion constraint:

```swift
public static let explain = MCPToolDescriptor(
    name: .explain,
    description: "...",
    inputSchema: MCPJSONSchema(
        type: .object,
        description: "Provide either a filesystem path or an item id from a prior scan.",
        properties: ["path": ..., "item_id": ...],
        required: []
    )
)
```

Runtime `MCPExplainInput.init(from:)` correctly rejects both-nil or both-present with `-32602 invalidParams`, but a schema-driven MCP client reading `tools/list` sees both fields as optional and no constraint — so it can generate invalid calls that the server then rejects. The PRD `explain` contract (§7.3) is exactly-one-of, which should be advertised machine-readably.

## Scope

Extend `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift::MCPJSONSchema` to support `oneOf` (or `anyOf` with `not` — pick whichever has better MCP-client support; `oneOf` is the JSON Schema canonical). Update `MCPPhase2Tools.explain` to advertise the exactly-one-of constraint. Add a schema test that `explain` advertises the constraint correctly.

## Acceptance Criteria

- [ ] `MCPJSONSchema` supports a `oneOf: [MCPJSONSchema]?` field (or equivalent) that encodes/decodes cleanly via `JSONEncoder`/`JSONDecoder`.
- [ ] `MCPPhase2Tools.explain.inputSchema` advertises `oneOf: [{ required: ["path"] }, { required: ["item_id"] }]` (or equivalent shape that forbids both-nil and both-present).
- [ ] New schema test asserts the `tools/list` output for `explain` includes the constraint and rejects both the neither and the both cases at the schema level.
- [ ] Existing `MCPExplainInput` decode tests still pass (runtime validation remains the authoritative gate; schema is advertising).

## Non-goals

- Runtime change to `MCPExplainInput` decode (already correct).
- Extending other tool schemas — this is explicit to `explain`.

## Reference

- Codex Pass 2 review finding on `gargantua-o4ef` (WARNING #2).
- PRD §7.3 `explain` tool contract.
- Session handoff `docs/handoffs/handoff-2026-04-19-mcp-explain-list-profiles-handlers.md` — "Follow-Ups Carried Forward".
