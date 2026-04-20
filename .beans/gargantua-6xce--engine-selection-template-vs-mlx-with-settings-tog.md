---
# gargantua-6xce
title: 'Engine selection: Template vs MLX with Settings toggle'
status: todo
type: task
priority: normal
created_at: 2026-04-20T14:06:09Z
updated_at: 2026-04-20T14:06:09Z
parent: gargantua-8igf
blocked_by:
    - gargantua-mgqr
---

`LocalAIService` takes an injected `AIInferenceEngine` but there's no way
for the app to actually select one. Wire the Template ↔ MLX choice into
Settings and pick a sensible default based on availability.

## Scope

- Add a Settings-level preference (`UserDefaults`-backed via the existing
  settings surface) for preferred engine: `.template` | `.mlx`.
- Change the `LocalAIService` construction site to honor the preference
  and fall back to `TemplateInferenceEngine` when MLX is selected but
  the model isn't downloaded or MLX isn't available for any reason.
- Settings UI: a simple picker / toggle. When MLX is picked but the
  model isn't yet on disk, surface the existing model-download affordance
  rather than silently doing nothing.

## Out of scope

- Actual MLX implementation (tracked under `gargantua-ddaa`).
- Changing the `AIExplanation.source` labeling; `.ai` vs `.rule` is
  already correct.

## Acceptance

- [ ] Settings exposes the engine preference and persists it
- [ ] App startup picks the right engine; missing model → fallback to
      Template and `AIExplanation.source == .rule` remains correct on
      the fallback path
- [ ] Tests cover: MLX selected + model present, MLX selected + no model,
      Template selected
