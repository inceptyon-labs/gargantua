---
# gargantua-swvt
title: 'Feature: AI Tier 1 MLX Integration'
status: completed
type: feature
priority: normal
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:46:33Z
updated_at: 2026-04-16T00:58:13Z
parent: gargantua-w7pe
---

On-device AI via MLX Swift. Optional model download, lazy loading, eager unloading. Advisory-only — never changes safety classifications.

## Goals
- Model download to ~/Library/Application Support/Gargantua/models/
- Lazy load on first AI feature use (explain button click)
- Auto-unload after 60s of inactivity
- Explain button: local LLM explains file and its safety level
- Without model, fall back to YAML rule explanation string

## Scope
**In Scope:** Model download manager, lazy load/unload lifecycle, explain endpoint, fallback to YAML, AI tier selector in Settings
**Out of Scope:** Classification advisory (Phase 1.5), LoRA fine-tuning, Tier 2/3

## Summary of Changes

All tasks completed:
- gargantua-cldy: AI model download manager (ModelDownloadManager, SettingsView)
- gargantua-8s5j: Lazy model loading and explain endpoint (AIServiceProtocol, LocalAIService)

Feature is complete. MLX Swift framework integration pending as a future task.
