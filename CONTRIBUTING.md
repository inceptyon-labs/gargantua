# Contributing

Thanks for helping improve Gargantua.

## Rule Contributions

The easiest way to contribute today is by adding or refining YAML cleanup and uninstall rules.

- Cleanup rules live in `Sources/GargantuaCore/Resources/cleanup_rules/`
- Uninstall remnant rules live in `Sources/GargantuaCore/Resources/uninstall_rules/`
- Rule authoring docs live in `docs/rules/`
- Rule templates live in `docs/rules/templates/`

Before opening a PR for rules:

1. Pick the closest existing file and match its style.
2. Keep `safety` conservative when a path may contain user data.
3. Add enough explanation text that a reviewer can understand why the rule is safe, review, or protected.
4. Validate the rules locally with `Scripts/validate-rules.sh`.
5. If you add a new category, update the built-in profiles and category UI in the app.

## Validation

Run the focused rule checks before opening a PR:

```bash
Scripts/validate-rules.sh
```

You can scope the checks:

```bash
Scripts/validate-rules.sh cleanup
Scripts/validate-rules.sh uninstall
```

## Safety Guidelines

- Use `safe` only when the files are clearly disposable or trivially regenerated.
- Use `review` when files may contain user preferences, session state, local data, or sync metadata.
- Use `protected` when removing the file could affect system boot, launch services, daemons, or privileged components.

When in doubt, prefer `review`.

## Evidence We Like In Rule PRs

- App name and bundle ID
- Realistic path samples from a test machine
- Why the files regenerate, or why they should stay review-only
- Notes about app-specific risk, such as offline media, login state, or shared containers
