---
# gargantua-7xh2
title: 'Task: Thread active profile into Deep Clean'
status: completed
type: task
priority: normal
created_at: 2026-04-17T18:07:17Z
updated_at: 2026-04-17T22:18:00Z
parent: gargantua-lupo
---

DeepCleanView currently defaults to `.deep` from MainContentView. Wire persisted active profile selection into Deep Clean where appropriate so PRD cleanup-profile UX is honored consistently.

Acceptance criteria:
- MainContentView resolves active profile from PersistenceController settings
- DeepCleanView receives the active profile or a documented Deep-specific override
- Behavior is covered by focused tests or a clear smoke note
- Existing `.deep` default remains safe when persistence is unavailable



## Summary of Changes

Wired the persisted active profile into Deep Clean so MainContentView no longer hardcodes `.deep`.

**Files changed**
- `Sources/GargantuaCore/Models/CleanupProfile.swift` — added `CleanupProfile.resolve(activeProfileID:persisted:fallback:)` pure helper; searches persisted profiles first (user overrides win), then all built-ins including `.devPurge`, then falls back.
- `Sources/Gargantua/MainContentView.swift` — added `activeDeepCleanProfile` computed var that reads `persistence.fetchSettings().activeProfileID`, looks up the profile via the resolver, and returns `.deep` when persistence isn't ready. Switched the `deepClean` case to pass this value.
- `Tests/GargantuaCoreTests/Models/CleanupProfileTests.swift` — added 5 focused resolver tests (persisted override wins, built-in fallback, devPurge lookup, unknown ID fallback, empty ID fallback).

**Key decisions**
- Split pure resolution into `CleanupProfile.resolve(...)` so behavior is testable without a SwiftData stack; MainContentView owns the thin persistence-fetch adapter.
- Persisted profiles are searched first so user edits to a built-in (same `id`) shadow the built-in constant.
- `devPurge` is checked explicitly because `CleanupProfile.builtIn` excludes it by design.
- Deep Clean keeps `.deep` as its fallback — if persistence fails or the stored ID is stale, behavior is unchanged from before this task.

**Tests**: 358/358 passing (baseline 353 + 5 new resolver tests).
