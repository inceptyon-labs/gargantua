# Gargantua

Gargantua is a native macOS cleaner focused on trust, explainability, and developer-heavy cleanup workflows.

The cleanup engine is driven by bundled YAML rules under `Sources/GargantuaCore/Resources/`. Those rules are the authoritative source for safety classification; AI can explain them, but it cannot lower a rule's safety level.

## Current Rule Inventory

- Cleanup rules: 19 files / 83 rules
- Uninstall remnant rules: 2 files / 12 rules

See [Community Rules](docs/rules/README.md) for authoring docs and [Rule Status](docs/rules/status.md) for current scope and known parity gaps.

## Repo Highlights

- [PRD](Gargantua-PRD-v5-FINAL.md)
- [Contributing](CONTRIBUTING.md)
- [Community Rules](docs/rules/README.md)
- [Rule Schema](docs/rules/schema.md)
- [Design Brief](docs/design-brief-app-shell.md)

## Validation

Run the focused rule checks:

```bash
Scripts/validate-rules.sh
```

Run the full test suite:

```bash
swift test
```
