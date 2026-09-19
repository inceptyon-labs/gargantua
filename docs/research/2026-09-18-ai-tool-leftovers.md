# AI tool leftovers — web research, proposed Gargantua rules

Target repo: `inceptyon-labs/gargantua-rules` → `rules/cleanup/developer/ai_tools.yaml`,
snapshotted into Gargantua's bundle.

**None of these tools are installed on the authoring machine.** Every path below comes
from vendor docs, source layout, or bug reports — nothing was verified on disk. That is
the central risk this review needs to attack.

## House safety contract (from the previous review round)

- `safe` = the tool rebuilds it unprompted. Cleanup may preselect and delete it.
- `review` = holds user conversation, generated output, or anything irreplaceable.
  Always paired with a `match_filters` age gate.
- **Never match** config, credentials, skills, commands, agents, plugins, installed
  extensions, or license state.
- **No SQLite databases.** Standing decision from the last round: deleting a live `.db`
  while its `-wal`/`-shm` sidecars remain risks corrupting the tool's state, and the
  `skip_if_process_running` guard only sees GUI apps (`NSWorkspace.runningApplications`),
  so a CLI can't be guarded.
- **Age gates must be measured on the thing that actually changes.** Last round's bug:
  a rule gated a project *directory* while the tool appends to a *file* inside it, so
  20 directories read 196 days stale while every transcript inside was under 29 days old.

## Rule engine facts that shape the proposals

- `paths` supports `~`, single-level `*`, and recursive `**`.
- `pattern` selects immediate children of each resolved path (hidden children skipped).
- `match_filters` supports `mtime > Nd`, evaluated against each matched item's own mtime.
- A rule with no `pattern` treats each resolved path as one result.

---

## A. VS Code-family extension storage

macOS layout is structural, not per-extension:
`~/Library/Application Support/<Editor>/User/globalStorage/<publisher>.<extension>/`

Every VS Code fork inherits it — Code, Cursor, Windsurf, VSCodium, Kiro, Trae — and
remote sessions use `~/.vscode-server/data/User/globalStorage/`.

**Proposal:** use a single-level glob for the editor rather than enumerating forks:
`~/Library/Application Support/*/User/globalStorage/<ext>/...`. Bounded (one wildcard
level, then literal segments), and it picks up forks not enumerated here.
*Question for review: is that glob too wide, or the right call?*

| Extension | globalStorage dir | What accumulates | Proposed |
|---|---|---|---|
| Cline | `saoudrizwan.claude-dev` | `puppeteer/.chromium-browser-snapshots/` — **747 MB measured**, a downloaded Chromium | `safe` |
| Cline | same | `tasks/<id>/{api_conversation_history,ui_messages,task_metadata}.json` — **359 MB measured** | `review`, mtime > 60d, gated per task dir |
| Cline | same | `checkpoints/<workspace-id>.git` — shadow git repo per workspace. Reports of **4 GB per task** and **120 GB+ accumulated** | `review`, mtime > 30d |
| Cline | same | `cache/` | `safe` |
| Roo Code | `rooveterinaryinc.roo-cline` | `tasks/<id>/` (same shape as Cline) | `review`, mtime > 60d |
| Kilo Code | `kilocode.kilo-code` | `tasks/<taskId>/` (Roo's shape) | `review`, mtime > 60d |
| Cody | `sourcegraph.cody-ai` | `symf/` — downloaded platform binaries, e.g. `symf-v0.0.6-aarch64-macos` | `safe` |
| Copilot Chat | `github.copilot-chat` | `cache/`, `logs/`, `tmp/` | `safe` |
| Copilot Chat | same | `session-store.db` | **excluded** — SQLite |

Sources: [Deguffer#83](https://github.com/BootBlock/Deguffer/issues/83) (measured
breakdown), [cline#4386](https://github.com/cline/cline/issues/4386) (checkpoint disk
usage), [Cline checkpoints docs](https://docs.cline.bot/core-workflows/checkpoints),
[Roo#3784](https://github.com/RooCodeInc/Roo-Code/issues/3784),
[Kilo file-locations](https://github.com/Kilo-Org/kilocode-legacy/blob/main/docs/file-locations.md),
[Cody troubleshooting](https://sourcegraph.com/docs/cody/troubleshooting),
[Copilot chat history discussion](https://github.com/orgs/community/discussions/129888).

**Concerns I want challenged:**
1. Cline's `checkpoints/` is its *undo* mechanism ("View Changes"). Is 30d too
   aggressive? Is `review` even sufficient, or should this be left alone entirely?
2. `puppeteer/.chromium-browser-snapshots` — safe to call `safe`? Cline re-downloads
   on demand, but that's a ~750 MB download on a metered connection.
3. Cody's `symf/` is a downloaded binary, not a cache. Re-downloaded automatically?

## B. Kiro (AWS)

`~/Library/Application Support/kiro/User/globalStorage/kiro.kiroagent/` — note the
lowercase `kiro` in Application Support. Chat history and session data, reported to reach
**13 GB+ with no built-in cleanup and no UI to manage it**.

Source: [kirodotdev/Kiro#5469](https://github.com/kirodotdev/Kiro/issues/5469).

Proposed: `review`, mtime > 60d. *Problem: I don't know the subdirectory layout inside
`kiro.kiroagent/`, so I can't scope below it, and a rule that targets the whole
directory would also take settings/state. Suggest dropping this tool unless the review
can establish the layout.*

## C. OpenCode

`${XDG_DATA_HOME:-~/.local/share}/opencode/`

| Path | Contents | Proposed |
|---|---|---|
| `log/*.log` | runtime logs | `safe` |
| `storage/message/ses_<id>/msg_<id>.json` | conversation messages | `review`, mtime > 60d |
| `storage/session/<hash>/ses_<id>.json` | session metadata | `review`, mtime > 60d |
| `storage/session_diff/`, `storage/part/`, `storage/tool-output/`, `storage/todo/` | per-session artifacts | `review`, mtime > 60d |
| `snapshot/` | file snapshots | `review`, mtime > 30d |

Existing bundled rule `opencode_cache` already covers `~/.cache/opencode`.

Sources: [OpenCode docs](https://opencode.ai/docs/troubleshooting/),
[session sharing / storage layout](https://deepwiki.com/sst/opencode/6.6-session-sharing).

**Concern:** `OPENCODE_DATA_DIR` can relocate all of this, so a fixed path silently
misses relocated installs. Acceptable, or worth skipping?

## D. Qwen Code

Gemini CLI fork, same `tmp/<project-hash>/` layout.

| Path | Contents | Proposed |
|---|---|---|
| `~/.qwen/tmp/<hash>/logs.json` | **full conversation content for every session of a project — grows unbounded, never cleaned, survives `/delete`** | `review`, mtime > 60d |
| `~/.qwen/tmp/<hash>/shell_history` | shell command history | `review`, mtime > 60d |
| `~/.qwen/projects/<hash>/chats/<id>.jsonl` | per-session transcripts | `review`, mtime > 60d |

Source: [QwenLM/qwen-code#11762](https://github.com/QwenLM/qwen-code/issues/11762) —
filed as a data-privacy concern; notes tool output in `logs.json` includes "SSH commands,
server configs, environment details" in plaintext.

**Follow-on for Gemini CLI:** the same `~/.gemini/tmp/<hash>/logs.json` exists (confirmed
present on the authoring machine, currently empty). The shipped `gemini_cli_chat_history`
rule covers `~/.gemini/tmp/*/chats` but **not** `logs.json` or `shell_history`. Propose
extending it.

## E. Goose (Block)

- `~/.local/share/goose/sessions/*.jsonl` — legacy session records. Since v1.10.0 goose
  imports these into a database and, per its own docs, the "legacy .jsonl files remain on
  disk but are no longer managed by goose." That is a genuine orphan: written by the tool,
  abandoned by the tool. Proposed `review`, mtime > 60d.
- Goose logs are already "automatically organized into date-based directories and cleaned
  up after two weeks" — **self-managing, so propose no rule.**

Source: [goose logging docs](https://goose-docs.ai/docs/guides/logs/).

## F. Amazon Q Developer CLI

`~/.aws/amazonq/history/chat-history-*.json` — prompts and responses per workspace,
including `chat-history-no-workspace.json`.

Source: [dev.to/aws — finding and recovering your prompt history](https://dev.to/aws/finding-and-recovering-your-amazon-q-developer-prompt-history-28j1).

Proposed: `review`, mtime > 60d.

**Concern:** this lives under `~/.aws`, which also holds `credentials` and `config`. The
rule is scoped to `~/.aws/amazonq/history` with a `chat-history-*.json` pattern, but
anything touching `~/.aws` deserves an extra look.

## G. Continue

Already covered: `~/.continue/index` (safe), `~/.continue/sessions` (review, 90d).
Newly found: `~/.continue/logs/core.log`. Proposed `safe`.

`CONTINUE_GLOBAL_DIR` relocates the root — same caveat as OpenCode.

Source: [Continue troubleshooting docs](https://docs.continue.dev/troubleshooting).

---

## Deliberately excluded

| Tool | Why |
|---|---|
| Tabnine | Only `~/.tabnine/mcp_servers.json` (config) substantiated; no cache layout found |
| OpenHands | Runs in Docker; `~/.openhands` holds config + session state with no documented split |
| Crush | Per-project `<project>/.crush/crush.db` — SQLite, and project-local |
| Amp | No local storage layout documented; threads sync server-side |
| Zed / Void / Augment / Supermaven / Warp / Trae | No citable path layout found |

## What I want from this review

1. Any proposed `safe` that should be `review`.
2. Any path that could match config, credentials, or irreplaceable data.
3. Any age gate measured on a directory whose mtime won't move when the content does
   — the exact bug caught last round.
4. Whether `~/Library/Application Support/*/User/globalStorage/…` is an acceptable glob.
5. Anything here that is too weakly sourced to ship at all.

---

# Corrections found after writing the above (before the review landed)

## 1. Cline changed storage roots in 4.x — the brief had the legacy path only

Cline now roots at `~/.cline` (override: `CLINE_DATA_DIR`). Documented tree:

```
~/.cline/
├── data/
│   ├── settings/providers.json   ← API KEYS AND PROVIDER CREDENTIALS
│   ├── settings/global-settings.json
│   ├── settings/cline_mcp_settings.json
│   ├── teams/            ├── sessions/     ← session data
│   ├── db/  (SQLite, e.g. cron.db)         └── workflows/
├── rules/  hooks/  skills/  agents/  plugins/  cron/
```

Consequences:
- Any rule touching `~/.cline` broadly would match `providers.json`. **Scope strictly to
  `~/.cline/data/sessions`.** Nothing else under `~/.cline` is shippable.
- `~/.cline/data/db/` is SQLite — excluded by the standing rule.
- The `saoudrizwan.claude-dev` globalStorage tree is now the **legacy** location. That
  makes it a *better* cleanup target, not a worse one: anyone who upgraded past 4.x has
  an abandoned copy of it that nothing will ever read again.

Source: [Cline config docs](https://docs.cline.bot/getting-started/config),
[cline#14135](https://github.com/cline/cline/issues/14135).

## 2. Kiro's layout is now known

`~/Library/Application Support/kiro/User/globalStorage/kiro.kiroagent/` contains one
directory per project, named as a 32-character hex hash. Reported in the issue:

```
d1c95acd1215dbe372efb48819c04345/   12 GB   (current project)
c0a23e81228432f1086bb8684f5c0604/   1.7 GB  (old project)
b1a9dfdf8e3da69e70d440745dabdb5f/   143 MB  (old project)
13G   kiro.kiroagent
```

No cleanup mechanism; the documented workaround is `rm -rf` of session directories.

Open question for the review: I still cannot prove `kiro.kiroagent/` holds *only* hash
directories. Options are (a) skip the tool, or (b) constrain `pattern` to a 32-character
name so settings files can't match. Which?

Source: [kirodotdev/Kiro#5469](https://github.com/kirodotdev/Kiro/issues/5469).

## 3. Two of these products are dead, which strengthens the case

- **Cody**: Free and Pro terminated 23 July 2025; individuals redirected to Amp. Only
  Enterprise remains. So on an individual's machine `sourcegraph.cody-ai/` — including
  the downloaded `symf` binaries — is unreachable by any running software.
- **Roo Code**: extension shut down 15 May 2026 after 3M+ installs; repo archived
  read-only. `rooveterinaryinc.roo-cline/tasks/` is abandoned data at scale.

Neither changes the proposed classification, but both mean these rules clean genuine
orphans rather than live state.

Sources: [Sourcegraph plan changes](https://sourcegraph.com/blog/changes-to-cody-free-pro-and-enterprise-starter-plans),
[Roo Code shutdown](https://vibecodinghub.org/blog/roo-code-shutdown),
[marketplace listing](https://marketplace.visualstudio.com/items?itemName=RooVeterinaryInc.roo-cline)
(publisher id `RooVeterinaryInc.roo-cline` confirmed current).

---

# Outcome after adversarial review (2026-09-18)

The review returned 6 blockers and 6 important findings against the proposals above.
Its central objection stands: this brief was built from vendor docs and third-party bug
reports, and two of its "measured" figures turned out to be a **Windows** breakdown and a
**Linux ARM devcontainer**, not native macOS. Most proposals were dropped.

## Shipped — verified against the tool's own path-building source

| Rule | Path | Evidence |
|---|---|---|
| `qwen_code_shell_history` | `~/.qwen/tmp/*/shell_history` | `Storage.getProjectTempDir()/shell_history` in `packages/core/src/config/storage.ts` |
| `gemini_cli_shell_history` | `~/.gemini/tmp/*/shell_history` | same method, same file, in `google-gemini/gemini-cli` |
| `goose_legacy_sessions` | `~/.local/share/goose/sessions/*.jsonl` | vendor docs: sessions moved to `sessions.db` at v1.10.0, legacy JSONL "remain on disk but are no longer managed by goose" |
| `continue_logs` | `~/.continue/logs/{core,prompt}.log` | `getCoreLogsPath()` / `getPromptLogsPath()` in `core/util/paths.ts` |

Reading goose's docs directly also caught something the brief had wrong: `sessions/`
holds the live `sessions.db` **alongside** the legacy transcripts. The rule matches
`*.jsonl` only; a `*` pattern would have swept up the database and its sidecars.

Source reading also **confirmed the already-shipped `gemini_cli_chat_history` rule**:
`getProjectTempDir()/chats` is exactly what that rule targets.

## Dropped, and what would change the verdict

| Proposal | Why dropped | What would unblock it |
|---|---|---|
| Cline / Roo / Kilo `tasks/` | Directory-level age gate unproven per writer and per version; per-file gating is worse, since it would delete fragments of a live conversation | A session-level last-activity signal with the whole session directory as the deletion unit — an adapter, not a YAML rule |
| Cline `checkpoints/`, OpenCode `snapshot/` | Recovery stores holding git repos; the deletion unit can span several tasks, and directory mtime doesn't represent every dependent conversation | Proof of repository ownership and reference relationships; never age-delete individual git objects |
| Kiro `kiro.kiroagent/` | 13 GB and no cleanup mechanism, but no inventory proving the directory excludes settings and credentials; the cited issue's largest child is the **current** project | A sanitized macOS inventory tied to an exact version, identifying the history files |
| Cline `puppeteer/.chromium-browser-snapshots` | The 747 MB figure is Windows; the corroborating report is a Linux ARM devcontainer | A native macOS inventory plus the resolver code, and a verified re-download |
| Cline `cache/`, Copilot Chat `cache/`,`logs/`,`tmp/` | Directory names are not evidence of contents or of regeneration | Current source identifying each subtree's writer and recovery behaviour |
| Cody `symf/` | Not binary-only — `symf/indexroot` holds local search indexes; auto-download is bypassed by a configured binary path | Split binaries from indexes; delete/restart/search test |
| OpenCode `storage/*` | Mixed JSON/SQLite generations; old JSON mtime can mean "migration source" rather than "unused conversation" | A versioned layout and evidence the records migrated |
| Amazon Q `~/.aws/amazonq/history` | Misattributed — the cited article describes the **VS Code plugin**, and AWS has since rebranded the Q CLI to Kiro | Identification of the current macOS writer |
| Gemini CLI `logs.json` | Not present in `storage.ts`; the file observed locally was empty. Fork ancestry is not evidence | The writer, or a populated versioned sample |

## Invariants added instead

`Tests/GargantuaCoreTests/Parsing/AIRuleSafetyContractTests.swift` asserts, across the
whole bundled rule set, that no rule enumerates a credential-bearing agent directory,
that the goose pattern cannot match `sessions.db`, that every `ai_history` rule is
age-gated and classified `review`, and that no rule targets a SQLite database. Each was
mutation-tested — all five fail when their invariant is violated.
