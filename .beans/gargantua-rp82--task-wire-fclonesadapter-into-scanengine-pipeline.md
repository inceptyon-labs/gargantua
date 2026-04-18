---
# gargantua-rp82
title: 'Task: Wire FclonesAdapter into ScanEngine pipeline'
status: todo
type: task
priority: high
created_at: 2026-04-18T22:18:15Z
updated_at: 2026-04-18T22:18:15Z
parent: gargantua-4nb9
blocked_by:
    - gargantua-i1ii
---

Compose FclonesAdapter alongside NativeScanAdapter/CzkawkaAdapter in a multi-adapter scan pipeline so duplicate results surface through ScanEngine. Respect PRD §5 sequential pipeline rule (never run fclones + czkawka + native simultaneously). Keep duplicate results review-by-default. Blocked-by: gargantua-i1ii (adapter shipped). Reference: Sources/GargantuaCore/Services/ScanAdapter.swift, FclonesAdapter.swift.
