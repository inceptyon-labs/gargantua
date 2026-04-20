---
# gargantua-xuz6
title: Evaluate and add MLX backend dependency
status: todo
type: task
priority: normal
created_at: 2026-04-20T14:05:34Z
updated_at: 2026-04-20T14:05:34Z
parent: gargantua-ddaa
---

Decide between MLX Swift SPM package and `mlx-lm` subprocess, then wire the
chosen dependency into the build so `MLXInferenceEngine` has something to
call. This Task does *not* implement `load`/`generate` — that's the next
child Task.

## Decide

- **MLX Swift (SPM package)**: in-process, no subprocess overhead, can read
  Metal directly. Adds ~tens of MB of dylib weight plus transitive deps
  (`mlx-swift-examples`, tokenizer). Needs to compile cleanly on release
  builds and not break the macOS release pipeline (see design doc
  docs/designs/2026-04-19-macos-release-pipeline.md).
- **`mlx-lm` subprocess**: out-of-process; uses the existing
  `DefaultProcessRunner` plumbing that's already hardened for
  timeout/SIGTERM/SIGKILL/stdin-pipe behavior. Adds a user-side Python
  dependency (or vendored helper), raises a PATH / TCC question similar
  to the developer-tools resolver pattern.

Write a short design note in `docs/designs/YYYY-MM-DD-mlx-backend.md`
capturing the trade-offs, the choice, and why.

## Do

Once picked:
- Add the dependency to `Package.swift` (SPM) or to `scripts/vendor-helpers`
  (subprocess) so release builds include what they need.
- Verify `swift build` debug + release still succeed.
- Verify the app bundle doesn't balloon past the PRD §7 budget.

## Out of scope

- Implementing `MLXInferenceEngine.load` / `generate` (next Task).
- Model file pinning / download manager changes.

## Acceptance

- [ ] `docs/designs/…-mlx-backend.md` captures the chosen backend + reasoning
- [ ] Build graph includes the dependency; `swift build` release is green
- [ ] App bundle size delta measured and recorded in the design doc
