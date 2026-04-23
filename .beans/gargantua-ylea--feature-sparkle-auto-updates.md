---
# gargantua-ylea
title: 'Feature: Sparkle auto-updates'
status: todo
type: feature
priority: high
created_at: 2026-04-23T20:54:59Z
updated_at: 2026-04-23T20:54:59Z
---

Integrate Sparkle for signed, notarized auto-updates. Phase 3 requirement from PRD §10.

## Context

PRD §10 (Phase 3 roadmap) requires Sparkle for production distribution. No Sparkle dependency in the project today; users would have to manually re-download to upgrade.

## Requirements

- Sparkle 2.x (EdDSA-signed appcasts)
- Appcast hosted on gargantua.dev (or CDN); URL baked into Info.plist
- Automatic background check (default daily), user-visible "Check for updates" menu item
- Release notes rendered in-app
- Signature verification (EdDSA public key pinned at build time)
- Respect user's update channel (stable / beta) preference

## Todo

- [ ] Add Sparkle as Swift package dependency
- [ ] Generate EdDSA keypair; store private key in CI secrets only
- [ ] Wire SPUUpdater into AppDelegate with sensible defaults
- [ ] Info.plist: SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks
- [ ] Appcast generation step in release pipeline (sign DMG, produce XML)
- [ ] Settings → Updates pane (channel picker, check-now button, last-check timestamp)
- [ ] Release notes markdown → HTML rendering in Sparkle sheet
- [ ] E2E smoke test: install old build, trigger update, verify new build runs
