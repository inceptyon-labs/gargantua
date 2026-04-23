---
# gargantua-hrym
title: 'Feature: Scheduled scans via launchd'
status: todo
type: feature
priority: normal
created_at: 2026-04-23T20:54:15Z
updated_at: 2026-04-23T20:54:15Z
---

Let users schedule periodic background scans. Closes a Phase 2 gap from PRD §10.

## Context

PRD §10 (Phase 2 roadmap) calls for launchd-triggered scheduled scans with configurable intervals in Settings. Not started — no LaunchAgent plist, no scheduler service, no Settings UI.

## Requirements

- Install a per-user LaunchAgent on opt-in (not by default)
- Intervals: daily / weekly / custom cron-like
- Runs a lightweight scan profile (configurable; default = Light)
- Results delivered as a user notification + dashboard alert, not a blocking modal
- Respects energy/battery: skip when on battery if user opts in
- Clean uninstall path (remove plist, unload agent) when disabled

## Todo

- [ ] Settings → Scheduling UI (interval picker, profile picker, on-battery toggle)
- [ ] Generate & install `com.inceptyonlabs.gargantua.scheduler.plist` via SMAppService (LaunchAgent)
- [ ] Background entry point that runs scan + persists a summary for the next app launch
- [ ] UserNotifications prompt + delivery of "Scan complete / N GB reclaimable"
- [ ] Dashboard alert integration for pending results
- [ ] Uninstall/disable path
- [ ] Tests: plist generation, scheduler install/uninstall flow
