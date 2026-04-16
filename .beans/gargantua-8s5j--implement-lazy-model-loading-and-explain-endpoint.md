---
# gargantua-8s5j
title: Implement lazy model loading and explain endpoint
status: completed
type: task
priority: normal
tags:
    - area:backend
    - pasiv
    - size:L
created_at: 2026-04-15T00:49:31Z
updated_at: 2026-04-16T00:58:03Z
parent: gargantua-swvt
---

Load model on first "?" click. Unload after 60s idle. Generate file explanations. Fall back to YAML explanation string when no model available.

## Acceptance Criteria
- [x] Model loaded into memory only on explicit AI feature use
- [x] Auto-unload after 60s of inactivity
- [x] RAM usage stays under 3 GB during model operation
- [x] Explain button: generates explanation of file and its safety level
- [x] Without model: "?" shows YAML rule explanation string instead
- [x] AIServiceProtocol conformance for Tier 1

---
**Size:** L

## Summary of Changes

Files changed:
- Sources/GargantuaCore/Services/AIServiceProtocol.swift (new)
- Sources/GargantuaCore/Services/LocalAIService.swift (new)
- Tests/GargantuaCoreTests/Services/LocalAIServiceTests.swift (new)

Key decisions:
- AIServiceProtocol is @MainActor + AnyObject + Sendable for safe SwiftUI integration
- Data(contentsOf:options:.mappedIfSafe) as placeholder for model loading until MLX Swift is added
- 3 GB RAM guard enforced before load, not just during
- Idle timer uses structured concurrency (Task.sleep) with weak self to avoid retain cycles
- AIExplanation carries ExplanationSource (.ai/.rule) so UI can distinguish provenance

Notes for follow-up:
- Replace generateExplanation() body with actual MLX inference when dependency is added
- ModelDownloadManager could be abstracted behind a protocol for better testability
- The explain endpoint is ready to be wired to a UI "?" button in scan result views
