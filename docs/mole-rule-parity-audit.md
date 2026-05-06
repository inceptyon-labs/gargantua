# Mole Rule Parity Audit

Audit date: 2026-04-24 UTC
Bean: `gargantua-81zc`
Mole source: `tw93/Mole@fd209bf1c8e7f1c07a3d5cb3f2c5c38ab730ad8e`
Mole commit date: 2026-04-24T08:02:08+08:00

## Summary

Gargantua does not yet have full Mole rule parity. After the app/cloud/office rule port, the app ships this reviewed snapshot:

| Area | Gargantua files | Gargantua rules |
| --- | ---: | ---: |
| App cleanup | 9 | 58 |
| Browser cleanup | 15 | 54 |
| Developer cleanup | 18 | 118 |
| System cleanup | 8 | 44 |
| Uninstall/remnant cleanup | 2 | 28 |
| Total | 52 | 302 |

Mole's cleanup implementation is shell-driven rather than rule-file-driven, so there is no perfect one-to-one rule count. As a conservative proxy, the current Mole source has 524 cleanup-operation call sites matching `safe_clean`, `clean_tool_cache`, `safe_sudo_find_delete`, `safe_sudo_remove`, and `safe_remove` across `lib/clean`, `lib/optimize`, and `lib/uninstall`.

| Mole source area | Cleanup-operation proxy count |
| --- | ---: |
| `lib/clean/app_caches.sh` | 174 |
| `lib/clean/user.sh` | 137 |
| `lib/clean/dev.sh` | 176 |
| `lib/clean/system.sh` | 17 |
| Other clean/optimize/uninstall helpers | 20 |
| Total | 524 |

The current Gargantua snapshot is enough for the initial native scanner, but parity work remains substantial. Porting should be batched by risk and product value rather than by blindly translating every Mole shell line.

## Current Gargantua Coverage

Bundled cleanup rule files:

- Apps: Dropbox, Slack, Spotify, cloud-sync apps, Office/mail apps, communication apps, virtualization caches, creative/media apps, productivity utilities, note apps, game/launcher caches, and remote desktop caches.
- Browsers: Arc, Brave, Chrome, Chromium, Comet, Dia, Edge, Firefox, Helium, Opera, Orion, Safari, Vivaldi, Yandex, Zen.
- Developer tools: Docker, Go, Homebrew, Node/frontend, Python/data, Rust, Xcode/mobile, JVM, editors, cloud CLIs, containers/Kubernetes, Ruby/PHP/.NET, Bazel/Zig/Deno/Terraform, CI caches, database/API tools, shell/network support, and AI/dev assistant caches.
- System cleanup: caches, logs, temp files, Trash, downloaded installer/archive filters, Finder metadata, Apple service caches, recent items, saved/autosave state, Mail Downloads, MobileSync backup protection, cached device firmware, privileged diagnostics/logs/updates/installers, and Rosetta/Apple Silicon caches.

Bundled remnant rule files:

- Generic user remnants: Application Support including bundle ID and safe name variants, Caches, NSURLSession downloads, Preferences and ByHost/SyncedPreferences, Containers and extension containers, Group Containers, Logs/crash reports, Saved State/recent shared file lists, WebKit/WebContent, HTTP storage/cookies, Application Scripts/workflows, user plug-ins/extensions, Unix-style config/data directories, and Privileged Helper Tools.
- System-level remnants: `/Library` support/preferences, caches/logs, plug-ins/extensions, and protected package receipts.
- Launch services: user LaunchAgents, system LaunchAgents, LaunchDaemons.

## Gap Inventory

### Browsers

Missing or partial Mole coverage:

- Dedicated cache rules now cover Edge, Chromium, Dia, Helium, Yandex, Opera, Vivaldi, Comet, Orion, and Zen.
- Chrome/Arc/Brave now include Mole's additional shader, Graphite/Dawn, GPU, component/extension CRX, GoogleUpdater, Puppeteer, and Service Worker ScriptCache paths where applicable.
- Firefox cache cleanup now carries a running-process guard.
- Remaining browser gaps are mostly dynamic pruning behaviors such as old browser framework versions and updater-version retention checks.

Classification guidance:

- `safe`: browser cache, code cache, GPU cache, shader cache, CRX/component cache, script cache, Puppeteer browser cache.
- `review`: Local Storage, cookies, IndexedDB, extension data, profile state, session restore data.
- `protected`: none by default, unless a path points at profile roots or credential/account databases.
- `out-of-scope until pruning policy`: old browser version pruning and updater retention checks.

### App, Cloud, Office, And GUI Caches

Ported from Mole in `gargantua-o1ka`:

- Cloud and sync apps: Google Drive, Baidu Netdisk, Alibaba Cloud Drive, Box, OneDrive, and expanded Dropbox cache variants. Sync roots, documents, account stores, and sync databases remain excluded.
- Office and mail apps: Microsoft Word, Excel, PowerPoint, Outlook, Apple iWork, WPS Office, Thunderbird, and Apple Mail. The YAML only targets cache, temp, and log directories; documents, AutoRecovery stores, mailboxes, templates, and preferences remain out of scope.
- Communication apps: Discord, Legcord, Zoom, WeChat, Telegram, Teams modern/legacy caches, WhatsApp, Skype, Tencent Meeting, WeCom, Feishu, and DingTalk cache/log locations. Message databases, downloads, and account state remain excluded.
- Virtualization: VMware Fusion and Parallels caches are safe, Vagrant temp files are safe, and VirtualBox's default `.cache` under `~/VirtualBox VMs` is review-gated because it sits next to VM bundles and disk images.
- Creative/media/productivity apps: ChatGPT and Claude desktop cache/logs, Sketch, Adobe, Figma, ScreenFlow, Final Cut Pro, DaVinci Resolve, Blender/Cinema 4D/Autodesk/SketchUp, Apple and third-party media caches, download-manager caches, note-app caches, Raycast and Alfred cache locations, remote desktop caches, and utility app caches.
- Game and emulator caches: Steam, Epic, Battle.net, EA, GOG, Riot, Minecraft, Lunar Client, PCSX2, and RPCS3 cache/log families are review-gated because some cache locations can represent large offline assets or project-adjacent generated data.

Remaining gaps or deliberately deferred behavior:

- Low-signal or highly niche GUI app cache paths from Mole can be added later, but the high-value cloud, office, communication, VM, media, productivity, launcher, game, and remote desktop families are now represented.
- Dynamic pruning behaviors remain out of YAML, including app-specific retention loops and checks that require command execution or app-aware current-version logic.
- App-specific protection checks such as Spotify offline-media detection and Raycast clipboard-history protection are represented conservatively by review-gated rules or narrow cache paths, not by broad data-directory deletion.

Classification posture used for the port:

- `safe`: cache, code cache, GPU cache, temp files, non-user logs, crash-report cache, media transcode cache where regenerated.
- `review`: offline media, sync databases, local storage, clipboard/history caches, app-specific support data, plugin caches with user projects nearby.
- `protected`: sync roots, user documents, credentials, account databases, keychains, browser cookies, active app state.
- `out-of-scope until app-specific guard exists`: Spotify-style offline-media detection, Raycast clipboard-history protection, and other app-specific "cache but contains user data" checks.

### Developer Tooling

Ported from Mole in `gargantua-kjv0`:

- Node/frontend: tnpm, npm residual caches, Yarn cache variants, Bun, Corepack, TypeScript, Electron, node-gyp, Turbo, Vite, Webpack, Parcel, ESLint, Prettier, Prisma, and bounded project-local web build caches.
- Python/data: pyenv, Jupyter runtime, Hugging Face, PyTorch, TensorFlow, Conda/Anaconda, Weights & Biases, and Mole path variants for Poetry, uv, Ruff, mypy, and pytest.
- Mobile/Xcode: CoreSimulator caches/logs/tmp, Xcode device logs/products/documentation/IB caches, Android Studio/SDK caches, SwiftPM cache variants, and Expo caches with account state excluded.
- Toolchains and languages: mise, Kubernetes cache, container temp, AWS CLI cache, Google Cloud logs, Azure logs, SBT, Ivy, Gradle, Maven, Ruby Bundler, Composer, NuGet, Bazel, Zig, Deno, Terraform, Grafana, Prometheus WAL review, Jenkins, GitLab Runner, GitHub Actions, CircleCI, SonarQube, Hex, Cabal, and opam.
- Developer apps: VS Code, Cursor, Zed, Copilot, JetBrains logs, Sublime Text, Sequel Ace/Pro, Redis tools, Navicat, DBeaver, Redis Insight, MongoDB Compass, Postman, Insomnia, TablePlus, Paw, Charles, Proxyman, Unity, Codex, Claude Desktop, Antigravity, Qoder, and OpenCode cache/log families.
- Shell/network support: Git lock/backup files, Oh My Zsh and completion caches, shell history backups as review, pre-commit cache, curl/wget caches.

Remaining gaps or deliberately deferred behavior:

- Command-backed pruning remains out of YAML: pnpm store pruning behavior, `go clean`, `nix-collect-garbage`, unavailable simulator deletion, package-manager prune commands, and tool-aware old-version retention loops.
- Version-pruning behaviors remain out of YAML where Mole keeps current/recent versions, such as JetBrains Toolbox apps, Xcode documentation indexes, simulator runtimes, device support versions, Claude Code versions, and Cursor Agent versions.
- Broad or risky project artifacts remain conservative: generic `bin`/`obj`, Terraform project caches, shell-history backups, Prometheus WAL, model caches, and upload staging are review-gated.

Pre-port classification:

- `safe`: build caches, package-manager caches, generated dependency caches, tool logs, crash-report caches.
- `review`: global package stores that double as offline mirrors, emulator/device support directories, CI workspaces, database/API tool caches, AI assistant pending uploads.
- `protected`: credentials/config directories such as `.aws` config, Docker config, kube config, SSH/GPG material, IDE settings, source workspaces.
- `out-of-scope until engine support`: tool-aware commands such as `npm cache clean`, `pnpm store prune`, `go clean`, `nix-collect-garbage`, `xcrun simctl delete unavailable`, and version-pruning loops.

### System And User Cleanup

Ported from Mole in `gargantua-72rh`:

- Finder and user state: `.DS_Store`, AppleDouble sidecars as review, recent item lists, saved application state, autosave information, and stale incomplete downloads.
- Apple user services: QuickLook/iconservices, photoanalysisd/mediaanalysisd, WebKit networking, account/identity caches as review, Siri suggestions, Calendar cache, AddressBook photo cache, sandboxed Apple service caches, wallpaper/idle assets, Rosetta user cache, and Apple media service caches.
- User Library cleanup: Mail Downloads as review, generic Application Support logs/caches as review, Group Container logs/caches/tmp as review with Apple shared containers excluded, cached device firmware as review, and MobileSync backups as protected.
- System cleanup: privileged `/Library` and `/private` cache/log/temp/diagnostic/update/installer paths as review, including `/Library/Logs/DiagnosticReports`, `/private/var/log`, Adobe/CreativeCloud system logs, `/Library/Updates`, `/macOS Install Data`, macOS installer apps, code-sign clone caches, diagnostic stores, power logs, memory exception reports, and the system Rosetta update bundle.

Classification posture used for the port:

- `safe`: regenerated user-level caches such as Finder/QuickLook/iconservices, WebKit networking cache, Apple media analysis caches, Apple sandboxed service caches, wallpaper thumbnails after age filtering, and user-level Rosetta/media service caches.
- `review`: AppleDouble metadata, recent items, saved state, autosave recovery files, incomplete downloads, Mail Downloads, cached firmware, generic Application Support and Group Container caches, system updates/installers, privileged logs/temp/cache/diagnostic stores, and system Rosetta cache.
- `protected`: MobileSync device backups and any Mole cleanup path representing backups, user documents, OS-critical stores, SIP/restricted data, credentials, active installer state, or system databases without a narrow stale-log/cache match.
- `out-of-scope until dedicated policy/support`: Time Machine snapshots and failed backups, external-volume top-level stores such as `.Spotlight-V100`/`.fseventsd`, active-download lsof checks, current macOS installer version checks, unrestricted group-container pruning, and any sudo-required deletion that should be mediated by explicit privileged-helper Trust Layer UX.

### Uninstall And Remnant Rules

Ported from Mole in `gargantua-jjue`:

- User-level static patterns: WebKit WebContent, HTTPStorages, cookies, Application Scripts, Services/Workflows, QuickLook generators, Internet Plug-Ins, Audio Plug-Ins, PreferencePanes, Input Methods, Screen Savers, Frameworks, Contextual Menu Items, Spotlight importers, ColorPickers, SyncedPreferences, Address Book plug-ins, Accessibility bundles, Mail bundles, XDG-style config/data directories, dotfiles, ByHost preferences, CrashReporter, diagnostic reports, shared file lists, and NSURLSession downloads.
- Bundle-ID-derived remnants: app extension containers under Application Scripts, Containers, FileProvider, and Group Containers using bundle ID, team ID, and name variants where available.
- System-level remnants: `/Library/Application Support`, `/Library/Caches`, `/Library/Logs`, `/Library/Preferences`, plug-ins/extensions, privileged helpers, LaunchAgent/Daemon variants, and protected package receipts.
- Scanner support: Mole-style app-name variants now include lowercase compound forms such as `maestro-studio`, and literal template hits resolve to the filesystem's actual child casing before dedupe.

Remaining gaps or deliberately deferred behavior:

- App-specific uninstall knowledge: Android Studio, Xcode, JetBrains, Unity/Unreal/Godot, VS Code, Docker, Maestro Studio, Raycast.
- Receipt/BOM expansion: package receipt files are protected, but Gargantua still cannot declaratively expand BOM contents into owned installed files.
- Login item removal, defaults-domain deletion, app-name variant command workflows, and sensitive-data preflight UX beyond current review/protected classification.

Pre-port classification:

- `safe`: logs, caches, saved state, crash reports, generated WebKit caches after app uninstall.
- `review`: preferences, containers, group containers, HTTP storage/cookies, Application Support variants, Application Scripts/workflows, plug-ins/extensions, dotfiles, app-specific project/tool directories, privileged helpers, and system-level support/cache/log paths.
- `protected`: package receipts, credentials, documents, system extensions, kernel extensions, login/network extension state, shared containers without ownership proof.
- `out-of-scope until dedicated support`: receipt/BOM expansion, login item removal, defaults-domain deletion, and app-specific destructive workflows.

## Rule Engine And Schema Gaps

The current YAML schema is strong for static path rules: it supports paths, single-segment and recursive globs, hidden recursive matches when the pattern asks for hidden segments, child filename patterns, excludes, process guards, presence/content guards, match filters, safety/confidence/explanation, source attribution, regenerate metadata, categories, tags, and profile-aware safety overrides. Remnant scanning also supports app-name variants and sensitive-data preflight.

Remaining gaps for full Mole parity:

1. ~~Command-backed cleanup: Mole uses tool-aware commands for package managers, simulators, Homebrew, Docker, Go, Nix, and other tools.~~ **Partially addressed.** The `CommandActionRule` schema and a starter set (`xcrun simctl delete unavailable`, `pnpm store prune`, `go clean -cache`) ship under `Sources/GargantuaCore/Resources/command_rules/`. Audit entries are written as `kind: command` with the captured tool version, exit code, and argument list. See the **Command-action hold list** below for what remains intentionally deferred.
2. Privileged cleanup policy: sudo-required locations must be modeled through the privileged helper with explicit Trust Layer constraints and UX before they can be more than review-gated path findings.
3. Active-file and current-version guards: Mole can skip files via `lsof`, running installer checks, current macOS version checks, and version-retention loops that YAML should not approximate as safe cleanup.
4. Receipt/BOM-derived remnants: Mole can inspect package receipts for installed files. Gargantua has no declarative rule model for receipt expansion yet.
5. External-volume policy: Mole can target external-volume `.Trashes`, `.TemporaryItems`, `.Spotlight-V100`, `.fseventsd`, and AppleDouble files with protocol checks. Gargantua should define an explicit external-volume scan/cleanup UX before porting those broadly.

## Recommended Port Order

1. Keep porting in narrow batches with conservative safety levels and explicit review/protected classifications.
2. Sync accepted Mole parity rules into the public `gargantua-rules` repository and vendor the reviewed snapshot back into this app.
3. Continue remnant-rule expansion only when new app-specific ownership evidence or receipt/BOM support exists.
4. Defer command-backed cleanup to dedicated adapters or Developer Tools flows.
5. Defer privileged cleanup escalation beyond review findings until helper UX and Trust Layer policy are explicit.
6. Define an external-volume cleanup policy before surfacing broad non-home-volume metadata/trash/cache rules.

## Command-Action Hold List

The following Mole-equivalent commands have an obvious adapter shape but are deliberately *not* in the bundled `command_rules/` snapshot. They sit on a "review-tier minimum, surprising semantics" hold list — they ship only after a more careful UX and dry-run story.

| Command | Reason for hold |
| --- | --- |
| `nix-collect-garbage` | Generation rollback semantics. Users who relied on `nixos-rebuild --rollback` or per-shell generations to recover from a bad change will silently lose that rollback target. Needs explicit "this also drops your rollback history" UX. |
| `npm cache clean` (`--force` required) | Offline install semantics. npm's cache doubles as the offline mirror that `npm ci` and `npm install --offline` rely on. Pruning it costs network on the next install and breaks airgapped/CI flows that don't expect re-fetch. |
| `go clean -modcache` | Re-fetch costs network. The module cache is shared across projects and can be tens of gigabytes; clearing it forces every project to re-download on the next build. Distinct rule from `go clean -cache` (already shipped) which only touches the build cache. |
| Tool-aware version-retention loops (e.g., "keep latest N JetBrains Toolbox apps", "keep current Xcode device support, drop older") | Active-use detection plus per-tool identity resolution required. "Old ≠ safe" without a per-tool concept of which version is in use; default classification is `review`-only until a generic version-retention guard exists. |

A future bean can promote any of these once the UX models the consequence honestly. They live on the `gargantua-wpl6` epic as candidates, not commitments.

## Follow-Up Tasks

The parent epic still has a child task for public rule sync/docs work. Browser, app/cloud/office, developer, rule-engine support, system/user, and generic remnant batches are now represented in the bundled rule snapshot. The `CommandActionRule` schema and the simctl/pnpm/go starter set landed in `gargantua-y84i`; MCP `scan`/`clean` integration and the in-app cleanup-flow surface for command rules remain open as follow-ups under the same epic.
