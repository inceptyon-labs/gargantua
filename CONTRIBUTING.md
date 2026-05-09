# Contributing

Thanks for helping improve Gargantua.

## Development Setup

After cloning, activate the versioned git hooks so gitleaks runs on every commit:

```bash
git config core.hooksPath .githooks
```

This is a one-time, per-clone step — the hook config lives in `.git/config`, which isn't versioned, so each fresh clone needs it. Install the binary too:

```bash
brew install gitleaks   # macOS
# or grab a release from https://github.com/gitleaks/gitleaks/releases
```

The hook blocks commits that contain secrets matched by `.gitleaks.toml`. If you hit a false positive, add an entry under `[allowlist]` in that file rather than bypassing with `--no-verify`.

## Contributing Rules

Adding or refining YAML cleanup and uninstall rules is the easiest way to contribute. The contribution model uses two repositories on purpose:

| Repo | Role |
| --- | --- |
| [`inceptyon-labs/gargantua-rules`](https://github.com/inceptyon-labs/gargantua-rules) | **Source of truth.** Schema, templates, in-flight rules, rule-only PRs and discussion. |
| `inceptyon-labs/gargantua` (this repo) | **Runtime authority.** Vendors a reviewed, deterministic snapshot under `Sources/GargantuaCore/Resources/`. The shipping app loads only this snapshot — there is no live remote rule fetch. |

### End-to-end flow

1. Open a rule-only PR against [`gargantua-rules`](https://github.com/inceptyon-labs/gargantua-rules) using the [Cleanup](https://github.com/inceptyon-labs/gargantua-rules/blob/main/docs/templates/cleanup-rule.yaml) or [Remnant](https://github.com/inceptyon-labs/gargantua-rules/blob/main/docs/templates/remnant-rule.yaml) template.
2. A maintainer reviews schema + safety classification.
3. After merge in `gargantua-rules`, the rules are synced into this repo's snapshot under `Sources/GargantuaCore/Resources/cleanup_rules/` or `uninstall_rules/` as a reviewed, batched update.
4. The next Gargantua release ships the updated snapshot. The app does not load mutable remote rules at runtime.

If you must change rules directly in this repo (e.g., a release-blocking fix), include a sync note in the PR explaining whether the change should backflow to `gargantua-rules`.

### Schema crib

Full schema and templates live at [gargantua-rules/docs](https://github.com/inceptyon-labs/gargantua-rules/tree/main/docs). The required fields for a cleanup rule:

```yaml
- id: spotify.cache                       # globally unique within the file
  name: Spotify cache                     # human-readable label
  category: app_cache                     # see categories list below
  paths:
    - "~/Library/Caches/com.spotify.client"
  safety: safe                            # safe | review | protected
  regenerates: true                       # does the app rebuild this on next launch?
  regenerate_command: null                # optional shell hint for the user
  explanation: |
    Spotify regenerates this cache on next launch. Login state, downloads,
    and playlists live elsewhere and are not touched.
```

Active categories are: `browser_cache`, `browser_data`, `system_cache`, `system_logs`, `temp_files`, `trash`, `app_cache`, `app_data`, `dev_artifacts`, `docker`, `homebrew`, `installers`, `similar_images`, `empty_files`, `broken_symlinks`, `ai_models`. Adding a new category is allowed but requires a matching update to the built-in profiles in `Sources/GargantuaCore/Models/CleanupProfile.swift` and the category UI.

### Safety classification

- `safe` — files are clearly disposable or trivially regenerated.
- `review` — files may contain user preferences, session state, offline data, or sync metadata.
- `protected` — removing the file could affect system boot, launch services, daemons, or privileged components.

When in doubt, prefer `review`. Destructive flows in the app and in MCP `clean` hard-reject `protected` regardless of any AI-generated explanation.

### Evidence we like in rule PRs

- App name and bundle ID
- Realistic path samples captured on a test machine
- Why the files regenerate, or why they should stay `review`-only
- Notes about app-specific risk, such as offline media, login state, sync databases, or shared containers
- For Mole-derived paths: what was deliberately deferred (command execution, active-file checks, current-version retention, receipt expansion, external-volume policy)

### Validate locally

Before opening the PR, validate against the bundled schema check and lint:

```bash
Scripts/validate-rules.sh                 # all rules
Scripts/validate-rules.sh cleanup         # cleanup rules only
Scripts/validate-rules.sh uninstall       # remnant rules only
```

To see how a rule behaves end-to-end, drop the file into the appropriate snapshot directory in your local clone, then run the app or scan from MCP:

```bash
# Cleanup rules
cp my-app.yaml Sources/GargantuaCore/Resources/cleanup_rules/apps/

# Remnant rules
# extend Sources/GargantuaCore/Resources/uninstall_rules/remnant_locations.yaml

swift run Gargantua          # exercise via the GUI
swift run GargantuaMCP       # or scan via MCP for a structured dry-run
```

Mole parity status and the inventory of deferred items live in [`docs/mole-rule-parity-audit.md`](docs/mole-rule-parity-audit.md). Use it as the reference for what's intentionally not yet ported.

### Receipt evidence (pkgutil)

A third evidence shape covers files that aren't expressible as a single YAML path: installer-placed files discovered by reading the installer's own bill-of-materials. Smart Uninstaller asks `pkgutil` which packages a target app plausibly owns, expands each receipt's BOM, and surfaces the candidates alongside YAML-rule remnants.

The model rests on one rule:

> **Receipts are evidence, not permission.**

A receipt tells us *some package* claimed to install a file. It does not tell us the file is safe to remove, that it isn't shared with another still-installed app, that the user hasn't replaced it, or that the package id is even the right owner. Every BOM-derived path therefore runs through the same safety classifier as YAML-rule output before it can become an action.

#### Match heuristic

`PackageMatcher` filters the full receipt database (`pkgutil --pkgs`) down to candidates plausibly owned by an app, in priority order:

1. **Exact bundle ID** — the receipt's package id equals the app's `bundleID`.
2. **Bundle prefix** — the receipt id is `<bundleID>.<suffix>` (e.g., `com.docker.docker.helper`).
3. **Reverse-DNS prefix** — the receipt id shares the bundle's first two components (e.g., any `com.docker.*`). Only applied when the prefix is at least two components long, so single-segment ids like `com` never widen.
4. **App-name slug** — the receipt id contains a sanitized app-name slug (lowercase, alphanumerics only, ≥3 chars), bounded by `.`, `-`, `_`, or string ends. The component-delimiter check stops `Bar` from matching `barista`, and the length floor stops `Go` from matching `golang`.

Slug matching deliberately overshoots a bit — same-vendor sibling apps (Photoshop ↔ Illustrator) will pull each other's receipts in. That's fine because the Trust Layer below catches any false-positive surface area before it becomes destructive.

#### System-prefix block list

System and platform-managed packages are blocked before any matching:

| Prefix | Why |
| --- | --- |
| `com.apple.*` | Apple-owned receipts; expanding them risks proposing system file removal. |
| `com.macports.*` | MacPorts manages its own uninstall flow. |

These are filtered inside `PackageMatcher.matches(...)` — extending the list means editing `PackageMatcher.blockedSystemPrefixes`. New entries should describe a package family that ships from a non-app source (system installer, package manager) where receipt-driven removal would be unsafe or duplicative of the source's own tooling.

#### Trust Layer classification

`ReceiptRemnantBuilder` runs each candidate through these gates in order:

1. **Path existence** — non-existent paths are dropped silently. Stale receipts (e.g., upgraded packages that moved files) leave entries pointing at paths that no longer exist; we never propose removing what isn't there.
2. **Protected-root policy** — paths matching `protected_roots.yaml` are dropped. A BOM that lists a protected root is a receipt-internal misclassification, not permission to operate on the directory.
3. **Shared-system path upgrade** — paths under `/Library/LaunchDaemons/`, `/Library/Frameworks/`, `/Library/PrivilegedHelperTools/`, `/Library/Extensions/`, or `/System/` upgrade from `.review` to `.protected_`, regardless of which receipt claims them. Cross-app shared infrastructure is not actionable from a single app's uninstall flow.
4. **Default to `.review`, never `.safe`** — receipt-derived rows are always at minimum `.review` confirmation; the Trust Layer keeps the user in the loop. There is no way for a BOM-only path to reach `.safe`.

#### Dedup against YAML rules

When the same path appears in both a YAML remnant rule and a `pkgutil` BOM, the YAML rule wins. The scanner emits rule-derived rows first, populates `seenPaths` as it goes, and `ReceiptRemnantBuilder` skips any candidate already in `seenPaths`. Net effect: a curated rule's classification (including its `safety` and `confidence`) is preserved; the receipt is treated as supporting context, not a parallel claim. Within the receipt pass, identical paths claimed by two sibling receipts also dedupe to a single row — first receipt processed wins the provenance.

#### Provenance on every row

Every receipt-derived `RemnantItem` carries:

- `ruleID` of the form `pkgutil-bom:<pkgID>` — distinguishes BOM-evidence from rule-evidence at a glance in audit logs.
- `tags` includes `pkgutil-bom` — UI/MCP can filter for receipt rows.
- `explanation` like `"Owned by package com.docker.docker (v4.30.0) installed 2025-12-04. Receipt evidence — review before removal."` — surfaces the receipt's package id, version, and install date so the user (and any downstream MCP consumer) can see exactly which installer placed the file.

When a sibling-app receipt over-matches (Adobe Photoshop's uninstall pulls in `com.adobe.illustrator` paths via the rev-DNS prefix), the `ruleID` and `explanation` still point at the *real* owning package — making the cross-app source visible instead of hiding it under the target app's bundle id.

#### Adding new receipt-aware behavior

Most contributors won't need to touch the receipt pipeline directly — it's a parallel scan source, not a per-rule extension point. If you do:

- New system-package prefix to block: extend `PackageMatcher.blockedSystemPrefixes` with a one-line comment explaining the family.
- New shared-system path that should upgrade to `.protected_`: extend `ReceiptRemnantBuilder.protectedSharedPathPrefixes`.
- New evidence to surface in audit / explain: keep encoding it in `RemnantItem.explanation` and `tags` rather than expanding `ScanResult` — the JSON schema for MCP and audit consumers is intentionally stable.
- Cross-app cases: see `Tests/GargantuaCoreTests/Services/CrossAppSharedReceiptTests.swift` for the canonical Adobe Creative Cloud and Microsoft Office shapes — sibling-vendor reverse-DNS over-match, shared system daemons, shared user-library caches, and YAML-vs-receipt precedence.

### Command-action rules

A second rule kind covers cleanup that can't be expressed as filesystem paths — operations where Gargantua asks an external tool to clean its own data. These ship as YAML under `Sources/GargantuaCore/Resources/command_rules/` and are loaded by `CommandActionRuleLoader`. They're audited as `kind: command` entries (separate from path entries) and run through `CommandActionExecutor`.

A complete command-action rule:

```yaml
- id: simctl_delete_unavailable                # unique within the file
  name: Xcode Simulator (orphaned runtimes)
  tool: xcrun                                  # resolver key, see candidate map below
  arguments:
    - simctl
    - delete
    - unavailable
  dry_run_arguments:                           # optional; gates effective safety
    - simctl
    - list
    - --json
  safety: safe                                 # safe | review (protected is rejected at parse)
  confidence: 95
  category: developer_tool_command
  regenerates: true
  regenerate_command: "Xcode → Settings → Components"
  affected_roots:                              # required; cross-checked vs protected_roots
    - "~/Library/Developer/CoreSimulator/Devices"
  preconditions:
    timeout_seconds: 120                       # bounded wall-clock cap
  source:
    name: Xcode
    bundle_id: com.apple.dt.Xcode
  explanation: |
    Removes simulator runtimes Xcode has marked as unavailable. Xcode owns
    this data and re-downloads it on demand from Settings → Components.
```

Bundled tool keys: `xcrun`, `pnpm`, `go`, `brew`, `docker`. Adding a new tool means extending `CommandActionToolResolver.defaultCandidates` with its standard install paths. For ad-hoc resolution (tests, custom installs), set `GARGANTUA_TOOL_<UPPERCASE_NAME>` to an absolute executable path.

Trust Layer rules specific to command-action rules:

- **`protected` is rejected at parse time.** Command-action rules describe tool invocations, not filesystem deletions; the `protected` floor only applies to path rules. Rules whose impact is unsafe enough to need `protected` semantics belong as path rules with explicit affected paths.
- **No dry-run means `review`.** When `dry_run_arguments` is omitted (or the dry-run runs but the bytes-reclaimable estimator returns nil), the *effective* safety used in the cleanup confirmation flow is downgraded to `review` regardless of the YAML's declared safety. The user is asked to confirm via the summary dialog, not the single-button path.
- **`affected_roots` is required and conservative.** Declare every root the command may touch up front so the cleanup pipeline can reject rules whose roots intersect the bundled `protected_roots.yaml` policy.
- **Audit evidence is verbose by design.** Every successful run writes an entry with the exact tool version (`<tool> --version`), the literal argument list, the exit code, and a `kind: command` discriminator so audit consumers can tell at a glance which evidence model produced the entry.

### Code-native scan adapters

Some cleanup evidence cannot be modeled honestly in YAML. Version-retention loops are the first example: a directory is not removable just because its name sorts older than another directory. These live in Swift scan adapters such as `StaleVersionScanAdapter`, not in `cleanup_rules/`.

Rules for adding a code-native adapter:

- Keep candidates grouped by product/family/version so the UI can explain what was kept and why.
- Default to `review` unless ownership, current version, and restore path are explicit.
- Support keep-latest-N and a user pin/exclusion path before surfacing a candidate.
- Route results as ordinary `ScanResult` rows so existing confirmation, protected-root checks, cleanup, and audit flows stay in control.
- Add focused tests for version parsing, retention decisions, pins/current-version guards, and profile category gating.

## Code Validation

For code changes, run Swift tests with coverage and inspect the lowest-covered
service/model files before adding broad new surface area:

```bash
swift test --enable-code-coverage

test_binary=".build/debug/GargantuaPackageTests.xctest/Contents/MacOS/GargantuaPackageTests"
xcrun llvm-cov export \
  -format=lcov \
  "$test_binary" \
  -instr-profile .build/debug/codecov/default.profdata \
  -ignore-filename-regex='.build|Tests' > coverage.lcov

Scripts/coverage-priorities.sh coverage.lcov --limit 20 --min-lines 20
```

Prioritize low-covered files under `Sources/GargantuaCore/Services/` and
`Sources/GargantuaCore/Models/`, especially safety, cleanup, permission,
signature, and agent lifecycle paths. CI reports these priorities but does not
fail on a coverage percentage yet. Once the team agrees on a baseline that the
suite reliably exceeds, enable the same script as a gate with `--fail-under`.

Dependency scanning uses Trivy for SwiftPM lockfile CVEs and an OSV wrapper for
OSV-backed checks against the pinned Git revisions in `Package.resolved`:

```bash
trivy fs --config trivy.yaml .
Scripts/osv-spm-scan.sh -- --all-packages
```

### Mutation Testing (optional)

Mutation testing complements line coverage by checking whether tests
actually catch behaviour changes in the code they exercise. It is
**opt-in** and not part of `swift test` or the default CI.

Install [Muter](https://github.com/muter-mutation-testing/muter):

```bash
brew install muter-mutation-testing/formulae/muter
muter --version
```

Run mutation testing on Swift files changed against `origin/main`:

```bash
Scripts/run-mutation.sh
```

Other useful invocations:

```bash
Scripts/run-mutation.sh --base HEAD~1                  # diff against last commit
Scripts/run-mutation.sh --files Sources/.../Foo.swift  # explicit single-file run
Scripts/run-mutation.sh --all                          # full mutation pass (slow)
```

The script writes a Tenet-compatible JSON report to:

```text
.healthcheck/mutation/muter.json
```

If no Swift sources changed in scope, the script writes a small skip
marker JSON to that same path and exits 0 — Tenet ingestion stays happy
without misreporting a zero score. The Muter config (`muter.conf.yml`)
points the test runner at `Scripts/test.sh` so MLX metallib staging works
inside Muter's sandbox; if you change the test command there, mirror the
change in the wrapper.

CI runs mutation testing only when:

- the workflow is dispatched manually from the **Actions** tab, **or**
- a PR carries the `mutation-test` label.

See `.github/workflows/mutation.yml`.

## MCP Server Contributions

The MCP server code lives in two places:

- `Sources/GargantuaMCP/main.swift` — the CLI entry point that wires transport, dispatcher, and handlers.
- `Sources/GargantuaCore/Services/MCP/` — handlers, session cache, rate limiter, notification service, and the request dispatcher.

Tool descriptors are registered through two segregated registries:

- `MCPPhase2Tools` — read-only tools. Exposed by default.
- `MCPPhase3Tools` — destructive tools. Phase 2 code paths must never advertise them. A Phase 3 consumer opts in explicitly by passing `MCPPhase3Tools.all` (or `MCPPhase2Tools.all + MCPPhase3Tools.all`) to the dispatcher.

When adding a new tool:

- If it only reads state, register it in `MCPPhase2Tools`.
- If it can modify disk, network, or any other persistent state, register it in `MCPPhase3Tools` and plug it into the same guardrails the `clean` tool uses (audit writer, shared `MCPRateLimiter`, client identifier provider, user notification service).
- Never merge the two registries inside `GargantuaCore` — keeping them separate means no accidental Phase 3 exposure through a Phase 2 consumer.

Integration coverage pattern: see `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationTests.swift` for the pipe-backed stdio harness. Reuse it when adding destructive tools so the full transport + dispatch + guardrail chain is exercised, not just the handler.
