# Rule Status

This document tracks the current implemented rule database in the repo.

## Current Bundled Scope

### Cleanup rules

- 19 YAML files
- 83 cleanup rules

Coverage currently includes:

- Browser: Chrome, Safari, Firefox, Arc, Brave
- Apps: Slack, Spotify, Dropbox
- Developer: Xcode, Node, Homebrew, Docker, Python, Rust, Go
- System: caches, logs, temp files, trash, installers

### Uninstall remnant rules

- 2 YAML files
- 12 remnant rules

Files:

- `Sources/GargantuaCore/Resources/uninstall_rules/remnant_locations.yaml`
- `Sources/GargantuaCore/Resources/uninstall_rules/launch_agents.yaml`

## Validation Surface

The rule database is validated by:

- `Tests/GargantuaCoreTests/Parsing/RuleSetIntegrationTests.swift`
- `Tests/GargantuaCoreTests/Parsing/RemnantRuleParserTests.swift`
- `Tests/GargantuaCoreTests/Parsing/RemnantRuleSetIntegrationTests.swift`
- `Tests/GargantuaCoreTests/Models/CleanupProfileTests.swift`

The contributor entrypoint is:

```bash
Scripts/validate-rules.sh
```

## What This Does Mean

- Gargantua ships a native YAML-driven cleanup engine.
- The PRD's named example cleanup families are now represented in the repo.
- Community contributors have a documented path to add and validate rule changes.

## What This Does Not Mean Yet

- Full historical Mole database parity is not proven.
- The PRD's note about `remnant_locations.yaml` carrying `52+ locations from Mole` is not satisfied yet.
- There is no direct Mole-to-Gargantua parity harness in the repo because `mo` was intentionally removed from the runtime architecture.

## Public Rules Repository

The public rules repository is [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules).

This app repository keeps the reviewed runtime snapshot under `Sources/GargantuaCore/Resources/`. The public repository is the intended source for rule-only contribution, schema documentation, templates, and standalone validation. App releases should import reviewed snapshots from that repo rather than loading mutable remote rules at runtime.

As of the 2026-04-23 local verification pass, the public repository exists but still needs its initial branch contents, MIT license, and validation CI before it is fully self-serve for external contributors.

The planned public repo starter kit should include:

- versioned schema docs
- standalone validation CI
- rule-only PR workflow
- release cadence decoupled from app releases
