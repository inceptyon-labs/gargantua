# Overnight deep audit — Gargantua

Paste everything below the line into Fable as a single message. Budget: ~8 hours.

---

You are running an unattended, all-night deep audit of Gargantua, a native macOS
cleaner at `/Users/Jason/Development/gargantua`. You have roughly **4 hours**.
Use them. Do not wrap up early, do not ask me questions — I am asleep. If
something is ambiguous, pick the most reasonable interpretation, write the
assumption down in the report, and keep going.

## What you are producing

One file: **`docs/audits/2026-07-25-deep-audit.md`**

It is a work order. The reader is a *less capable model* (Sonnet/Opus tier)
that will implement the fixes one at a time with no memory of this audit and no
ability to re-derive your reasoning. Every finding must be implementable by that
reader from the report text alone — exact file paths, exact symbols, current
code quoted, proposed code sketched, and a concrete acceptance test.

You are **auditing, not implementing**. Do not fix anything. Do not commit, do
not push, do not create a branch. The only files you may write are your report
and your own scratch notes under `docs/audits/`. Building, running tests, running
linters, and launching the app are all expected and encouraged.

## Hard safety rules (this is a file-deletion app)

- **Never execute a destructive operation against real data.** No Deep Clean
  execute, no Uninstaller scrub, no Quarantine apply, no Duplicate Finder delete,
  no developer-tool cleanup command that actually prunes a real cache. Scan,
  preview, and dry-run only.
- If you need to exercise a destructive path, build a throwaway fixture tree
  under `/tmp/gargantua-audit-fixtures/` and point the app or a test at that.
  Never at `~`, `~/Library`, `~/Development`, or any real project.
- Do not modify any file under
  `Sources/GargantuaCore/Resources/{cleanup_rules,uninstall_rules,command_rules}/`.
  Those are a pinned snapshot of the `gargantua-rules` repo and CI fails on drift
  (`Scripts/sync-rules.sh check`). If a rule is wrong, *report* it; don't edit it.
- Do not touch `~/.claude`, `~/.beans`, or anything outside the repo except
  read-only inspection and `/tmp` fixtures.
- Do not run `beans create`. The report ends with a paste-ready backlog script
  that I will run myself.

## Repo orientation (verify, don't trust)

- Swift Package, `swift-tools-version: 6.0` (Swift 6 language mode), Swift 6.1 toolchain, macOS 14+.
  ~544 Swift source files, ~83k LOC, ~323 test files.
- Six targets: `GargantuaCore` (the bulk), `Gargantua` (SwiftUI app),
  `GargantuaMCP` (local MCP server, stdio + localhost SSE on port 7493),
  `GargantuaScheduler` (launchd background runner), `GargantuaPrivilegedHelper`
  (SMAppService/XPC), `GargantuaLicensing`, `GargantuaAppKitShims`.
- Dual build: `swift build` from a clean clone is fully unlocked (AGPL).
  `GARGANTUA_LICENSING=1` compiles in the trial clock, license gate, and Polar.sh
  activation. **Audit both configurations** — a bug that only exists in the
  licensed build is a bug that only paying customers hit, and I cannot see it
  from a normal build.
- Deps: Yams, mlx-swift-lm, Sparkle 2 (EdDSA), swift-transformers.
- Useful commands: `Scripts/run.sh` (launches the app with `mlx.metallib`
  staged — plain `swift run` may crash on MLX init), `Scripts/test.sh` (same for
  tests), `Scripts/sync-rules.sh check`, `Scripts/validate-rules.sh`,
  `Scripts/osv-spm-scan.sh`. SwiftLint must be run **over the whole project**,
  not per-file — CI does, and per-file runs miss error-level violations.
- Read `AGENTS.md`, `README.md`, `PRODUCT.md`, `DESIGN.md`, and `docs/licensing/`
  early. Read `CHANGELOG.md` and the last ~50 commits to learn what is already
  known and recently changed — do not report a bug that was fixed last week.

## Evidence discipline

This is the part that decides whether the report is worth anything.

- Every finding cites `path/to/File.swift:LINE` for code you actually opened
  **this session**. No recalled APIs, no assumed behavior.
- Before writing a finding, try to refute it. Ask: is there a guard elsewhere
  that makes this unreachable? Is this branch dead? Is there a test asserting the
  opposite? If you can't rule the refutation out, mark the finding
  `Confidence: Medium` or `Low` and say exactly what you couldn't verify.
- Findings you reasoned about but did not observe get an explicit
  **`UNVERIFIED — needs runtime repro`** tag. Never dress up inference as
  observation.
- If you claim something is broken at runtime, try to reproduce it at runtime.
  Build it, launch it, click it, read the console.
- Where a fix is non-obvious, write a tiny throwaway spike in `/tmp` to prove the
  approach compiles and behaves. Delete the spike; keep the snippet in the report.

## Brand-voice exclusion

The Nolan-themed copy (TARS / CASE / ENDURANCE / Event Horizon / Accretion Disk
naming across Deep Clean, Uninstaller, File Health, Smart Uninstaller) is
**deliberate brand voice, not AI slop**. Do not flag it. Do not suggest renaming
it to something "clearer". You may flag a themed label only if it actively
prevents a user from understanding what a destructive button will do.

Also: on the void/dark background, the system `ProgressView` spinner is invisible
— `AccretionDiskView` is the correct spinner. Uses of bare `ProgressView` on dark
surfaces are a *finding*, not a style preference.

---

# Phase plan

Work the phases in order. **Append to the report at the end of every phase** —
if you die at hour 6 I still want five phases of findings on disk. Keep a running
scratch log at `docs/audits/2026-07-25-progress.md` (phase, elapsed, what you
covered, what you deliberately skipped) so I can see the shape of the night.

Time estimates are guidance. If a phase is producing gold, stay in it; if it's
dry after a real effort, move on and say so in the progress log.

### Phase 0 — Baseline (~30 min)

- Clean build both configurations; record warnings verbatim (count + the
  interesting ones). Swift 6 concurrency warnings are a rich vein — do not skim.
- `Scripts/test.sh` full suite. Record pass/fail, duration, and any test that is
  skipped, flaky, or disabled. If tests fail, that's finding #1.
- SwiftLint + SwiftFormat over the whole project. Record violation counts by rule.
- `Scripts/sync-rules.sh check`, `Scripts/validate-rules.sh`,
  `Scripts/osv-spm-scan.sh`.
- Inventory what tooling exists vs. what actually runs in CI
  (`.github/workflows/`). Note anything configured but dead (muter, trivy,
  semgrep, gitleaks — `muter_logs/`, `trivy.yaml`, `coverage.lcov`, and
  `test_output.log` are all sitting in the repo root; figure out whether they're
  live or fossils, and whether any of them should be gitignored).

### Phase 1 — Security (~90 min)

Threat-model first, then hunt. This app deletes files, runs with elevated trust,
and exposes a local network port. Attack surfaces, in rough priority order:

1. **Privileged helper (`GargantuaPrivilegedHelper`)** — XPC connection
   validation. Is the client audited by code-signing requirement
   (`SecCodeCheckValidity` / `setCodeSigningRequirement`)? Can any local process
   connect and ask it to delete a path? What is the exact set of operations it
   exposes, and is each one path-validated *inside the helper* rather than
   trusting the caller? Privilege escalation here is the worst thing in the repo.
2. **MCP server (`GargantuaMCP`)** — localhost SSE on port 7493. Is there auth?
   Origin/Host header validation (DNS-rebinding: a web page the user visits can
   POST to `127.0.0.1:7493`)? Which tools are destructive, and is
   `LicenseGate.shared.canExecuteDestructiveAction()` plus a user-consent gate
   enforced on every one? Note: `clean` was ungated once and fixed on 2026-07-02 —
   confirm the fix held and check the same class of hole in every other tool.
3. **Path traversal / symlink handling** — a path-traversal bug was fixed
   2026-07-02. Re-audit the whole family: `..` normalization, symlink following
   during enumeration and during delete, TOCTOU between scan and execute, hard
   links, firmlinks, `/Volumes` and network mounts, paths with newlines or
   quotes. Verify `protected` classification cannot be bypassed by an alias,
   symlink, or case-insensitive path variant.
4. **Rule loading** — YAML parsed by Yams from bundled resources. Can a rule
   escalate? Billion-laughs / deeply nested YAML? Does any rule field flow into a
   shell invocation, a glob, or a regex (ReDoS)?
5. **Process spawning** — `ProcessSpawner.swift`,
   `DeveloperToolBinaryResolver.swift`, `CommandActionToolResolver.swift`. Is
   anything shelled through `sh -c`? Is `PATH` inherited from an untrusted
   environment? Can a malicious `node_modules/.bin` or a planted binary earlier in
   `PATH` get executed as the user? Is the resolved binary validated (absolute
   path, not user-writable directory, signature/ownership)?
6. **Licensing (`GARGANTUA_LICENSING=1`)** — Polar activation/validation. What is
   embedded (should be only the public `organization_id`)? Is the 14-day offline
   grace receipt tamper-resistant, or is it a plist a user can edit? TLS/cert
   handling. Any secret, token, or endpoint that shouldn't be in a public repo.
   Also grep the full git history for leaked credentials — a Polar org access
   token was pasted into a chat around 2026-07-13; confirm nothing like it ever
   landed in a commit.
7. **Sparkle updates** — EdDSA public key handling, appcast URL, HTTPS
   enforcement, downgrade/rollback protection.
8. **Cloud AI path** — what leaves the machine, is it redacted, is the spend cap
   enforceable client-side, is the API key stored in Keychain vs. UserDefaults.
   Verify the documented invariant that AI **cannot downgrade** a safety
   classification actually holds in code.
9. **Scheduler (`GargantuaScheduler`)** — launchd plist permissions, what it can
   do unattended, whether a scheduled scan can execute destructive actions with
   no human present.
10. **Audit log / Trash-first** — is the audit record written before or after the
    destructive act? Can it be suppressed? Is "Trash" ever silently a real delete
    (e.g. cross-volume, or when Trash is full)?

Use `tenet-security` / `tenet-secrets` style thinking if it helps, but do the
reading yourself — a tool's clean report is not evidence.

### Phase 2 — Correctness and bugs (~90 min)

Hunt real defects, not lint. Highest-yield areas given this codebase:

- **Concurrency**: Swift 6 strict-concurrency violations, `@MainActor` boundary
  errors, `nonisolated(unsafe)`, shared mutable state across the scan pipeline,
  `Task` cancellation that isn't propagated, actor reentrancy in the scanners.
- **Cancellation and lifecycle**: what happens if a user cancels mid-scan,
  quits mid-clean, sleeps the Mac mid-operation, or revokes Full Disk Access
  while a scan is running?
- **Size and count math**: `AlertItem.formatBytes` had a singular-byte bug fixed
  in `e2207c6` — that suggests a class of formatting/rounding defects. Check
  reclaimable-size accumulation, double-counting across buckets (a file matched
  by two rules), hard-linked files counted twice, sparse files, and APFS clones.
- **Duplicate Finder**: hashing strategy, collision handling, partial-read
  shortcuts, symlinked duplicates, the "keep one" selection logic — deleting the
  wrong copy is a catastrophic, unrecoverable bug.
- **Uninstaller**: leftover attribution (is a shared path attributed to one app
  and scrubbed?), bundle-ID matching false positives.
- **Error handling**: swallowed errors, empty catches, `try?` that hides real
  failures, operations that report success when a file wasn't actually removed.
- **Force unwraps / array indexing / precondition** on any path reachable from
  user data or filesystem state.
- **Persistence**: profile/settings/exclusion storage — migration on upgrade,
  corrupt-file recovery, concurrent write.

For each defect, give a **repro**: exact steps, or a failing unit test I can add.

### Phase 3 — Complexity and architecture (~60 min)

83k LOC across 544 files with heavy `Type+Extension.swift` splitting (e.g. seven
`ProcessInventoryView+*.swift`, five `DeveloperToolPanel*`). Assess honestly:
is the splitting genuine decomposition or is it a god-object hidden across files?

- Largest files and longest functions; cyclomatic complexity and nesting hot
  spots. Name the top 15 with numbers.
- Duplicated logic across scanners / views (path clustering, size formatting,
  safety classification, confirmation flows) that should be one implementation.
- Dead code: unreferenced types, unreachable branches, abandoned experiments,
  `TODO`/`FIXME` debt with an age (blame it).
- Layering: does `GargantuaCore` leak view concerns into services, or vice versa?
  Is anything in `Views/` doing filesystem work it shouldn't?
- Test coverage shape: which *critical paths* (destructive execute, protected
  classification, helper XPC, MCP gating) are untested? Coverage percentage is
  not the answer — name the untested critical paths.
- Recommend at most **five** refactors, each with a blast-radius estimate and a
  reason tied to a bug or a shipped-feature cost. Do not recommend refactoring
  for tidiness.

### Phase 4 — UX audit, driving the real app (~2 hours)

Launch it (`Scripts/run.sh`) and actually use it. Screenshot anything you flag.
Walk every surface in the sidebar: Dashboard, Deep Clean, Dev Artifact Scan,
Developer Tools, Disk Explorer, Duplicate Finder, File Health, File Organizer,
Smart Uninstaller, Background Items, Process Inventory, Rule Viewer, Profiles,
Scheduled Scans, Settings (every tab), the menu-bar widget, the licensing/unlock
sheet (build with `GARGANTUA_LICENSING=1` to see it).

**Three specific investigations I want answered by name — each gets a verdict in
the report even if the verdict is "works fine, no change needed":**

1. **Disk Explorer back-navigation.** Drilling into the treemap/file explorer,
   can you get *back*? Is there a breadcrumb, a back button, ⌘↑, a keyboard path,
   a scroll-to-parent? What happens at the root, at a permission-denied folder,
   after a rescan changes the tree under you? Files:
   `DiskExplorerView.swift`, `DiskExplorerView+Layout.swift`,
   `DiskTreemapLayout.swift`, `DiskExplorerDominantChildView.swift`,
   `DiskExplorerFocusUnavailableView.swift`, `DirectoryRowView.swift`,
   `DirectoryTreemapCellView.swift`. If navigation is one-way or lossy, design
   the fix concretely (component, state model, keyboard bindings, breadcrumb
   behavior at depth) — this is the finding I most expect to be real.

2. **Dead indicators — work happening with no signal.** Systematically hunt every
   place the app does something the user can't see: async work with no spinner,
   no progress, no result toast; buttons that fire and look inert; long scans
   with no ETA or item counter; failures that log to console and show nothing;
   empty states indistinguishable from loading states; `ProgressView` invisible
   on the void background where `AccretionDiskView` belongs; optimistic UI that
   never reconciles. Method: for each user-triggered action, trace from the
   button's action closure to every terminal state (success / empty / error /
   cancelled / permission-denied) and check that each terminal state renders
   *something*. Produce a **table**: surface → action → missing feedback →
   proposed indicator → file:line.

3. **Developer Tools — pnpm appears broken.** Reproduce it. `pnpm` is on my
   machine; the panel seems not to work. Trace the whole chain:
   `DeveloperToolsView.swift` → `DeveloperToolsExecutionFlow.swift` →
   `DeveloperToolBinaryResolver.swift` → `CommandActionToolResolver.swift` →
   `ProcessSpawner.swift` → `DeveloperToolPreviewOutputParser.swift` →
   `DeveloperToolPreviewAdapter.swift` →
   `DeveloperToolExecutionAdapter.swift`, plus the rule at
   `Sources/GargantuaCore/Resources/command_rules/developer/pnpm_store_prune.yaml`
   and `Sources/GargantuaCore/Models/CommandActionRule.swift`.
   Prime suspects to confirm or eliminate: a GUI-launched app inherits launchd's
   minimal `PATH` (no `/opt/homebrew/bin`, no `~/Library/pnpm`, no
   `~/.local/share/pnpm`), so binary resolution succeeds in a terminal and fails
   from the app bundle; corepack shims; volta/asdf/fnm shims that need a shell to
   resolve; `pnpm store prune` output format changed and the parser regex no
   longer matches; exit-code handling; sandbox/entitlement blocking exec. Then
   **audit every other tool in the panel the same way** — npm, yarn, brew, pip,
   cargo, go, docker, gradle, xcodebuild, whatever the rules define — and give a
   per-tool verdict table (resolves? previews? parses? reports correctly?).
   Include the exact reproduction and the exact fix.

Beyond those three, cover: destructive-confirmation clarity (does the button text
tell the truth about what's about to be deleted?), keyboard navigation and focus
order, VoiceOver/accessibility labels on icon-only controls, window resizing and
minimum sizes, first-run and permission-request flows, error copy that dead-ends
the user (there is prior art here — the `activationLimitReached` copy sent a
paying customer nowhere), and dark/void-theme contrast.

### Phase 5 — Cross-cutting sweep (~45 min)

- Dependency health and CVEs; Sparkle/MLX/Yams version currency.
- Build and release pipeline: `Scripts/release/`, signing, notarization,
  reproducibility, the vendored-binaries lockfile.
- Docs vs. reality: does the README describe behavior the code doesn't have?
- Performance: scanning a large tree — allocation churn, redundant `stat` calls,
  main-thread filesystem work, memory high-water mark on a deep scan. Measure
  something if you can; estimate honestly if you can't.

### Phase 6 — Three killer features (~45 min)

Not a brainstorm list. Exactly **three**, each one earned by something you saw in
the code or the UI during the night. For each:

- The insight from the audit that motivates it (cite what you saw).
- What it does, in one paragraph a user would understand.
- Why it fits *this* product's thesis — traceability, explainability,
  reversibility, agent-drivable, local-first, developer audience — and why the
  closed-box competitors structurally can't ship it.
- Implementation sketch: which modules, what new types, what the data model
  needs, roughly how much work, and what the riskiest unknown is.
- What it would cost in complexity, and what you'd cut to pay for it.

Bias toward things that exploit assets already in the repo (the rules corpus with
provenance, the MCP server, the audit log, local MLX, the privileged helper,
scheduled scans) rather than net-new subsystems. Prefer one feature that would
make a developer tell another developer about it over three tasteful increments.

### Phase 7 — Assembly and adversarial self-review (~45 min)

Re-read your own report as a hostile reviewer:

- Kill every finding you can't defend with a citation. A short honest report
  beats a padded one; I will notice padding and trust the rest less.
- De-duplicate findings that are the same root cause wearing different hats.
- Re-check severity assignments — inflating a nit to High burns my time.
- Verify every file path and line number you cited still resolves.
- Confirm each finding's "acceptance criteria" is something a junior model can
  actually check without judgment calls.

---

# Report format

`docs/audits/2026-07-25-deep-audit.md`

## 1. Executive summary
Ten bullets max. What is genuinely at risk, what is merely untidy, and the single
most important thing to do first. Lead with the outcome.

## 2. Baseline facts
Build status both configurations, test results, lint counts, tooling that is
live vs. dead. Raw numbers.

## 3. Findings
Grouped by area (Security / Correctness / Complexity / UX / Tooling /
Performance / Docs), sorted by severity within each group. Every finding uses
this exact template:

```
### [SEC-01] Short imperative title

- **Severity:** Critical | High | Medium | Low
- **Confidence:** High | Medium | Low  (+ UNVERIFIED tag if not observed)
- **Effort:** S (<1h) | M (half day) | L (multi-day)
- **Files:** `Sources/.../Thing.swift:120-158`, `Sources/.../Other.swift:44`
- **Depends on:** none | [SEC-03]

**What's wrong.** Two or three sentences. Plain technical English.

**Evidence.**
```swift
// current code, quoted from the file, with line numbers
```
What you observed at runtime, if you ran it.

**Why it matters.** The concrete failure: who does what, and what breaks.

**Repro.** Numbered steps, or the failing test to write.

**Proposed fix.** Specific. Name the file, the function, the change. Include a
code sketch of the target state. If there are two reasonable approaches, pick
one and say why in a sentence — do not hand the implementer a decision.

**Acceptance criteria.**
- [ ] Objectively checkable statement
- [ ] Test added at `Tests/.../XTests.swift` asserting Y
- [ ] `Scripts/test.sh` green, SwiftLint clean project-wide
```

## 4. Answers to the three named investigations
Disk Explorer back-navigation, dead indicators (with the full table), Developer
Tools / pnpm (with the per-tool verdict table). Each gets a verdict even if it's
"no defect found", with the evidence that led you there.

## 5. Complexity and architecture assessment
Numbers first, then the ≤5 recommended refactors.

## 6. Three killer features

## 7. Prioritized backlog
A single ordered table: rank, finding ID, title, severity, effort, dependencies.
Ordered by what I should actually do first, accounting for dependencies and for
which fixes unblock others. This is the table I will work top-down.

## 8. Appendix: beans backlog script
A fenced bash block of `beans create` commands — one per finding worth tracking,
with `-t bug|task|feature`, `-p critical|high|normal|low`, and a `-d` description
that references the finding ID and the report path. **Do not run it.** I will.

## 9. Appendix: what I did not cover
Honest gaps — areas skipped, findings you couldn't verify, things that need a
human or a second session. This section is mandatory and being thorough here
costs you nothing.

---

# Working style for the night

- Prefer reading code over running greps that return counts. Depth over breadth
  in the areas that can hurt a user; breadth is fine for docs and tooling.
- Use subagents freely to parallelize independent sweeps (one per area), but
  **you** verify every finding before it enters the report — do not paste a
  subagent's claims through unchecked. Subagents are frequently confidently wrong
  about code they skimmed.
- Write findings as you go. Never hold a phase's output in your head.
- Complete sentences. No arrow chains, no invented codenames, no compression
  that makes the implementer re-derive your meaning.
- If you finish early, do not stop — go deeper on Phase 1 (security) and Phase 4
  (UX runtime verification), then re-verify your Medium/Low-confidence findings
  and try to promote or kill them.

When you're done, the last line of your final message should tell me the report
path, the finding count by severity, and the one thing you'd fix first.
