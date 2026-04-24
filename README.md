<p align="center">
  <img src="AppShell/Brand/gargantua-logo-1024.png" width="160" alt="Gargantua">
</p>

<h1 align="center">Gargantua</h1>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black.svg?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-orange.svg?logo=swift" alt="Swift 5.10">
  <img src="https://img.shields.io/badge/MCP-compatible-6e40c9.svg" alt="MCP compatible">
</p>

Gargantua is a native macOS cleaner for developers and power users. It scans common cache, build-artifact, duplicate-file, and app-remnant locations, classifies findings by risk, explains why each item is considered safe or risky, and only removes files through explicit user-controlled flows.

The project is built as a Swift Package with three executables:

- `Gargantua`: the SwiftUI macOS app
- `GargantuaMCP`: a local Model Context Protocol server for automation-driven scans and guarded cleanups
- `GargantuaPrivilegedHelper`: an SMAppService/XPC helper for operations that require elevated trust

## Why Gargantua Exists

Most cleaner apps optimize for big numbers and vague confidence. Gargantua optimizes for traceability:

- Every finding comes from a rule, parser, or local scanner path that can be tested.
- Every result is classified as `safe`, `review`, or `protected`.
- Protected items are visible, but destructive paths reject them.
- Cleanup actions prefer Trash and write audit records for destructive workflows.
- Optional local explanations can summarize why a rule exists, but they cannot downgrade a safety classification.

## Features

- **Deep Clean:** YAML-driven scan rules for browser caches, app caches, system logs, temp files, Trash, installers, developer artifacts, Docker, Homebrew, and language build caches.
- **File Health:** duplicate, empty-file, big-file, similar-image, and broken-symlink scans through bundled helper binaries.
- **Smart Uninstaller:** app bundle inspection plus post-uninstall remnant detection for support files, launch agents, preferences, and related state.
- **Cleanup Profiles:** built-in and custom profiles that decide which rule categories run and which safety overrides apply.
- **Explainability:** per-item explanations sourced from rules, metadata, and optional local model inference.
- **Audit Trail:** MCP-triggered cleanup attempts are written to `~/Library/Logs/Gargantua/audit.json`.
- **Release Pipeline:** scripts for assembling, signing, notarizing, stapling, and packaging the app as a DMG.
- **Auto Updates:** Sparkle 2 appcasts with EdDSA signatures, signed-feed validation, and stable/beta channels.

## Safety Model

Gargantua's trust layer uses three safety levels:

| Level | Meaning | Default Behavior |
| --- | --- | --- |
| `safe` | Disposable files that are expected to regenerate or have no user-owned state. | Preselected in cleanup flows. |
| `review` | Files that may be removable, but could contain preferences, sync state, offline data, or context the user should inspect. | Shown, explained, not silently selected. |
| `protected` | Files with system impact, privilege implications, or high risk of data loss. | Visible for transparency; destructive flows hard-reject them. |

Rules live under `Sources/GargantuaCore/Resources/cleanup_rules/` and `Sources/GargantuaCore/Resources/uninstall_rules/`. The bundled rule snapshot is deterministic; Gargantua does not load mutable remote rules at runtime. The current reviewed snapshot includes 50 cleanup files / 274 cleanup rules and 2 uninstall files / 28 remnant rules; it is intentionally not a full Mole parity claim.

## MCP Server

`GargantuaMCP` exposes local tools for MCP clients over newline-delimited JSON-RPC 2.0 on stdin/stdout. It can also serve MCP over localhost Server-Sent Events on port `7493`. Logs go to stderr.

Run it locally:

```bash
swift run GargantuaMCP
```

Run the SSE transport only:

```bash
swift run GargantuaMCP -- --transport sse --port 7493 --bind localhost
```

Run both transports:

```bash
swift run GargantuaMCP -- --transport both
```

SSE binds to `127.0.0.1` by default. Binding to LAN uses `--bind lan` or the app's Settings -> MCP Transport pane and requires a bearer token stored in Keychain or supplied with `--token`. The SSE endpoint is:

```text
http://127.0.0.1:7493/sse
```

Example client entries:

```json
{
  "mcpServers": {
    "gargantua": {
      "command": "swift",
      "args": ["run", "GargantuaMCP", "--", "--stdio"]
    }
  }
}
```

```json
{
  "mcpServers": {
    "gargantua": {
      "url": "http://127.0.0.1:7493/sse"
    }
  }
}
```

For Claude Desktop, Cursor, or Claude Code, use the first shape when the client launches the server process and the second shape when the client connects to a separately running SSE server.

Read-only tools:

- `scan`: dry-run scan for reclaimable items
- `analyze`: health score, disk usage, and recommendations
- `status`: current system health metrics
- `explain`: explain a filesystem path or prior scan item
- `list_profiles`: list built-in and custom cleanup profiles

Destructive tool:

- `clean`: clean item IDs returned by a prior `scan`

`clean` is guarded by server-side checks:

- `confirm: true` is required.
- Unknown item IDs are rejected.
- Any `protected` item aborts the whole request.
- Each MCP client gets one clean operation per 60 seconds.
- Every non-dry-run attempt writes an audit entry with the client identifier.
- The app attempts a local notification with a short cancel window before files move.

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode 15 or newer with Swift 5.10
- Apple Silicon is the primary development and test target

Clone and build:

```bash
git clone https://github.com/inceptyon-labs/gargantua.git
cd gargantua
swift build
```

Run the app target:

```bash
swift run Gargantua
```

Run the MCP server:

```bash
swift run GargantuaMCP
```

Run tests:

```bash
swift test
```

For the local helper binaries and MLX shader setup used by the test/release scripts, prefer:

```bash
Scripts/test.sh
```

## Release Builds

The release pipeline is script-based and keeps `Package.swift` as the source of truth.

```bash
git tag v0.1.0
Scripts/release.sh
```

Release signing and notarization use local environment values from `.env.release`, which is intentionally ignored. See `Scripts/release/README.md` for the required variables and release flow.
The release flow also stages a signed Sparkle appcast under `dist/sparkle-updates/` for upload to the HTTPS location configured by `SPARKLE_FEED_URL`.

Useful supporting scripts:

- `Scripts/fetch-vendored-bins.sh`: refresh pinned helper binaries
- `Scripts/build-metallib.sh`: build the MLX Metal shader library used by local inference
- `Scripts/smoke/verify-vendored-bins.sh`: confirm an installed app resolves its bundled helpers
- `Scripts/smoke/privileged-helper.sh`: smoke-test privileged helper installation and status

## Rule Contributions

Rule authoring docs, schema notes, and templates live in the public [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules) repository:

- [Rule Schema](https://github.com/inceptyon-labs/gargantua-rules/blob/main/docs/schema.md)
- [Cleanup Rule Template](https://github.com/inceptyon-labs/gargantua-rules/blob/main/docs/templates/cleanup-rule.yaml)
- [Remnant Rule Template](https://github.com/inceptyon-labs/gargantua-rules/blob/main/docs/templates/remnant-rule.yaml)

Validate bundled rules before opening a rule PR:

```bash
Scripts/validate-rules.sh
```

Rule-only collaboration should happen in `gargantua-rules`. This app repository vendors reviewed snapshots so releases remain deterministic. Mole-backed additions should continue to land as reviewed, bounded batches rather than broad parity claims.

## Development Notes

After cloning, activate the versioned pre-commit hook if you plan to commit:

```bash
git config core.hooksPath .githooks
brew install gitleaks
```

The hook runs `gitleaks` against staged changes to reduce the chance of committing API keys or credentials.

The following are intentionally local-only and ignored by Git:

- task trackers and handoff archives
- local assistant instructions
- design-system scratch files
- release secrets and environment files
- downloaded local model files

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, PR expectations, and rule contribution guidance.

## Security

If you discover a security issue, especially anything involving the privileged helper, MCP guardrails, audit trails, or a path that could remove a `protected` item, please report it privately per [SECURITY.md](SECURITY.md). Do not open a public issue.

## License

Gargantua is licensed under the [GNU Affero General Public License v3.0](LICENSE).

YAML cleanup and uninstall rules under `Sources/GargantuaCore/Resources/` are sourced from the public [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules) repository; see that repo's license for rule-specific terms.
