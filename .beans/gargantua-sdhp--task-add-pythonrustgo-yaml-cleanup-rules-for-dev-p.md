---
# gargantua-sdhp
title: 'Task: Add Python/Rust/Go YAML cleanup rules for Dev Purge'
status: todo
type: task
priority: normal
created_at: 2026-04-17T01:59:55Z
updated_at: 2026-04-17T02:00:24Z
parent: gargantua-l9dk
---

Dev Purge UI previously exposed Python (.venv, __pycache__), Rust (target/), and Go (GOPATH/pkg) category rows, but no native YAML rules existed for those categories — so they scanned empty. The UI rows were removed as part of guga; restore them once cleanup_rules/developer/*.yml adds rules for those toolchains.

Once rules exist, re-add entries to `DevArtifactCategory.defaults` in DevArtifactScanView.swift and extend the `matchesCategory` switch accordingly.
