---
# gargantua-j8a1
title: 'Feature: Smart Uninstaller'
status: completed
type: feature
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-18T01:55:48Z
parent: gargantua-qe4a
---

Native uninstall workflow per PRD Phase 2. Use NSWorkspace / Launch Services app metadata plus YAML remnant rules. Preserve Trust Layer classifications and Trash-first cleanup.


## Summary of Changes

Feature complete. All six child tasks merged to main:

- **gargantua-9wxo** — Smart Uninstaller model + remnant rule YAML schema
- **gargantua-anqg** — RemnantRuleLoader (directory loader)
- **gargantua-8cs1** — Placeholder expander + remnant filesystem scanner
- **gargantua-4xkj** — NSWorkspace/LaunchServices app scanner
- **gargantua-9dxb** — Trash-first uninstall executor + admin helper protocol
- **gargantua-pxva** — SwiftUI surface (picker, plan review, confirmation, summary)

MVP is usable end-to-end for non-admin paths: user picks an app, reviews the auto-generated plan grouped by RemnantCategory, confirms through the existing 3-tier ConfirmationModalView, and sees a post-uninstall recap via CleanupSummaryView.

## Follow-up Work (not blocking)

- **Real authorization prompting** for protected items. Today `authorizationProvider` defaults to `{ nil }` in the view model, so selecting a `protected_` item (launch daemon, privileged helper) surfaces `UninstallExecutionError.authorizationRequired`. Needs an SMAppService/SMJobBless privileged helper wired to `PrivilegedUninstallHelping` plus an `AuthorizationRef` obtained through AuthorizationServices.
- **RemnantItem.id uniqueness assertion** — IDs are `"\(ruleID)-\(counter)"` plus `"app-bundle-\(bundleID)"`. Theoretically safe but no runtime guard; consider asserting or deduplicating when building `UninstallPlan` if user-authored rules are ever accepted.
