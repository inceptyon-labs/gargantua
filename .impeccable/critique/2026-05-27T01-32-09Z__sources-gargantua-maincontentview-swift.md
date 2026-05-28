---
target: full app
total_score: 31
p0_count: 0
p1_count: 2
timestamp: 2026-05-27T01-32-09Z
slug: sources-gargantua-maincontentview-swift
---
## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 4 | Solid |
| 2 | Match System / Real World | 3 | Thematic labels have fallback clarity |
| 3 | User Control and Freedom | 3 | No in-app Trash restore flow |
| 4 | Consistency and Standards | 3 | Settings header breaks scale; GargantuaButton used only in Settings |
| 5 | Error Prevention | 3 | Permanent delete of large amounts needs text confirmation |
| 6 | Recognition Rather Than Recall | 3 | Solid |
| 7 | Flexibility and Efficiency | 4 | Excellent keyboard shortcuts |
| 8 | Aesthetic and Minimalist Design | 3 | Dashboard stacks tall on 13" |
| 9 | Error Recovery | 3 | Solid |
| 10 | Help and Documentation | 2 | No onboarding, no contextual help |
| **Total** | | **31/40** | **Good** |

## Anti-Patterns Verdict

No AI slop detected. Zero shadows, gradient text, glassmorphism, or material/blur. Structural scan found 4 false positives (semantic side-stripe borders, logo brand colors, structural Color.clear/black, .white on colored fills). Three genuine structural findings: 10 bare ProgressView instances, ~20 inline button CTAs bypassing GargantuaButton, 216 hardcoded font sizes (half icon sizes, half genuine bypasses).

## Priority Issues

- [P1] Settings header uses display font (28px) while all other pages use heading (16px) via PageHeaderView
- [P1] 16 sidebar items is too many destinations; overlapping scan tools need consolidation
- [P2] GargantuaButton used only in Settings; ~20 feature CTAs are hand-built inline
- [P2] Idle states across 6+ views share identical template layout
- [P2] 10 bare ProgressView() instances remain in secondary contexts

## Persona Red Flags

- Alex (Power User): App requires manual "Start Triage Scan" click before doing anything useful on launch
- Sam (Accessibility): AccretionDiskView is accessibilityHidden(true); no VoiceOver feedback during standalone loading states
- Dev Cleanup Casual: 16 sidebar items with no guidance before first triage scan
