# Community Rules

This folder is the starter kit for crowd-sourced cleanup and uninstall rules.

For the current implemented rule inventory and remaining parity gaps, see [Rule Status](status.md).

## Public Repository

The public home for rule-only collaboration is [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules).

Gargantua still ships a reviewed bundled snapshot in this app repo. The public rules repo is the source and collaboration surface; app releases import reviewed snapshots so local scans are deterministic and safety classifications cannot change at runtime.

## What Lives Where

- `https://github.com/inceptyon-labs/gargantua-rules`
  Public source repository for rule-only PRs, schema docs, templates, and standalone validation.
- `Sources/GargantuaCore/Resources/cleanup_rules/`
  Bundled cleanup snapshot used by the native scanner.
- `Sources/GargantuaCore/Resources/uninstall_rules/`
  Bundled Smart Uninstaller remnant snapshot.
- `docs/rules/templates/`
  Copyable starting points mirrored in-tree until the public repo owns the full starter kit.

## Rule Types

### Cleanup rules

Cleanup rules describe reclaimable files while an app is still installed.

Common categories already used in the app:

- `browser_cache`
- `browser_data`
- `system_cache`
- `system_logs`
- `temp_files`
- `trash`
- `installers`
- `app_cache`
- `app_data`
- `dev_artifacts`
- `docker`
- `homebrew`

### Remnant rules

Remnant rules describe files that may remain after an app is uninstalled.

These use `remnant_rules:` and `path_templates:` with placeholders such as:

- `{bundleID}`
- `{appName}`
- `{teamID}`

## Contribution Workflow

1. Open rule-only changes against [inceptyon-labs/gargantua-rules](https://github.com/inceptyon-labs/gargantua-rules) once its initial branch is populated.
2. Choose the closest existing file to the app or category you are adding.
3. Start from a template in `docs/rules/templates/`.
4. Keep safety conservative.
5. Run `Scripts/validate-rules.sh`.
6. If you change the app-bundled snapshot directly, include a sync note for the public repo.
7. Open a PR using the rule checklist.

See also:

- [Rule Schema](schema.md)
- [Contributing](../../CONTRIBUTING.md)

## Review Standards

Reviewers should be able to answer:

- What created this path?
- Does it regenerate?
- Could deleting it remove user data or state?
- Is the bundle ID attribution correct?
- Should this be grouped under an existing category instead of a new one?

## When To Add A New Category

Avoid new categories unless the rule family truly needs different profile behavior or distinct UI grouping.

If you add a new category, also update:

- `Sources/GargantuaCore/Models/CleanupProfile.swift`
- `Sources/GargantuaCore/Views/ProfileListView.swift`
- Any relevant integration tests
