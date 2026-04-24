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

## Rule Contributions

The easiest way to contribute today is by adding or refining YAML cleanup and uninstall rules. Rule-only collaboration belongs in the public [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules) repository; this app repository consumes reviewed snapshots from that repo.

- Public rule source: `https://github.com/inceptyon-labs/gargantua-rules`
- App-bundled cleanup snapshot: `Sources/GargantuaCore/Resources/cleanup_rules/`
- App-bundled uninstall snapshot: `Sources/GargantuaCore/Resources/uninstall_rules/`
- Rule docs and templates: `https://github.com/inceptyon-labs/gargantua-rules/tree/main/docs`

The bundled snapshot remains the app's runtime authority for safety classification. If you update rules in this app repo directly, include a sync note explaining whether the change should also land in `gargantua-rules`.

Before opening a PR for rules:

1. Open rule-only PRs against `inceptyon-labs/gargantua-rules`.
2. Pick the closest existing file and match its style.
3. Keep `safety` conservative when a path may contain user data.
4. Add enough explanation text that a reviewer can understand why the rule is safe, review, or protected.
5. Validate the rules locally with `Scripts/validate-rules.sh`.
6. If you add a new category, update the built-in profiles and category UI in the app snapshot.

## Validation

Run the focused rule checks before opening a PR:

```bash
Scripts/validate-rules.sh
```

You can scope the checks:

```bash
Scripts/validate-rules.sh cleanup
Scripts/validate-rules.sh uninstall
```

## Safety Guidelines

- Use `safe` only when the files are clearly disposable or trivially regenerated.
- Use `review` when files may contain user preferences, session state, local data, or sync metadata.
- Use `protected` when removing the file could affect system boot, launch services, daemons, or privileged components.

When in doubt, prefer `review`.

## Evidence We Like In Rule PRs

- App name and bundle ID
- Realistic path samples from a test machine
- Why the files regenerate, or why they should stay review-only
- Notes about app-specific risk, such as offline media, login state, or shared containers

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
