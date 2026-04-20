---
# gargantua-t9em
title: 'File Health: czkawka 9+ subcommand rename + exit-11 success code'
status: in-progress
type: bug
priority: high
created_at: 2026-04-20T22:47:04Z
updated_at: 2026-04-20T22:47:04Z
---

File Health scan surfaces "czkawka_cli <command> exit 11" for every subcommand and "unrecognized subcommand 'temporary'" for the temp-files column. Two root causes:

1. **Subcommand rename**: czkawka 9+ renamed `temporary` → `temp`. The vendored binary (11.0.1) rejects the old name with a clap exit 2. `CzkawkaOutputParser.swift:23` had `case .temporaryFiles: "temporary"`.

2. **Exit-code semantics drift**: czkawka 9+ emits exit code 11 to signal "scan completed, findings produced". `CzkawkaAdapter.swift` treated any non-zero exit as a subcommand failure and surfaced it as an error, causing every column that actually found something to come back empty and produce the "File Health scan unavailable" page.

## Repro

```
./Sources/GargantuaCore/Resources/bin/czkawka_cli empty-files -d "$HOME"
# → 44k lines of paths on stdout, empty stderr, exit 11
```

## Fix

- Rename subcommand value `temporary` → `temp` in `CzkawkaOutputParser.CzkawkaCategory.subcommand`.
- Accept `exitCode == 0 || exitCode == 11` in `CzkawkaAdapter.swift` as scan success.
- Test: exit 11 parses output and records no error.
- Test: existing `temporary` stubbed-output test updated to stub `temp`.

## Acceptance

- [x] `temp` subcommand is used on czkawka 9+
- [x] Exit 11 is treated as success; output is parsed
- [x] Regression test covers exit-11 success path
