---
# gargantua-9dxb
title: 'Task: Uninstall execution path (Trash-first + admin helper)'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T21:50:04Z
updated_at: 2026-04-18T01:12:40Z
parent: gargantua-j8a1
blocked_by:
    - gargantua-8cs1
---

Execute an UninstallPlan: move selected items to Trash, record AuditEntry per operation, escalate to an admin helper for launch_daemons / privileged_helpers.

Scope:
- Reuse CleanupEngine patterns: Trash-first, never rm -rf
- Honour SafetyLevel: refuse protected_ unless explicitly overridden; require fullModal confirmation path
- Emit AuditEntry for every batch with tool='uninstaller', files list, bytesFreed, confirmationMethod, cleanupMethod
- Kill running processes (NSRunningApplication.terminate) before removing /Applications bundle, with timeout + forceTerminate fallback
- XPC-authenticated privileged helper (or SMJobBless) for /Library/LaunchDaemons and /Library/PrivilegedHelperTools — authorisation via AuthorizationRef
- Tests: dry-run mode, trash round-trip, audit entries written, protected-level refusal, admin-path gating

Blocked by gargantua-8cs1 (scanner produces the plan).
