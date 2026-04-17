---
# gargantua-2xrw
title: 'Task: Add ScanAdapter protocol or remove MoCleanAdapter/MoPurgeAdapter'
status: completed
type: task
priority: normal
created_at: 2026-04-17T01:07:45Z
updated_at: 2026-04-17T15:39:35Z
parent: gargantua-l9dk
blocked_by:
    - gargantua-lupo
    - gargantua-guga
---

Once Deep Clean and Dev Purge no longer reference the Mole-based adapters, either delete the broken adapters or convert them behind a ScanAdapter protocol that NativeScanAdapter also conforms to. Prevents regression to the broken path.

## Summary of Changes

Deleted `MoCleanAdapter.swift`, `MoPurgeAdapter.swift`, and their test files. `ScanAdapter` protocol already in place (introduced by gargantua-lupo); `NativeScanAdapter` is the sole conformer. No protocol-or-delete ambiguity remains. `swift build` clean, 281 tests pass. Done as part of gargantua-9hhj.
