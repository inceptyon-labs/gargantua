---
# gargantua-oeil
title: Integrate PermissionChecker into permission flow
status: todo
type: task
priority: low
tags:
    - area:frontend
    - pasiv
    - size:S
created_at: 2026-04-16T11:07:05Z
updated_at: 2026-04-16T11:07:05Z
---

PermissionChecker service exists but isn't used in PermissionRequestFlowView. The onboarding flow should use it to check actual FDA/Automation permission status instead of just marking onboarding complete.

## Acceptance Criteria
- [ ] PermissionRequestFlowView uses PermissionChecker to verify FDA status
- [ ] Permission status shown as granted/denied with visual indicator
- [ ] If permissions already granted, flow can be skipped
- [ ] PermissionBannerView shown in main UI when FDA is missing (post-onboarding)
