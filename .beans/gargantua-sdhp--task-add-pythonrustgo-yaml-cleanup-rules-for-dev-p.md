---
# gargantua-sdhp
title: 'Task: Add Python/Rust/Go YAML cleanup rules for Dev Purge'
status: completed
type: task
priority: normal
created_at: 2026-04-17T01:59:55Z
updated_at: 2026-04-17T16:38:52Z
parent: gargantua-l9dk
---

Dev Purge UI previously exposed Python (.venv, __pycache__), Rust (target/), and Go (GOPATH/pkg) category rows, but no native YAML rules existed for those categories — so they scanned empty. The UI rows were removed as part of guga; restore them once cleanup_rules/developer/*.yml adds rules for those toolchains.

Once rules exist, re-add entries to `DevArtifactCategory.defaults` in DevArtifactScanView.swift and extend the `matchesCategory` switch accordingly.


## Summary of Changes

Added three new rule files under `Sources/GargantuaCore/Resources/cleanup_rules/developer/`:

- `python.yaml` (10 rules): project-local `.venv`/`venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, and user-level caches for pip, pipx, poetry, uv.
- `rust.yaml` (6 rules): cargo `target/`, `~/.cargo/registry/{cache,src}`, `~/.cargo/git`, sccache, rustup tmp/downloads.
- `go.yaml` (3 rules): `~/Library/Caches/go-build`, `~/go/pkg/mod` (GOMODCACHE), `~/go/bin` (review, safe after 90d inactivity).

All rules are tagged with their language name (`python`/`rust`/`go`). Restored the Python / Rust / Go category rows in `DevArtifactCategory.defaults` (`DevArtifactScanView.swift`) and extended the `matchesCategory` switch with tag-based cases — category matching now uses `result.tags.contains(...)` so new languages can be added by YAML + one switch case.

Updated `RuleSetIntegrationTests.expectedFileCount` from 12 → 15, and `developerCoverage` now asserts Python/Rust/Go tagged rules exist.

Dropped one rule during self-review: `go_test_cache` at `~/Library/Caches/go-build/testcache` overlapped with the parent `go_build_cache` rule (adapter dedupes by exact path, so nested paths would have been double-counted).

- Tests: 235/235 passing
- Build: clean
- Lint: changed file DevArtifactScanView has pre-existing file_length + type_body_length warnings, untouched
- Commit: 8d961e5 merged to main
