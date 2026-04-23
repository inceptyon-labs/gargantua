# Gargantua

Gargantua is a native macOS cleaner focused on trust, explainability, and developer-heavy cleanup workflows.

The cleanup engine is driven by bundled YAML rules under `Sources/GargantuaCore/Resources/`. Those rules are the authoritative source for safety classification; AI can explain them, but it cannot lower a rule's safety level.

## Current Rule Inventory

- Cleanup rules: 19 files / 83 rules
- Uninstall remnant rules: 2 files / 12 rules

See [Community Rules](docs/rules/README.md) for authoring docs and [Rule Status](docs/rules/status.md) for current scope and known parity gaps.

## Repo Highlights

- [PRD](Gargantua-PRD-v5-FINAL.md)
- [Contributing](CONTRIBUTING.md)
- [Community Rules](docs/rules/README.md)
- [Rule Schema](docs/rules/schema.md)
- [Design Brief](docs/design-brief-app-shell.md)

## MCP Server

Gargantua ships an MCP (Model Context Protocol) server so agents like Claude Code can ask the app to scan for cleanable files, explain what it found, and — with opt-in guardrails — clean them.

The server is split into two surfaces:

- **Phase 2 (read-only):** `scan`, `analyze`, `status`, `explain`, `list_profiles`. Always available; safe to expose to any client.
- **Phase 3 (destructive):** `clean`. Only call with `item_ids` from a prior `scan`, `confirm: true`, and an initiated handshake.

Phase 3 safety guardrails (PRD §7.4), enforced by the server on every call:

- **Protected hard-reject.** Any item classified `protected` aborts the whole request; the server never removes a protected path over MCP.
- **Rate limit.** One clean operation per 60 seconds per client. Exceeding it returns `invalidParams` with a retry-after hint.
- **Audit trail.** Every attempted clean — success, failure, or user-cancelled — appends an entry to `~/Library/Logs/Gargantua/audit.json` tagged `transport: "mcp"` with the client identifier.
- **User notification.** Before any files move, macOS posts a local notification with a `Cancel` action. If the user taps Cancel within 5 seconds, the clean is short-circuited and the attempt is still audited (`bytes_freed: 0`). If they don't, the clean proceeds.

Client identification is read from the JSON-RPC `initialize` handshake's `clientInfo.name`. A client that skips `initialize`, sends a blank name, or re-initializes with a blank name is audited under the sentinel `"unknown"` and shares that bucket's rate-limit budget — it cannot bypass attribution by omitting its name.

Run the server standalone:

```bash
swift run GargantuaMCP
```

It reads newline-delimited JSON-RPC 2.0 on stdin and writes responses on stdout; log output goes to stderr.

## Validation

Run the focused rule checks:

```bash
Scripts/validate-rules.sh
```

Run the full test suite:

```bash
swift test
```
