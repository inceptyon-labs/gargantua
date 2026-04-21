---
# gargantua-u6gm
title: Reduce stripped release app below 50 MB
status: todo
type: task
priority: normal
tags:
    - area:release
    - size:S
created_at: 2026-04-21T01:25:17Z
updated_at: 2026-04-21T01:26:04Z
---

## Context

While implementing gargantua-5vv2, the release pipeline now strips shipped Mach-O executables before codesign and the main executable drops from 53,631,912 B to 26,538,488 B.

Actual assembled stripped app size is still 60M (`du -sh`), over PRD §7's 50 MB ceiling. Size contributors from the verified local assemble:

- czkawka_cli: 27M (28,019,544 B)
- Gargantua: 25M (26,538,488 B)
- fclones: 5.1M (5,327,800 B)
- mlx.metallib: 3.0M (3,135,866 B)

## Scope

Find a product-safe way to reduce the shipped app bundle below 50 MB without removing required functionality. Likely candidates: smaller czkawka packaging, optional/on-demand helper distribution, different helper build flags, or revisiting the PRD budget now that MLX + helper binaries are both included.

## Acceptance

- [ ] `du -sh dist/Gargantua.app` is under 50M after release build, assemble, strip, and sign.
- [ ] File-size breakdown is documented with before/after numbers.
- [ ] Duplicate Finder/File Health helper functionality remains available in the shipped app.
