---
# gargantua-oeil
title: Integrate PermissionChecker into permission flow
status: in-progress
type: task
priority: low
tags:
    - area:frontend
    - pasiv
    - size:S
created_at: 2026-04-16T11:07:05Z
updated_at: 2026-04-16T14:15:09Z
---

PermissionChecker service exists but isn't used in PermissionRequestFlowView. The onboarding flow should use it to check actual FDA/Automation permission status instead of just marking onboarding complete.

## Acceptance Criteria
- [x] PermissionRequestFlowView uses PermissionChecker to verify FDA status
- [x] Permission status shown as granted/denied with visual indicator
- [x] If permissions already granted, flow can be skipped
- [x] PermissionBannerView shown in main UI when FDA is missing (post-onboarding)
