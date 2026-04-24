# Mole Rule Parity Audit

Audit date: 2026-04-24 UTC
Bean: `gargantua-81zc`
Mole source: `tw93/Mole@fd209bf1c8e7f1c07a3d5cb3f2c5c38ab730ad8e`
Mole commit date: 2026-04-24T08:02:08+08:00

## Summary

Gargantua does not yet have full Mole rule parity. The app currently ships a reviewed starter snapshot:

| Area | Gargantua files | Gargantua rules |
| --- | ---: | ---: |
| App cleanup | 3 | 12 |
| Browser cleanup | 5 | 22 |
| Developer cleanup | 7 | 37 |
| System cleanup | 4 | 12 |
| Uninstall/remnant cleanup | 2 | 12 |
| Total | 21 | 95 |

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

- Apps: Dropbox, Slack, Spotify.
- Browsers: Arc, Brave, Chrome, Firefox, Safari.
- Developer tools: Docker, Go, Homebrew, Node, Python, Rust, Xcode.
- System cleanup: caches, logs, temp files, Trash, downloaded installer/archive filters.

Bundled remnant rule files:

- Generic user remnants: Application Support, Caches, Preferences, Containers, Group Containers, Logs, Saved State, WebKit, Privileged Helper Tools.
- Launch services: user LaunchAgents, system LaunchAgents, LaunchDaemons.

## Gap Inventory

### Browsers

Missing or partial Mole coverage:

- Missing dedicated browsers: Edge, Chromium, Dia, Helium, Yandex, Opera, Vivaldi, Comet, Orion, Zen.
- Existing Chrome/Arc/Brave rules are partial. Mole includes additional cache families such as shader caches, Graphite/Dawn caches, component/extension CRX caches, GoogleUpdater cache/old files, Puppeteer cache, and Service Worker ScriptCache paths.
- Firefox has basic coverage, but Mole also guards cleanup when Firefox is running.

Pre-port classification:

- `safe`: browser cache, code cache, GPU cache, shader cache, CRX/component cache, script cache, Puppeteer browser cache.
- `review`: Local Storage, cookies, IndexedDB, extension data, profile state, session restore data.
- `protected`: none by default, unless a path points at profile roots or credential/account databases.
- `out-of-scope until engine support`: old browser version pruning and running-process-aware cleanup.

### App, Cloud, Office, And GUI Caches

Missing or partial Mole coverage:

- Cloud and sync apps: Google Drive, Baidu Netdisk, Alibaba Cloud, Box, OneDrive, plus expanded Dropbox cache variants.
- Office and mail apps: Microsoft Word, Excel, PowerPoint, Outlook, Apple iWork, WPS Office, Thunderbird, Apple Mail.
- Communication apps: Discord, Legcord, Zoom, WeChat, Telegram, Teams, WhatsApp, Skype, Tencent Meeting, WeCom, Feishu, DingTalk.
- AI and developer-facing GUI apps: ChatGPT, Claude Desktop, Codex, Antigravity, Filo, Qoder, OpenCode.
- Creative/media/productivity apps: Adobe, Sketch, Figma, Final Cut, DaVinci Resolve, Blender, Cinema 4D, Autodesk, SketchUp, Apple Music, Podcasts, TV, Plex, NetEase Music, QQ Music, VLC, IINA, MPV, Steam, Epic, Battle.net, Minecraft, Notion, Obsidian, Logseq, Bear, Evernote, Raycast, Alfred, Warp, Ghostty, and remote desktop tools.
- Virtualization: VMware Fusion, Parallels, VirtualBox, Vagrant.

Pre-port classification:

- `safe`: cache, code cache, GPU cache, temp files, non-user logs, crash-report cache, media transcode cache where regenerated.
- `review`: offline media, sync databases, local storage, clipboard/history caches, app-specific support data, plugin caches with user projects nearby.
- `protected`: sync roots, user documents, credentials, account databases, keychains, browser cookies, active app state.
- `out-of-scope until app-specific guard exists`: Spotify-style offline-media detection, Raycast clipboard-history protection, and other app-specific "cache but contains user data" checks.

### Developer Tooling

Missing or partial Mole coverage:

- Node/frontend: tnpm, Yarn, pnpm store pruning behavior, Bun, Corepack, TypeScript, Electron, node-gyp, Turbo, Vite, Webpack, Parcel, ESLint, Prettier.
- Python/data: pyenv, Hugging Face, PyTorch, TensorFlow, Conda/Anaconda, Weights & Biases, Jupyter runtime; current pip/poetry/uv rules are narrower than Mole.
- Mobile/Xcode: Simulator runtime caches, unavailable simulator deletion, device support cleanup, documentation cache pruning, Android Studio/SDK caches, Expo caches.
- Toolchains and languages: mise, Nix, Kubernetes, container temp, AWS CLI, Google Cloud logs, Azure logs, SBT, Ivy, Gradle, JetBrains, Ruby Bundler, Composer, NuGet, Bazel, Zig, Deno, Terraform, Grafana, Prometheus, Jenkins, GitLab Runner, GitHub Actions, CircleCI, SonarQube, Hex, Cabal, Opam.
- Developer apps: Sequel Ace/Pro, Redis tools, Navicat, DBeaver, Postman, Insomnia, TablePlus, Paw, Charles, Proxyman, Unity, Figma, GitHub Desktop, crash reporters, VS Code, Zed, Copilot, Cursor.
- Shell/network support: Git lock/backup files, Oh My Zsh cache, shell history backups, pre-commit cache, curl/wget caches.

Pre-port classification:

- `safe`: build caches, package-manager caches, generated dependency caches, tool logs, crash-report caches.
- `review`: global package stores that double as offline mirrors, emulator/device support directories, CI workspaces, database/API tool caches, AI assistant pending uploads.
- `protected`: credentials/config directories such as `.aws` config, Docker config, kube config, SSH/GPG material, IDE settings, source workspaces.
- `out-of-scope until engine support`: tool-aware commands such as `npm cache clean`, `pnpm store prune`, `go clean`, `nix-collect-garbage`, `xcrun simctl delete unavailable`, and version-pruning loops.

### System And User Cleanup

Missing or partial Mole coverage:

- User cleanup: `.DS_Store`, resource forks, recent items, saved application state, QuickLook/iconservices, photoanalysisd, akd, WebKit networking, Autosave, identity caches, Siri suggestions, Calendar cache, AddressBook photo cache.
- User Library cleanup: generic Application Support logs/caches, Group Container caches/logs, Mail Downloads, MobileSync backups, cached device firmware.
- System cleanup: `/Library/Logs/DiagnosticReports`, `/private/var/log` logs, third-party system logs, `/Library/Updates`, `/macOS Install Data`, macOS installer apps, `/private/var/folders` code-sign clones, `/private/var/db/diagnostics`, DiagnosticPipeline, powerlog, memory exception reports.
- Platform caches: Rosetta update bundle, Rosetta user cache, Apple Silicon media service cache.

Pre-port classification:

- `safe`: old logs, temp files, crash reports, diagnostic reports, generated previews, code-sign clone caches, regenerated icon/QuickLook caches.
- `review`: installers, `/Library/Updates`, MobileSync backups, Mail Downloads, cached device firmware, saved state, recent items, user Library support caches.
- `protected`: Time Machine snapshots/backups, OS-critical stores, SIP/restricted paths, active installer data, user documents, system databases.
- `out-of-scope until privileged-helper policy is explicit`: sudo-required system cleanup that Mole can perform from a CLI but Gargantua must route through the helper and Trust Layer.

### Uninstall And Remnant Rules

Missing or partial Mole coverage:

- User-level static patterns not yet covered: `~/Library/WebKit/com.apple.WebKit.WebContent/{bundleID}`, `~/Library/HTTPStorages/{bundleID}`, `~/Library/HTTPStorages/{bundleID}.binarycookies`, `~/Library/Cookies/{bundleID}.binarycookies`, `~/Library/Application Scripts/{bundleID}`, `~/Library/Services/{appName}.workflow`, QuickLook generators, Internet Plug-Ins, Audio Plug-Ins, PreferencePanes, Input Methods, Screen Savers, Frameworks, Autosave Information, Contextual Menu Items, Spotlight importers, ColorPickers, Workflows, SyncedPreferences, Address Book plug-ins, Accessibility bundles, Mail bundles, `~/.config/{appName}`, `~/.local/share/{appName}`, dotfiles, and ByHost preferences.
- Bundle-ID-derived remnants: app extensions under Application Scripts, Containers, FileProvider, shared file lists, NSURLSession download caches, and group containers matching bundle-id variants.
- System-level remnants: `/Library/Application Support`, `/Library/Caches`, `/Library/Logs`, `/Library/Preferences`, receipts, BOM-derived installed files, system LaunchAgent/Daemon variants, PrivilegedHelperTools, kernel/system extensions, frameworks, plug-ins, preference panes, input methods, screen savers.
- App-specific uninstall knowledge: Android Studio, Xcode, JetBrains, Unity/Unreal/Godot, VS Code, Docker, Maestro Studio, Raycast.

Pre-port classification:

- `safe`: logs, caches, saved state, crash reports, generated WebKit caches after app uninstall.
- `review`: preferences, containers, group containers, HTTP storage/cookies, Application Support, dotfiles, app-specific project/tool directories.
- `protected`: credentials, documents, system extensions, kernel extensions, login/network extension state, shared containers without ownership proof.
- `out-of-scope until engine support`: receipt/BOM expansion, login item removal, defaults-domain deletion, app-name variant generation, and sensitive-data preflight.

## Rule Engine And Schema Gaps

The current YAML schema is strong for static path rules: it supports paths, single-segment and recursive globs, child filename patterns, excludes, safety/confidence/explanation, source attribution, regenerate metadata, categories, tags, and profile-aware safety overrides.

Full Mole parity needs additional modeling:

1. Process-aware guards: Mole skips some cleanups while apps such as Firefox, Xcode, Simulator, or Spotify are running. Gargantua rules currently cannot express `skip_if_process_running`.
2. Presence/content guards: Mole protects Spotify offline media and Raycast clipboard history by inspecting sentinel files or specific subdirectories. Gargantua needs rule-level guard predicates before those paths can be safe.
3. Age filters as match filters: Gargantua can downgrade/upgrade safety by age, but many Mole system rules only match files older than a threshold. The scanner needs rule-level age filters so new logs/temp/installers are not surfaced as cleanable.
4. Command-backed cleanup: Mole uses tool-aware commands for package managers, simulators, Homebrew, Docker, Go, Nix, and other tools. Some belong in Developer Tools rather than YAML path cleanup.
5. Privileged cleanup policy: sudo-required locations must be modeled through the privileged helper with explicit Trust Layer constraints, not ported as ordinary path rules.
6. Dynamic app-name variants: Mole expands names into no-space, hyphen, underscore, lowercase, base-channel, and bundle-derived variants for uninstall remnants. Remnant rules currently support `{bundleID}`, `{appName}`, and `{teamID}`, but not name transforms.
7. Hidden recursive matches: `PathExpander` uses `.skipsHiddenFiles` during recursive walking. Patterns such as `**/.venv`, `**/.pytest_cache`, `**/.tox`, and `**/.cache` can be missed unless the expander learns to descend hidden directories when the rule asks for a hidden segment.
8. Receipt/BOM-derived remnants: Mole can inspect package receipts for installed files. Gargantua has no declarative rule model for receipt expansion yet.
9. Sensitive-data preflight: Mole checks candidate uninstall files for credentials, documents, preferences, cookies, and config markers. Gargantua should add equivalent preflight before broad variant/remnant expansion.

## Recommended Port Order

1. Fix hidden recursive matching before adding more project-local dot-directory dev rules.
2. Port browser cache-only gaps first: Edge, Chromium, Opera, Vivaldi, Orion, Zen, plus expanded Chrome/Arc/Brave cache families.
3. Port developer cache-only gaps next, starting with high-value package/build caches that are clearly regenerated.
4. Add system/user cleanup only where the existing non-privileged scanner and Trust Layer can represent the risk honestly.
5. Expand app/cloud/office caches in narrow batches with app-specific review/protected classification for sync/offline data.
6. Expand remnant rules after adding name-transform and sensitive-data preflight support.
7. Defer command-backed and privileged system cleanup to dedicated engine/helper tasks.

## Follow-Up Tasks

The parent epic already has child tasks for browser, developer, app/cloud/office, system/user, remnant, and sync/docs work. This audit adds one additional required implementation concern for the porting sequence:

- Add rule-engine support for hidden recursive matches, process/presence guards, age match filters, and dynamic remnant name variants before claiming full Mole parity.
