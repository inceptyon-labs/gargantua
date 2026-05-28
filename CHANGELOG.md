# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-05-27

### Added

- **Sparkle 2 auto-updates** with EdDSA-signed appcasts, signed-feed enforcement, and stable/beta channels (`Settings → About`).
- **Privileged helper** (`GargantuaPrivilegedHelper`) registered via SMAppService and reached over XPC, used for elevated-trust uninstall paths so the app never invokes `sudo`.
- **Scheduled scans** backed by a `GargantuaScheduler` LaunchAgent registered through SMAppService, with interval presets, a custom 5-field cron expression, profile selection, and skip-on-battery (`Settings → Automation`).
- **MCP SSE transport** alongside stdio: bind localhost or LAN, bearer-token auth in Keychain, generate/rotate/revoke from `Settings → Network`.
- **Claude Code Agent** integration for non-interactive maintenance runs with read-only-by-default tools, per-session destructive-tool grants, and configurable model/turn limits.
- **Local MLX inference** with a self-built `mlx.metallib` colocated in the app bundle, idle-unload after 60 s, model staging under `~/Library/Application Support/Gargantua/Models/`.
- **Cloud AI (Anthropic)** with Keychain-only key storage, per-request redaction, optional 4 KB content-preview consent, hard monthly spend cap, and a dynamic Anthropic model picker.
- **Disk Explorer** treemap and directory drill-down for visualizing reclaimable space before cleaning.
- **AI Models** profile and view for downloaded LLM/diffusion model storage, biased toward `review`.
- **AI model intelligence** for review-only duplicate model candidates and orphan `.gguf` / `.safetensors` / `.onnx` / PyTorch-family weights, using filename/size metadata without reading model contents.
- **File Health** scans (empty files, big files, similar images, broken symlinks) backed by a vendored `czkawka_cli`.
- **Duplicate Finder** backed by a vendored `fclones`, scoped to user-defined personal-scope roots.
- **Command-action rules** schema (`Resources/command_rules/`) with starter coverage for `xcrun simctl delete unavailable`, `pnpm store prune`, `go clean -cache`, and opt-in `go clean -modcache`; surfaced through scan + cleanup.
- **Stale-version discovery** for review-gated Xcode DeviceSupport and JetBrains Toolbox version sets, using keep-latest retention, current-version hints, and pinned-path exclusions before surfacing old versions.
- **App-pack remnant rules** for Docker, Xcode, Android Studio, JetBrains, VS Code/Cursor/Zed, Unity/Unreal/Godot, and Raycast.
- **`pkgutil` receipt evidence** in Smart Uninstaller and the MCP `explain` tool: shows pkg ID, version, and install date as ownership provenance, never as deletion permission.
- **Protected-roots policy** (`safety_policy/protected_roots.yaml`) hard-blocking cleanup at filesystem roots regardless of rule classification, with user-extendable but bundled-immutable entries.
- **Menu bar widget** with optional launch-at-login via `SMAppService.loginItem`.
- **Audit trail** at `~/Library/Logs/Gargantua/audit.json` for every MCP-triggered cleanup attempt, with retention configurable in `Settings → About`.
- **Release pipeline**: `Scripts/release.sh` orchestrates build → assemble → strip → codesign → notarize app → DMG → notarize DMG → `spctl --assess` → signed Sparkle appcast.
- **Local publish flow**: `Scripts/publish.sh` runs the release pipeline and then uploads the DMG + `appcast.xml` to a GitHub Release and pushes `Casks/gargantua.rb` to `inceptyon-labs/homebrew-tap`.
- **Vendored helpers** built from source via `Scripts/fetch-vendored-bins.sh` (`fclones`, `czkawka_cli`); installation verified by `Scripts/smoke/verify-vendored-bins.sh`.
- **CI**: SwiftLint + `swift test --enable-code-coverage` with a 40% floor enforced by `Scripts/coverage-priorities.sh` on `macos-15`.
- **Mole rule parity expansion**: app cleanup coverage for cloud-sync, Office/mail, communication, virtualization, creative/media, productivity, launcher, game, utility, and remote desktop caches; Smart Uninstaller remnant templates for WebKit, HTTP storage, app scripts, plug-ins, XDG config, app extensions, system-level paths, and protected receipts.

### Changed

- Developer Tools now prefers structured Docker `system df --format json` previews when available,
  falls back to the legacy table output, and explains unknown post-run byte estimates instead of borrowing unrelated totals.
- Protected Developer Tools operations now carry stronger risk copy and safety styling; Docker volume prune and Docker system prune
  route through full-modal acknowledgment with explicit data-loss wording.
- Reviewed snapshot now ships **51 cleanup files / 287 rules**, **2 generic + 7 app-pack remnant files / 28 + 63 rules**, and **4 command-action rules**. See `docs/mole-rule-parity-audit.md` for what's deferred.
- Advanced command-action cleanup now has an opt-in `Advanced Commands` profile plus parser validation that requires review safety, affected roots outside protected roots, explicit consequence copy, a bounded timeout, and restore guidance before bundled advanced YAML can load.
- Smart Uninstaller now evaluates curated `app_pack` rules before broad generic remnant rules so app-specific review/protected classifications win during path dedupe.
- Synced the reviewed Mole-expanded rule snapshot to the public `gargantua-rules` repository.

### Fixed

- `MCP explain` no longer advertises a top-level `oneOf` schema, which broke Anthropic API tool registration.
- `NSHumanReadableCopyright` in `Info.plist` corrected to AGPL-3.0 (was incorrectly labelled MIT).

## [0.1.0] - 2026-04-23

### Added

- Initial public release.
- YAML-driven cleanup and uninstall rules (19 cleanup files / 83 rules, 2 uninstall files / 12 rules).
- MCP server (`GargantuaMCP`) with Phase 2 read-only tools (`scan`, `analyze`, `status`, `explain`, `list_profiles`) and Phase 3 destructive `clean` tool protected by protected-path hard-reject, 60s-per-client rate limit, audit trail, and cancel-notification grace period.
- Privileged helper (`GargantuaPrivilegedHelper`) for operations requiring elevated trust.
- Local AI explainability via MLX Swift for rule explanations — AI can explain a rule's safety classification but cannot lower it.
