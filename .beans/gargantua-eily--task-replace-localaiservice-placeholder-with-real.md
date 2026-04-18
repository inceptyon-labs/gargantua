---
# gargantua-eily
title: 'Task: Replace LocalAIService placeholder with real inference boundary'
status: in-progress
type: task
priority: normal
created_at: 2026-04-17T18:07:39Z
updated_at: 2026-04-18T02:10:18Z
parent: gargantua-8igf
---

LocalAIService currently lazy-loads model bytes and returns structured/rule fallback text. Define and implement the real MLX or mlx-lm inference boundary, keeping fallback behavior and idle unload semantics.
