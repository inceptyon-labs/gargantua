---
# gargantua-071c
title: 'Task: Create public gargantua-rules repository and link it'
status: completed
type: task
priority: normal
tags:
    - area:docs
    - area:infra
    - size:S
created_at: 2026-04-23T23:00:52Z
updated_at: 2026-04-23T23:16:00Z
---

PRD §14 calls for a separate MIT-licensed `gargantua-rules` repository. The current repo documents community rule authoring in-tree, but no separate public repo is linked from the app/docs, and GitHub search did not find a matching `gargantua-rules` repository.

## Evidence

- `README.md:12` links to in-tree `docs/rules/README.md` and `docs/rules/status.md`.
- `CONTRIBUTING.md:9` directs contributors to in-tree `Sources/GargantuaCore/Resources/cleanup_rules/` and `Sources/GargantuaCore/Resources/uninstall_rules/`.
- `docs/rules/status.md:58` says a dedicated `gargantua-rules` repo is a future next step if contributions become frequent.
- `gh search repos gargantua-rules --limit 20` returned `[]` on 2026-04-23, and web search found no relevant GitHub repository.

## Scope

- Create or document the intended public `gargantua-rules` repository.
- Add MIT license and rule-only contribution flow if the repo is created.
- Update README/CONTRIBUTING/docs and any in-app links to point to the public rules repo.
- Decide whether bundled app rules stay mirrored in-tree or become imported from the rules repo.

## Acceptance Criteria

- [x] Public repo existence/ownership is documented.
- [x] README/CONTRIBUTING/docs link to the public rules repo.
- [x] Rule contribution workflow is clear for external contributors.
- [x] In-tree rule docs explain the sync/import relationship.

## Completed

- Verified `https://github.com/inceptyon-labs/gargantua-rules` exists, is public, and is owned under `inceptyon-labs`.
- Added the public rules repo link to `README.md`, `CONTRIBUTING.md`, `docs/rules/README.md`, and `docs/rules/status.md`.
- Added a "Contribute Rules" link in the in-app Rules screen header.
- Documented the sync model: `gargantua-rules` is the intended source/collaboration repo, while this app vendors reviewed snapshots under `Sources/GargantuaCore/Resources/` for deterministic runtime safety classification.

## Notes

- The public repo currently has no default branch, license, or validation CI. The app docs now call this out so the contribution path is clear without implying the external repo is already fully self-serve.
