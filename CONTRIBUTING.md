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
