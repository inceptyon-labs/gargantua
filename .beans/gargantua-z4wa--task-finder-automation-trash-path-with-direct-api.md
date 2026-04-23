---
# gargantua-z4wa
title: 'Task: Finder Automation trash path with direct API fallback'
status: todo
type: task
priority: normal
tags:
    - area:backend
    - area:frontend
    - size:M
created_at: 2026-04-23T23:00:42Z
updated_at: 2026-04-23T23:00:42Z
---

PRD §9 calls for Move-to-Trash via Finder Automation with a direct Trash API fallback. The current implementation prompts/explains Automation during onboarding, but cleanup uses direct APIs (`NSWorkspace.recycle` for ordinary paths and `FileManager.trashItem` inside the privileged helper). There is no Finder Automation implementation or runtime fallback strategy.

## Evidence

- `Sources/GargantuaCore/Views/PermissionRequestFlowView.swift:100` shows an Automation onboarding screen, and `:110` says Gargantua uses Finder automation.
- `Sources/GargantuaCore/Services/CleanupEngine.swift:139` documents recycling via `NSWorkspace`, and `:143` calls `NSWorkspace.shared.recycle`.
- `Sources/GargantuaPrivilegedHelper/main.swift:49` moves privileged items with `FileManager.default.trashItem`.
- Repo search found no AppleEvent/osascript/Finder automation cleanup path; only onboarding copy and direct Trash APIs.

## Scope

- Decide and implement the PRD-intended primary path: Finder Automation first, direct API fallback second.
- Keep per-item result reporting and Trash URL capture where possible.
- Align onboarding copy/status with actual runtime capability.
- Add tests around fallback selection and error reporting using protocol seams/stubs.

## Acceptance Criteria

- [ ] Cleanup can attempt Finder Automation for user-visible Trash moves where appropriate.
- [ ] Direct `NSWorkspace.recycle` / `FileManager.trashItem` fallback remains available and tested.
- [ ] Onboarding/permission copy reflects the real behavior.
- [ ] Failures preserve the existing per-item `CleanupItemResult` shape.
