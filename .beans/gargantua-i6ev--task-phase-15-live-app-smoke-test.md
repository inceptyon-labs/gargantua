---
# gargantua-i6ev
title: 'Task: Phase 1.5 live app smoke test'
status: completed
type: task
priority: critical
created_at: 2026-04-17T18:07:17Z
updated_at: 2026-04-17T19:58:02Z
parent: gargantua-l9dk
---

Validate the current native-scanner app end-to-end from the actual running macOS app.

Acceptance criteria:
- Launch app from `swift run Gargantua` or built `.app`
- Deep Clean produces real NativeScanAdapter results
- Dev Purge produces real NativeScanAdapter results using default/custom scan roots
- System Status renders native metrics
- Disk Explorer opens and resolves rows progressively
- Clean flow moves selected safe fixture items to Trash and writes an audit entry
- Capture any manual notes/screenshots in the bean body

This is a manual smoke gate; automated tests already pass.

## Smoke Notes
- 2026-04-17: Deep Clean scan and cleanup were smoke-tested manually and appear functional.
  Follow-up UX issue found: safe cleanup confirmation was too minimal, results did not persist
  across navigation, and no refresh control existed for stale results.
- 2026-04-17: Follow-up fix implemented in app code: Deep Clean scan results now persist via
  shared session state, results view has a Refresh action, and cleanup confirmation is a full
  modal with Move to Trash / Delete Permanently choices.
- 2026-04-17: Live app smoke completed from `swift run Gargantua`.
  Evidence:
  - Fresh launch succeeded; Dashboard rendered native system metrics (`MacBook Pro - macOS 26.5`,
    `914 / 926 GB used`) and the Native/MCP footer. Full Disk Access banner appeared as expected
    for inaccessible system paths. Screenshot: `/tmp/gargantua-smoke-fresh-launch.png`.
  - Deep Clean completed with NativeScanAdapter results: 466 items, 30 GB reclaimable, 20.9s.
    Screenshot: `/tmp/gargantua-smoke-deep-results.png`.
  - Dev Purge completed with a disposable custom-root fixture; scan returned 14 items including
    `/private/tmp/gargantua-smoke-root/project/node_modules` at 4.1 KB. Screenshot:
    `/tmp/gargantua-smoke-dev-fixture-selected.png`.
  - Cleaned only the fixture row through the app confirmation modal using Move to Trash. UI
    reported "Cleanup Complete", "4.1 KB freed", and "1 item moved to Trash". The source fixture
    was removed. Audit log grew from 3 to 4 lines and recorded `cleanupMethod` `trash`,
    `bytesFreed` `4096`, and path `/private/tmp/gargantua-smoke-root/project/node_modules`.
    Screenshot: `/tmp/gargantua-smoke-clean-summary.png`.
  - Disk Explorer opened and resolved out of busy state with row controls present. Screenshot:
    `/tmp/gargantua-smoke-disk-explorer.png`.
  Cleanup: restored Dev Purge scan roots to the original Auto SwiftData blob and removed the
  `/tmp/gargantua-smoke-root` fixture.
