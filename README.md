<p align="center">
  <img src="AppShell/Brand/gargantua-logo-1024.png" width="160" alt="Gargantua">
</p>

<h1 align="center">Gargantua</h1>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black.svg?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-orange.svg?logo=swift" alt="Swift 5.10">
  <a href="https://tenet-badges.jnew008538.workers.dev/projects/gargantua"><img src="https://tenet-badges.jnew008538.workers.dev/api/v1/badges/gargantua.svg" alt="Tenet score"></a>
  <img src="https://img.shields.io/badge/MCP-compatible-6e40c9.svg" alt="MCP compatible">
</p>

Gargantua is a native macOS cleaner for developers and power users. It scans common cache, build-artifact, duplicate-file, and app-remnant locations, classifies findings by risk, explains why each item is considered safe or risky, and only removes files through explicit user-controlled flows.

The project is built as a Swift Package with four executables:

- `Gargantua` — the SwiftUI macOS app
- `GargantuaMCP` — a local Model Context Protocol server for automation-driven scans and guarded cleanups
- `GargantuaScheduler` — a launchd-driven background runner used by Scheduled Scans
- `GargantuaPrivilegedHelper` — an SMAppService/XPC helper for operations that require elevated trust

## Install

```sh
brew tap inceptyon-labs/tap
brew install --cask gargantua
```

This pulls the signed, notarized DMG from the latest GitHub Release. Updates after install are delivered through the in-app Sparkle channel, so the cask only tracks `:latest`. Apple Silicon, macOS 14 (Sonoma) or newer.

## Why Gargantua Exists

Most cleaner apps optimize for big numbers and vague confidence. Gargantua optimizes for traceability:

- Every finding comes from a rule, parser, or local scanner path that can be tested.
- Every result is classified as `safe`, `review`, or `protected`.
- Protected items are visible, but destructive paths reject them.
- Cleanup actions prefer Trash and write audit records for destructive workflows.
- Optional local or cloud explanations can summarize why a rule exists, but they cannot downgrade a safety classification.

## Features

- **Deep Clean** — YAML-driven scan rules for browser caches, app caches, system logs, temp files, Trash, installers, developer artifacts, Docker, Homebrew, language build caches, and review-gated stale developer versions.
- **Dev Purge** — narrow-scope view limited to developer artifacts, Docker, Homebrew, and stale developer versions so a routine cleanup can't accidentally widen into a full scan.
- **Developer Tools** — tool-native Homebrew and Docker cleanup previews and run buttons, with Docker `system df` JSON parsing when available and full-modal acknowledgment for protected prunes.
- **Smart Uninstaller** — app bundle inspection plus post-uninstall remnant detection for support files, launch agents, preferences, and related state.
- **Duplicate Finder** — duplicate-group detection backed by `fclones`, scoped to user-defined personal-scope roots.
- **File Health** — empty-file, big-file, similar-image, and broken-symlink scans through bundled `czkawka` helpers.
- **Disk Explorer** — interactive treemap and directory drill-down for understanding where space goes before cleaning.
- **AI Models cleanup** — dedicated profile for downloaded LLM and diffusion model storage, biased toward `review` since re-downloading is expensive.
- **Cleanup Profiles** — built-in (`Developer`, `Light Cleanup`, `Deep Clean`, `Dev Purge`, `AI Models`) and custom profiles that decide which rule categories run and which safety overrides apply.
- **Explainability** — per-item explanations sourced from rules, metadata, and optional local or cloud model inference.
- **Scheduled Scans** — launchd-backed background scans with interval presets, custom cron expressions, profile selection, and skip-on-battery.
- **Menu Bar Widget** — glanceable status from the menu bar, optional launch-at-login.
- **MCP Server** — local Model Context Protocol server for automation-driven scans and guarded cleanups (see below).
- **Audit Trail** — MCP-triggered cleanup attempts are written to `~/Library/Logs/Gargantua/audit.json`.
- **Auto Updates** — Sparkle 2 appcasts with EdDSA signatures, signed-feed validation, and stable/beta channels.
- **Release Pipeline** — scripts for assembling, signing, notarizing, stapling, and packaging the app as a DMG.

## Safety Model

Gargantua's trust layer uses three safety levels:

| Level | Meaning | Default Behavior |
| --- | --- | --- |
| `safe` | Disposable files that are expected to regenerate or have no user-owned state. | Preselected in cleanup flows. |
| `review` | Files that may be removable, but could contain preferences, sync state, offline data, or context the user should inspect. | Shown, explained, not silently selected. |
| `protected` | Files with system impact, privilege implications, or high risk of data loss. | Visible for transparency; destructive flows hard-reject them. |

Rules live under `Sources/GargantuaCore/Resources/cleanup_rules/`, `Sources/GargantuaCore/Resources/uninstall_rules/`, and `Sources/GargantuaCore/Resources/command_rules/`. The bundled rule snapshot is deterministic; Gargantua does not load mutable remote rules at runtime. The reviewed snapshot ships five evidence shapes:

- **Path-based cleanup rules** — 51 files / 287 rules across apps, browsers, developer tools, and system locations.
- **Path-based remnant rules** — 2 generic files / 28 rules plus 5 app-pack files / 41 app-specific rules for Docker, Xcode, Android Studio, JetBrains, and VS Code/Cursor/Zed.
- **Command-action rules** — 3 developer-tool commands (`xcrun simctl delete unavailable`, `pnpm store prune`, `go clean -cache`) recorded with tool version, exit code, and arguments per run.
- **Code-native stale-version discovery** — Xcode DeviceSupport and JetBrains Toolbox version directories grouped by product/family/version with keep-latest, current-version, and pinned-path guards.
- **Dynamic `pkgutil` receipt evidence** — Smart Uninstaller surfaces ownership provenance (pkg ID, version, install date) for any package whose receipt matches an app being uninstalled. Receipts are evidence, not deletion permission; shared system paths upgrade to `protected`.

Trust Layer parity is *evidence-shape* parity, not Mole-shell line parity — every shape is explainable, bounded, reversible, and audited. Deferred Mole behaviors (`nix-collect-garbage`, `npm cache clean`, `go clean -modcache`, version-retention loops, receipt-driven deletion) are tracked in [`docs/mole-rule-parity-audit.md`](docs/mole-rule-parity-audit.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

A bundled **protected-roots policy** (`Sources/GargantuaCore/Resources/safety_policy/protected_roots.yaml`) hard-blocks cleanup at filesystem roots regardless of rule classification. It covers `/`, `/Applications`, `/Library`, `/System`, `/Users`, `~`, `~/Library`, `/private`, `/var`, `/var/folders/*/*/{C,T,X}`, and equivalents under `/System/Volumes/Data`. Users can add their own protected roots in Settings → Storage; bundled entries cannot be removed.

## Configuration

Everything below is configurable from **Settings**. Five tabs: AI · Automation · Network · Storage · About.

### AI (Settings → AI)

| Engine | Default | Network | Where keys/data live |
| --- | --- | --- | --- |
| **Template** | On | Local-only | None (rule-based, instant) |
| **Local MLX** | Off | Local-only after download | `~/Library/Application Support/Gargantua/Models/` |
| **Cloud (Anthropic)** | Off | `api.anthropic.com` over TLS | API key in macOS Keychain |
| **Claude Code Agent** | Off | Spawns local Claude Code CLI | Configuration in app prefs; CLI manages its own auth |

- **Template engine** — the default. Generates explanations directly from YAML rule metadata. No model required, no network.
- **Local MLX** — opt-in. Downloads `mlx-community/Llama-3.2-1B-Instruct-4bit` (~700 MB) to local storage. Runs on Apple Silicon via MLX. First explanation per session compiles Metal shaders. Idle engine unloads after 60 s.
- **Cloud AI (Anthropic)** — off by default. Requires a user-supplied Anthropic API key, stored only in macOS Keychain, never written to disk in plaintext. Sends file paths, sizes, classifications, and confidence scores. File content snippets (4 KB max, redacted for tokens and keys) are sent **only** with the explicit "Allow file-content previews" toggle. Configurable monthly spend cap (default $0; hard ceiling enforced client-side). Default model: `claude-sonnet-4-20250514`.
- **Claude Code Agent** — opt-in local agent runtime. Spawns the Claude Code CLI for non-interactive maintenance runs. **Tools are read-only by default**; destructive MCP tools must be explicitly granted per session. Configurable model, max turns, and scheduled-audit toggle.

In all engines: **AI can explain a classification but cannot lower it.** A `protected` finding remains `protected` regardless of what any model says.

### Storage (Settings → Storage)

- **Scan Roots** — where Dev Purge looks for build artifacts. Empty list uses sensible defaults; user-added roots must be absolute or `~/`-prefixed and cannot be `/` or `$HOME` directly.
- **Personal Scope** — folders the Duplicate Finder is allowed to traverse. Same path validation as scan roots. Seeded with sane defaults on first launch.
- **Exclusions (whitelist)** — paths or glob patterns Gargantua should never propose for cleanup. Persists across scans; entries can be removed individually.
- **Protected Roots** — bundled hard-protect list plus user-added entries. Bundled entries are read-only; user entries support `~/`, `${HOME}`, and absolute paths.

### Automation (Settings → Automation)

- **Scheduled scans** — launchd agent registered via SMAppService. Interval presets (hourly, daily, weekly) or a custom 5-field cron expression with validation. Selectable profile (default `Light`). Toggle to skip when on battery.
- **Menu bar widget** — glanceable status, optional.
- **Launch at login** — registered through `SMAppService.loginItem`.

### Network (Settings → Network)

- **MCP Transport** — toggle SSE transport, change bind (`localhost` or `lan`), set port, and manage the bearer token (generate, rotate, revoke). Token lives in Keychain.

### About (Settings → About)

- **Updates** — Sparkle feed host, last check, channel (`stable` / `beta`), automatic checks, automatic downloads.
- **Audit retention** — how long destructive-attempt audit entries are kept (default 90 days).

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

SSE binds to `127.0.0.1` by default. Binding to LAN uses `--bind lan` or the app's Settings → Network pane and **requires** a bearer token stored in Keychain or supplied with `--token`. The SSE endpoint is:

```text
http://127.0.0.1:7493/sse
```

### SSE TLS for LAN clients

`GargantuaMCP` serves SSE over plain HTTP. For LAN or remote clients, the supported TLS pattern is to keep Gargantua bound to localhost and terminate HTTPS in a reverse proxy on the same Mac:

```bash
swift run GargantuaMCP -- --transport sse --port 7493 --bind localhost
```

Then configure the proxy to listen on the LAN-facing interface with a certificate trusted by your client and forward to `127.0.0.1:7493`. Example Caddy route:

```caddyfile
gargantua.example.lan {
    reverse_proxy 127.0.0.1:7493
}
```

Clients connect to the HTTPS proxy endpoint:

```text
https://gargantua.example.lan/sse
```

If you choose `--bind lan`, treat it as an advanced trusted-network mode: Gargantua still requires a bearer token, but it does not terminate TLS itself. Put a TLS reverse proxy in front of the port before exposing it beyond the local machine.

### Client configuration

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

### Tools

Read-only (Phase 2):

- `scan` — dry-run scan for reclaimable items
- `analyze` — health score, disk usage, and recommendations
- `status` — current system health metrics
- `explain` — explain a filesystem path or prior scan item
- `list_profiles` — list built-in and custom cleanup profiles

Destructive (Phase 3):

- `clean` — clean item IDs returned by a prior `scan`

`clean` is guarded by server-side checks:

- `confirm: true` is required.
- Unknown item IDs are rejected.
- Any `protected` item aborts the whole request.
- Each MCP client gets one clean operation per 60 seconds.
- Every non-dry-run attempt writes an audit entry with the client identifier to `~/Library/Logs/Gargantua/audit.json`.
- The app attempts a local notification with a short cancel window before files move.

Phase 2 and Phase 3 tool registries are segregated in code so a Phase 2 consumer cannot accidentally advertise destructive tools — see [CONTRIBUTING.md](CONTRIBUTING.md#mcp-server-contributions).

## Security

Gargantua runs with elevated trust on a user's machine. Defenses are layered:

- **Trust layer** — every finding gets a `safe`/`review`/`protected` classification before any UI sees it. Destructive flows hard-reject `protected`.
- **Bundled protected roots** — `protected_roots.yaml` blocks cleanup at filesystem roots regardless of rule classification. Users can extend it but cannot remove bundled entries.
- **Privileged helper** — operations needing elevated trust are routed through `GargantuaPrivilegedHelper`, registered via SMAppService and reached over XPC. The app never calls `sudo` directly.
- **MCP guardrails** — bearer-token auth (Keychain-backed) for non-local binds, per-client rate limit, hard `protected` reject, audit log, cancel-notification grace period, and segregated Phase 2/Phase 3 tool registries.
- **Keychain-only secret storage** — Anthropic API key and MCP bearer token live in Keychain, never on disk in plaintext.
- **Cloud AI redaction** — outbound cloud requests strip apparent secrets and tokens from any included content. File contents are only sent with explicit per-config consent, capped at 4 KB per item, with hard monthly spend caps.
- **Hardened runtime + notarization** — release builds are signed with Developer ID, hardened runtime enabled, notarized, and stapled. Sparkle update artifacts are EdDSA-signed and feed-validated.
- **Pre-commit secret scanning** — versioned `.githooks/` with `gitleaks` blocks committed credentials. See [CONTRIBUTING.md](CONTRIBUTING.md#development-setup).
- **Dependency scanning** — `trivy fs` plus an OSV wrapper run against `Package.resolved` to flag CVEs in pinned SwiftPM dependencies.

If you discover a security issue — especially anything involving the privileged helper, MCP guardrails, audit trails, cloud-AI redaction, or a path that could remove a `protected` item — please report it privately per [SECURITY.md](SECURITY.md). Do not open a public issue.

## Build From Source

Requirements:

- macOS 14 (Sonoma) or newer; **macOS 15 + the latest stable Xcode is required** to resolve the `mlx-swift-lm` dependency, which declares `swift-tools-version: 6.1`.
- Apple Silicon is the only supported architecture for development and release builds.
- Xcode Command Line Tools (`xcode-select --install`) — provides `codesign`, `notarytool`, `stapler`, `iconutil`, `swift`.
- The Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) — `mlx-swift`'s `BuildMetallibPlugin` shells out to `xcrun metal` to compile shaders.

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

## Releasing

Releases are cut locally on a developer's Mac. The pipeline produces a signed, notarized, stapled DMG plus a signed Sparkle appcast, uploads both to a GitHub Release, and pushes a refreshed Cask to `inceptyon-labs/homebrew-tap`.

```bash
Scripts/release-interactive.sh
```

The interactive entry point shows the current version, prompts for the bump type (patch / minor / major / beta / custom), updates `CHANGELOG.md`, creates the git tag, runs the build + sign + notarize + upload + tap-push pipeline, and offers to push the tag at the end.

For non-interactive runs (you've already created the tag), use `Scripts/publish.sh` directly. Both are thin wrappers around `Scripts/release.sh`. The full one-time-setup checklist (Apple Developer ID cert, notarytool keychain profile, Sparkle EdDSA keypair, `gh` CLI, tap repo permissions) and per-release steps live in [`docs/RELEASING.md`](docs/RELEASING.md). Per-stage details for the build pipeline itself are in [`Scripts/release/README.md`](Scripts/release/README.md).

Useful supporting scripts:

- `Scripts/fetch-vendored-bins.sh` — refresh pinned helper binaries (`fclones`, `czkawka_cli`)
- `Scripts/build-metallib.sh` — build the MLX Metal shader library used by local inference
- `Scripts/smoke/verify-vendored-bins.sh` — confirm an installed app resolves its bundled helpers
- `Scripts/smoke/privileged-helper.sh` — smoke-test privileged helper installation and status

## Rule Contributions

Rules use a **two-repo model**: rule-only PRs (schema, new paths, refinements) go to the public [`inceptyon-labs/gargantua-rules`](https://github.com/inceptyon-labs/gargantua-rules) repository. This app repo vendors a reviewed, deterministic snapshot under `Sources/GargantuaCore/Resources/`, which is what ships at runtime — there is no live remote rule fetch.

The full flow (PR → review → snapshot sync → release), schema crib, classification guidance, evidence checklist, and local-testing steps are in [CONTRIBUTING.md](CONTRIBUTING.md#contributing-rules).

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

## Credits

Gargantua stands on a lot of open source.

**Rule research**

- [`tw93/Mole`](https://github.com/tw93/Mole) — many of the bundled cleanup paths (cloud, office, communication, virtualization, creative/media, productivity, launcher, game, remote desktop) were ported from Mole's shell-driven cleanup library and reviewed, classified, and rewritten as YAML rules with conservative safety classifications. See [`docs/mole-rule-parity-audit.md`](docs/mole-rule-parity-audit.md) for what's ported and what's deferred.

**Vendored helper binaries** (built from source via `Scripts/fetch-vendored-bins.sh`)

- [`pkolaczk/fclones`](https://github.com/pkolaczk/fclones) — backs the Duplicate Finder
- [`qarmin/czkawka`](https://github.com/qarmin/czkawka) — backs the File Health scans (empty files, big files, similar images, broken symlinks)

**Swift packages**

- [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) and the broader [MLX](https://github.com/ml-explore/mlx) project — local AI inference on Apple Silicon
- [`huggingface/swift-transformers`](https://github.com/huggingface/swift-transformers) — tokenizer for the local model
- The [`mlx-community/Llama-3.2-1B-Instruct-4bit`](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) MLX conversion of Meta's [Llama 3.2](https://www.llama.com/) — the optional local explanation model
- [`jpsim/Yams`](https://github.com/jpsim/Yams) — YAML parsing for the rule layer
- [`sparkle-project/Sparkle`](https://github.com/sparkle-project/Sparkle) — auto-update framework with EdDSA-signed appcasts

**Security and supply-chain tooling**

- [`gitleaks/gitleaks`](https://github.com/gitleaks/gitleaks) — pre-commit secret scanning
- [`aquasecurity/trivy`](https://github.com/aquasecurity/trivy) — `Package.resolved` CVE scanning
- [`google/osv-scanner`](https://github.com/google/osv-scanner) and the [OSV](https://osv.dev/) database — vulnerability checks against pinned SwiftPM revisions
- [`muter-mutation-testing/muter`](https://github.com/muter-mutation-testing/muter) — optional mutation testing for changed Swift files

If you ship a fork that adds dependencies, please update this list — credit is part of the contract.

## License

Gargantua is licensed under the [GNU Affero General Public License v3.0](LICENSE).

YAML cleanup and uninstall rules under `Sources/GargantuaCore/Resources/` are sourced from the public [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules) repository; see that repo's license for rule-specific terms.
