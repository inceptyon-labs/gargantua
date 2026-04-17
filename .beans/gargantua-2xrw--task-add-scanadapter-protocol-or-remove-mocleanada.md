---
# gargantua-2xrw
title: 'Task: Add ScanAdapter protocol or remove MoCleanAdapter/MoPurgeAdapter'
status: todo
type: task
priority: normal
created_at: 2026-04-17T01:07:45Z
updated_at: 2026-04-17T01:07:45Z
parent: gargantua-l9dk
blocked_by:
    - gargantua-lupo
    - gargantua-guga
---

Once Deep Clean and Dev Purge no longer reference the Mole-based adapters, either delete the broken adapters or convert them behind a ScanAdapter protocol that NativeScanAdapter also conforms to. Prevents regression to the broken path.
