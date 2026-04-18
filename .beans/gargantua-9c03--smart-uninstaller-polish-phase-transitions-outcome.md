---
# gargantua-9c03
title: 'Smart Uninstaller polish: phase transitions + outcome-coherent summary heading'
status: completed
type: task
priority: normal
created_at: 2026-04-18T12:45:39Z
updated_at: 2026-04-18T12:48:11Z
---

Follow-up polish on the Smart Uninstaller surface.

## Problem 1: jarring phase transitions

`SmartUninstallerView.body` switches between picker / console / review / summary / error views inside a `Group`. No `.transition` or `withAnimation`, so screens pop instead of crossfade. Confirmation modal already fades (`.transition(.opacity)`); the phase switch itself doesn't.

## Problem 2: heading contradicts message on total failure

`summaryState` always renders 'SIGNAL RECOVERED' as the heading, even when `SingularityCloseMessage.line(for:)` returns 'Signal lost. All artifacts still bound.' Screenshot from 2026-04-18 shows both on screen at once when a root-owned /Applications/*.app fails to uninstall. Heading needs to key off the same outcome bucket the close message uses.

## Acceptance

- [x] Phase transitions crossfade (or similar non-jarring motion) with reduceMotion respected
- [x] Summary heading matches outcome: SIGNAL RECOVERED (success), PARTIAL TRANSFER (partial), SIGNAL LOST (total failure)
- [x] Close message text unchanged (already outcome-aware)
- [x] Tests for the heading selector mirror the close-message outcome tests

## Summary of Changes

- `SmartUninstallerView`: wrapped the phase switch in `.animation(_, value: phaseKey)` with per-branch `.transition(phaseTransition)`. `phaseKey` is a stable bucket string so associated-value changes on `.scanning(app)` don`t trigger a crossfade. `phaseTransition` collapses to `.identity` under `accessibilityReduceMotion`.
- `SingularityCloseMessage.heading(for:)` added alongside `line(for:)`: returns SIGNAL RECOVERED / PARTIAL TRANSFER / SIGNAL LOST keyed off the same outcome bucket as the close line. Summary heading color also shifts to `protected_` red on total-failure so the header visually matches the message.
- Tests: 2 new tests in `SpaghettifyModifierTests` guard the invariant that heading and line never contradict each other (the bug visible in the 2026-04-18 screenshot).
- 450/450 tests passing. swiftlint clean on changed files. Build clean.

Permission-denied root cause (root-owned `/Applications/*.app`) is out of scope for this polish bean — tracked separately under **gargantua-h0ny** (SMAppService privileged helper, feature, draft status).
