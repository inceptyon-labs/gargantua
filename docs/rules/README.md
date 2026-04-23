# Community Rules

This folder is the starter kit for crowd-sourced cleanup and uninstall rules.

For the current implemented rule inventory and remaining parity gaps, see [Rule Status](status.md).

## What Lives Where

- `Sources/GargantuaCore/Resources/cleanup_rules/`
  For cleanup rules used by the native scanner.
- `Sources/GargantuaCore/Resources/uninstall_rules/`
  For Smart Uninstaller remnant discovery.
- `docs/rules/templates/`
  Copyable starting points for new YAML files.

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

1. Choose the closest existing file to the app or category you are adding.
2. Start from a template in `docs/rules/templates/`.
3. Keep safety conservative.
4. Run `Scripts/validate-rules.sh`.
5. Open a PR using the rule checklist.

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
