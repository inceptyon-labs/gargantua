# Rule Schema

This is a practical schema guide for contributors. For the canonical runtime shapes, see:

- `Sources/GargantuaCore/Models/ScanRule.swift`
- `Sources/GargantuaCore/Models/Uninstaller/RemnantRule.swift`

## Cleanup Rule Shape

Top-level key:

```yaml
rules:
```

Common fields:

- `id`: stable unique identifier
- `name`: human-readable name
- `paths`: one or more absolute or `~`-relative glob paths
- `pattern`: optional filename filter inside a matched directory
- `exclude`: optional glob exclusions
- `safety`: `safe`, `review`, or `protected`
- `confidence`: integer from `0` to `100`
- `explanation`: one-line rationale shown in the app
- `source.name`: app or subsystem name
- `source.bundle_id`: optional bundle identifier
- `source.verify_signature`: optional boolean
- `regenerates`: boolean
- `regenerate_command`: optional command hint
- `category`: scan category used by profiles and grouping
- `tags`: optional tags
- `safety_overrides`: optional profile-aware reclassification rules

Example:

```yaml
rules:
  - id: example_cache
    name: Example Cache
    paths:
      - "~/Library/Caches/com.example.app"
    safety: safe
    confidence: 98
    explanation: "Disposable cache files regenerated automatically."
    source:
      name: Example App
      bundle_id: com.example.app
      verify_signature: true
    regenerates: true
    category: app_cache
    tags: [app, example, cache]
```

## Remnant Rule Shape

Top-level key:

```yaml
remnant_rules:
```

Common fields:

- `id`
- `name`
- `category`
- `path_templates`
- `pattern`
- `exclude`
- `safety`
- `confidence`
- `explanation`
- `source.name`
- `source.bundle_id`
- `source.verify_signature`
- `applies_to.bundle_ids`
- `applies_to.exclude_bundle_ids`
- `regenerates`
- `tags`

Example:

```yaml
remnant_rules:
  - id: example_support
    name: Example Support Files
    category: support_files
    path_templates:
      - "~/Library/Application Support/{appName}"
    confidence: 90
    explanation: App-written support data left behind after uninstall.
    source:
      name: "{appName}"
    regenerates: false
    tags: [generic, support]
```

## Safety Heuristics

- `safe`: disposable caches, logs, derived artifacts, rebuildable state
- `review`: local storage, sync state, preferences, offline media, containers
- `protected`: launch daemons or similarly sensitive system-impacting items

## Naming Guidelines

- Keep `id` stable and machine-friendly.
- Prefix app-specific IDs with the app name, such as `slack_cache`.
- Prefer one rule per meaningful storage family instead of one giant catch-all rule.
