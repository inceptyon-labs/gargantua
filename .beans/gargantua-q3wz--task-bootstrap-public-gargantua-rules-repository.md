---
# gargantua-q3wz
title: 'Task: Bootstrap public gargantua-rules repository'
status: completed
type: task
priority: normal
tags:
    - area:docs
    - area:infra
    - size:S
created_at: 2026-04-23T23:19:51Z
updated_at: 2026-04-23T23:23:52Z
---

Bootstrap the public gargantua-rules repository now that it exists.

## Scope

- Add an MIT license.
- Add README and contributor guidance for rule-only PRs.
- Add schema docs and templates copied from the app repo starter kit.
- Seed the repository with the current reviewed cleanup and uninstall rule snapshot.
- Add standalone validation script and CI workflow.

## Acceptance Criteria

- [x] Public repository has a default branch with initial contents.
- [x] MIT license is present.
- [x] Rule docs, templates, and contribution flow are present.
- [x] Current app-bundled rules are copied into the public repo.
- [x] Validation can run standalone in the rules repo.

## Completed

- Bootstrapped `https://github.com/inceptyon-labs/gargantua-rules` with default branch `main`.
- Added MIT license and repository description.
- Added `README.md`, `CONTRIBUTING.md`, `docs/schema.md`, and `docs/templates/`.
- Seeded `rules/cleanup/` with 19 files / 83 cleanup rules from the app's reviewed snapshot.
- Seeded `rules/uninstall/` with 2 files / 12 remnant rules from the app's reviewed snapshot.
- Added standalone `Scripts/validate-rules.sh` and `.github/workflows/validate.yml`.
- Verified local validation passed and GitHub Actions `Validate Rules` passed on push.

## External Commit

- `inceptyon-labs/gargantua-rules@d45e367` — `chore: bootstrap public rules repository`
