---
# gargantua-gf5w
title: 'Feature: Bundle cleanup_rules and resolve mo for shipped .app'
status: todo
type: feature
priority: high
created_at: 2026-04-17T01:07:15Z
updated_at: 2026-04-17T01:07:38Z
parent: gargantua-l9dk
---

In a shipped signed/notarized .app bundle, cleanup_rules YAML files and any mo dependency must live in predictable bundle locations. Currently rules live at repo root (only swift run works) and mo lookup only falls back to homebrew paths.

## Acceptance Criteria
- [ ] `cleanup_rules/` copied into `Bundle.main.resourceURL` as an SPM resource (or via a post-build copy step if SPM resource handling is too constrained)
- [ ] `RuleDirectoryResolver.resolve()` prefers `Bundle.main.resourceURL/cleanup_rules` when present (already coded — verify at runtime from a built `.app`)
- [ ] Decision recorded: do we bundle `mo` or drop the hard dependency on it?
      - Option A (bundle): download mo binary in CI, sign with our team ID, place in `Contents/Resources/mo`. MoAnalyzeAdapter / MoStatusAdapter find it.
      - Option B (drop): remove mo from the app's runtime path entirely; replace `mo analyze` with native disk walker and `mo status` with native `sysctl`/`IOKit` queries (already PRD Phase 1.5 plan for status).
      - Option C (require brew): document "Install mole via Homebrew to enable Disk Explorer / System Status"; detect and show onboarding banner if missing.
- [ ] Chosen option documented in this bean; follow-up tasks created for execution
- [ ] Running the built `.app` (not `swift run`) can scan without extra env vars

## Wiring Checklist
- [ ] Add resource declaration to `Package.swift` for cleanup_rules (or add build script)
- [ ] Verify `Bundle.main.resourceURL` path at runtime when launched from Finder
- [ ] If Option A: add CI step to fetch + codesign mo, update `MoleRunner.resolveBinaryPath()` to check bundled path first
- [ ] Update onboarding to detect missing mo (Option C) and guide install

## Notes
Current `RuleDirectoryResolver` already walks up from the executable looking for `Package.swift` — that fallback disappears in a shipped `.app`, so the bundled resource path is the hard requirement.
