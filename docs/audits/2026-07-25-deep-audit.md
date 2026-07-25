# Gargantua — deep audit, 2026-07-25

Audit of `/Users/Jason/Development/gargantua` at commit `fcdbeb4` (`main`), plus one
uncommitted working-tree change. Conducted unattended. Every finding below cites code
opened during this session; anything reasoned about but not observed carries an explicit
`UNVERIFIED` tag.

**Scope note / assumption stated up front:** the prompt asked for both build
configurations. Both were built (`swift build` and `GARGANTUA_LICENSING=1 swift build`).
The app was *not* driven interactively for every surface — see §9 for exactly which
runtime verifications happened and which did not. I have not marked any code-derived
finding as runtime-observed.

---

## 1. Executive summary

**21 findings: 5 High, 10 Medium, 6 Low.** The codebase is in good health — both builds
clean, 2410 tests green, no compiler warnings in production code, no leaked secrets in 951
commits — and its defenses in the hardest place (the root-privileged helper) are genuinely
well built. The problems cluster in two themes: *destructive actions that skip the license
gate*, and *the app telling the user an operation succeeded when it did not*.

1. **Fix first: `pnpm` is broken in the shipped app because Gargantua never sets a working
   directory for the tools it spawns.** A Finder-launched app runs them from `/`, and
   `pnpm store path` writes a probe file into the cwd, so it dies with `EROFS` (exit 226).
   Reproduced at the command line this session. One line to fix, it repairs a headline
   feature, and it is the only finding here a user has already reported. [BUG-01]
2. **The Dashboard reports a failed triage scan as a clean bill of health.** The error is
   recorded and never read, so the card falls through to a green checkmark reading "No
   triage groups found". A scan that crashed is indistinguishable from a spotless Mac, on
   the first screen the user sees. [UX-05]
3. **The Duplicate Finder never surfaces failed deletions.** `result.failedItems` is not
   rendered anywhere — no summary, no banner — and failed items quietly reappear in the
   list. This is the one surface where deleting the wrong copy is unrecoverable. [UX-06]
4. **The MCP SSE server is reachable by a web page via DNS rebinding.** Localhost binds
   require no bearer token and nothing validates the `Host` or `Origin` header, while the
   destructive `clean` tool is registered on that transport unconditionally. Off by default
   and notification-guarded, which is what keeps it High rather than Critical — though see
   finding 7. [SEC-02]
5. **Developer Tools executes destructive commands with no license gate.** `docker system
   prune`, `brew autoremove`, `go clean -modcache` and twelve more run straight from the
   confirmation modal. Commit `99bf0e3`, which deliberately swept "all GUI destructive
   paths" on 2026-07-03, enumerated six surfaces and missed this one. [SEC-01]
6. **The MCP `clean` tool is not license-gated either**, and its rate limit resets whenever
   a client renames itself in a re-`initialize`. Same root cause as finding 5: there is no
   enumerable list of destructive entry points, so "did we gate everything?" is answerable
   only by grep. [SEC-03], [SEC-05]
7. **Settings tells the user the MCP SSE endpoint exposes "read-only Gargantua tools."** It
   exposes file deletion. This is the consent surface for the whole network-exposure
   decision, and it is one string. [UX-03]
8. **Nine more post-action failures are logged and never shown**, including the
   `gargantua://activate` deep-link failure (paying-customer-facing) and audit-write
   failures across six destructive flows — after which the summary card still invites the
   user to "View Audit Trail", a button that then silently does nothing. [UX-07]
9. **The audit record is written after the destructive act, not before**, so a crash
   mid-clean leaves files deleted with no forensic trace — in a product whose stated thesis
   is traceability. [SEC-04]
10. **The one structural fix worth doing beyond the bug list:** an enumerable registry of
    destructive entry points, with a test that iterates it and asserts each is gated. That
    single change would have caught findings 5 and 6 mechanically, and it is the only
    refactor in this report that pays for itself in prevented bugs rather than tidiness.
    [REF-02]

**Not at risk, and worth stating plainly:** the privileged helper's XPC authentication
(audit-token-based, uid taken from the kernel, `lchown` not `chown`, hardcoded allow-list),
the "AI cannot downgrade a safety classification" invariant (holds structurally — no AI
path can write a `SafetyLevel`), scheduled scans (read-only, cannot delete), secret
hygiene (gitleaks clean across all 951 commits — the Polar token from the July support case
never landed), Sparkle (HTTPS-enforced, EdDSA, pinned to the CVE-patched 2.9.2), and
license-receipt tamper resistance (Keychain-backed, fail-closed migration marker).

## 2. Baseline facts

All commands run this session from a clean tree (plus the one uncommitted file noted
below).

| Check | Command | Result |
| --- | --- | --- |
| Unlocked build | `swift build` | **Build complete (29.77s)**, exit 0 |
| Licensed build | `GARGANTUA_LICENSING=1 swift build` | **Build complete (25.63s)**, exit 0 |
| Full test suite | `Scripts/test.sh` | **2410 tests / 326 suites, all passed**, 37s wall |
| Rule-set validation | `Scripts/validate-rules.sh` | 97 tests / 11 suites passed |
| Rule snapshot drift | `Scripts/sync-rules.sh check` | `OK — bundle matches upstream@5e75aa7` |
| Dependency CVEs | `Scripts/osv-spm-scan.sh` | `No issues found` (17 packages) |
| Secret scan, full history | `gitleaks detect` | `951 commits scanned … no leaks found` |
| SwiftFormat | `swiftformat --lint .` | `0/870 files require formatting`, 90 skipped |
| SwiftLint (whole project) | `swiftlint lint` | **6 warnings, 0 errors** |
| Compiler warnings | `swift build --build-tests`, full recompile | **1225 total — 0 in `Sources/`, 1225 in `Tests/`** |

### SwiftLint — all six, verbatim

```
Sources/GargantuaCore/Views/Licensing/LicenseErrorCopy.swift:9:1: Line Length Violation: 169 > 150 (line_length)
Sources/GargantuaCore/Services/CleanupEngine.swift:535:1: File Length Violation: 535 > 500 (file_length)
Sources/GargantuaCore/Services/CleanupEngine.swift:105:14: Type Body Length Violation: 303 > 300 (type_body_length)
Sources/GargantuaCore/Services/DeveloperToolPreviewOutputParser.swift:53:1: Type Body Length: 304 > 300 (type_body_length)
Tests/GargantuaCoreTests/Services/UserRuleSanitizerTests.swift:130:50: Trailing Comma Violation (trailing_comma)
Tests/GargantuaCoreTests/Services/MCP/MCPServerStatusStoreTests.swift:161:1: Vertical Whitespace before Closing Braces
```

CI runs `swiftlint lint` with no `--strict`, so these six warnings do not fail the build
today. Three of them are threshold violations that will become errors the moment anyone
adds `--strict` or nudges the file past the next limit.

### Compiler warnings by kind (1225, all in `Tests/`)

| Count | Warning |
| --- | --- |
| 767 | `'#require(_:_:)' is redundant because '…' never equals 'nil'` |
| 240 | `instance method 'lock'/'unlock' is unavailable from asynchronous contexts` — **error in Swift 6** |
| 97 | `instance method 'wait' is unavailable from asynchronous contexts` — **error in Swift 6** |
| 96 | `mutation of captured var in concurrently-executing code` — **error in Swift 6** |
| 25 | `result of call to 'withLock' is unused` |

The 433 Swift-6-fatal warnings are concentrated in a handful of test files
(`MaintenanceEngineAuditHookTests`, `ProcessInventorySessionTests`,
`BackgroundItemsSessionTests`, `ClaudeCodeAgentProcessExecutorTests`,
`MCPExplainToolHandlerInputTests`, `CloudAITransportTests`). Production code is clean.

### Tooling: live vs. fossil

| Artifact | Live? | Evidence |
| --- | --- | --- |
| SwiftLint / SwiftFormat | **Live** | `.github/workflows/ci.yml:23-38`, whole-project |
| `swift test` + coverage floor 78% | **Live** | `ci.yml:69-93` via `Scripts/coverage-priorities.sh` |
| `Scripts/sync-rules.sh check` | **Live** | `ci.yml:10-21`, its own job |
| `gitleaks` | **Live-ish** | `.githooks/` pre-commit, opt-in per clone; **not** in CI |
| `muter.conf.yml` + `mutation.yml` | **Live** | separate workflow; `muter_logs/` is gitignored output from Jun 1 |
| `trivy.yaml` | **Config only** | tracked in git, but no workflow invokes trivy — see [TOOL-01] |
| `coverage.lcov` (Jun 1), `test_output.log` (May 12) | **Fossils** | already gitignored, stale local output |

`coverage.lcov`, `test_output.log`, and `muter_logs/` are all covered by `.gitignore`
(verified with `git check-ignore`) and none is tracked. They are harmless local debris.
`trivy.yaml` and `muter.conf.yml` *are* tracked.

### Working-tree state at audit start

One uncommitted file: `Sources/GargantuaCore/Views/Licensing/UnlockGargantuaSheet.swift`
(+12/−9). It is the 2026-07-14 unlock-sheet styling fix — moves "Already bought? Enter
your key" out of the crowded action row onto its own line, restyles it as a caption-sized
underlined accent link, and adds `.focusable(false)` to kill the default focus ring. The
change is good and compiles. It has been sitting uncommitted for ten days. See [TOOL-03].

---

## 3. Findings

Grouped by area, sorted by severity within each group.

### Security

---

### [SEC-01] Gate Developer Tools command execution behind the license gate

- **Severity:** High
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/DeveloperToolsExecutionFlow.swift:257-286`, `Sources/GargantuaCore/Views/DeveloperToolsView.swift:112-121`, `Sources/GargantuaCore/Views/DeveloperToolsView+Results.swift:22,25`
- **Depends on:** none

**What's wrong.** Every destructive GUI surface in Gargantua calls
`DestructiveActionGate.blockReason()` immediately before touching a delete path. The
Developer Tools panel does not. Its confirmation modal calls `confirmExecution` directly,
which spawns a `Task` into `execute`, which calls the injected `executionProvider` —
`DeveloperToolExecutionAdapter().execute` — with no license check anywhere in the chain.
Fifteen operations run this way, including `dockerSystemPrune`, `homebrewAutoremove`,
`goCleanModcache`, and `cargoPurgeExtractedCaches` (which calls `FileManager.removeItem`
directly).

**Evidence.** The six gated surfaces, for contrast:

```
Sources/GargantuaCore/Views/FileHealthContainerCleanupFlow.swift:97:  if let reason = await DestructiveActionGate.blockReason() {
Sources/GargantuaCore/Views/CleanupSummaryView.swift:114:            if let reason = await DestructiveActionGate.blockReason() {
Sources/GargantuaCore/Views/DuplicateFinderContainerView.swift:123:   if let reason = await DestructiveActionGate.blockReason() {
Sources/GargantuaCore/Views/AIModelsView.swift:296:                    if let reason = await DestructiveActionGate.blockReason() {
Sources/GargantuaCore/Views/DevArtifactScanView.swift:192:           if let reason = await DestructiveActionGate.blockReason() {
Sources/GargantuaCore/Views/DeepCleanView.swift:253:                 if let reason = await DestructiveActionGate.blockReason() {
```

The ungated path, quoted from `DeveloperToolsExecutionFlow.swift:257-266`:

```swift
    func confirmExecution(_ request: ExecutionRequest) {
        session.pendingExecution = nil
        session.executingOperationID = request.operation.id
        session.executionNotices[request.operation.id] = nil

        Task {
            await execute(request)
        }
    }
```

and `:267-277`:

```swift
    func execute(_ request: ExecutionRequest) async {
        let operation = request.operation
        let beforeBytes = operation.estimatedReclaimableBytes(in: request.preview)
        let tier = confirmationTier(for: [Self.confirmationItem(for: request)])

        let executionResult = await Self.runExecutionProviderOffMain(
            executionProvider,
            operation: operation,
            preview: request.preview,
            confirmationMethod: tier
        )
```

A repo-wide grep for the gate in these files returns nothing:

```
$ grep -rn "LicenseGate\|DestructiveActionGate\|GateDecision" \
    Sources/GargantuaCore/Views/DeveloperTools*.swift \
    Sources/GargantuaCore/Services/DeveloperTool*.swift
(no matches)
```

**Refutation attempted.** I checked three ways this could be a non-finding and ruled all
three out. (a) The gate is not applied deeper: `DeveloperToolExecutionAdapter.execute`
(`Sources/GargantuaCore/Services/DeveloperToolExecutionAdapter.swift:102-152`) goes
resolver → `runner.run` → audit write, no gate. (b) It is not gated at the service layer
like the Uninstaller: `UninstallExecutor.swift:200` has an explicit
`canExecuteDestructiveAction()` call and `DeveloperToolExecutionAdapter` has none.
(c) It was not a deliberate exclusion: commit `99bf0e3` ("gate all GUI destructive paths
through a shared license gate", 2026-07-03) names the four surfaces it added and
explicitly says "The Uninstaller and Quarantine paths already gate at the service layer …
they were left as-is." Developer Tools is named nowhere in that commit message. This is
an omission, not a decision.

**Why it matters.** In a `GARGANTUA_LICENSING=1` build with an expired trial and no
license — the exact state a lapsed evaluator is in — the user can still reclaim tens of
gigabytes through Developer Tools. Deep Clean correctly raises the Unlock sheet; the
panel one click away in the sidebar does not. Beyond the revenue leak it is an
inconsistency a user will notice and reasonably read as the paywall being arbitrary.

**Repro.**
1. `GARGANTUA_LICENSING=1 swift build`.
2. Expire the trial: set the first-launch date 15 days back —
   `defaults write com.gargantua.app com.gargantua.licensing.trial.firstLaunch -date "$(date -v-15d +%Y-%m-%dT%H:%M:%SZ)"`
   (key from `TrialClock.swift:9`). Confirm Deep Clean now raises the Unlock sheet.
3. Open Developer Tools, scan, and click a cleanup button on any installed tool.
4. Observe: the confirmation modal appears and the command executes. Expected: the
   Unlock sheet, as on Deep Clean.

**Proposed fix.** Gate in `confirmExecution`, not in `execute` — the check belongs before
the modal is dismissed and the executing spinner starts, so a blocked user does not see
a phantom in-progress state. `DeveloperToolsView` needs a `blockedReason` on its session
state and the `.destructiveActionGate(reason:)` modifier on its body, exactly as
`DeepCleanView` does.

In `Sources/GargantuaCore/Models/DeveloperToolsSessionState.swift`, add:

```swift
    public var blockedReason: BlockReason?
```

In `DeveloperToolsExecutionFlow.swift`, replace `confirmExecution` with:

```swift
    func confirmExecution(_ request: ExecutionRequest) {
        session.pendingExecution = nil
        Task {
            if let reason = await DestructiveActionGate.blockReason() {
                session.blockedReason = reason
                return
            }
            session.executingOperationID = request.operation.id
            session.executionNotices[request.operation.id] = nil
            await execute(request)
        }
    }
```

In `DeveloperToolsView.swift`, attach the sheet to the outer `ZStack` (after the
`.animation` modifier at `:123`):

```swift
        .destructiveActionGate(reason: $session.blockedReason)
```

Choosing the view-layer gate over a service-layer throw inside
`DeveloperToolExecutionAdapter` because every other GUI surface uses the view-layer gate
and the shared modifier already renders the Unlock sheet; a service-layer throw would
need new error plumbing and would surface as a red failure notice rather than a buy CTA.

**Acceptance criteria.**
- [ ] `grep -c "DestructiveActionGate.blockReason" Sources/GargantuaCore/Views/DeveloperToolsExecutionFlow.swift` returns `1`.
- [ ] A test at `Tests/GargantuaCoreTests/Views/DeveloperToolsExecutionFlowTests.swift` injects a `decide` closure returning `.blocked(reason: .trialExpired)` and asserts `executionProvider` is never invoked and `session.blockedReason != nil`.
- [ ] A second test asserts that with `.allowed`, `executionProvider` **is** invoked exactly once.
- [ ] `Scripts/test.sh` green; `swiftlint lint` project-wide still 6 warnings or fewer.

---

---

### [SEC-02] Reject SSE requests whose Host header is not a loopback literal

- **Severity:** High
- **Confidence:** High (code); the DNS-rebinding chain itself is **UNVERIFIED — needs runtime repro**
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/MCP/MCPSSERequestRouter.swift:43-144`, `Sources/GargantuaCore/Services/MCP/MCPTransportSettings.swift:69,364-377`, `Sources/GargantuaMCP/main.swift:55,286,308-318`
- **Depends on:** none

**What's wrong.** When the MCP SSE transport is bound to localhost, no authentication is
required at all, and no code in the SSE request path inspects the `Host` or `Origin`
header. Host-header validation is the standard defense against DNS rebinding, and it is
absent. The destructive `clean` tool is registered on this transport unconditionally.

**Evidence.** Authorization is a no-op for localhost. `MCPTransportSettings.swift:69`:

```swift
    /// Whether incoming requests must present a bearer token.
    public var requiresBearerToken: Bool { bindScope == .lan }
```

and `MCPTransportSettings.swift:365-377`:

```swift
    public static func isAuthorized(
        authorizationHeader: String?,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> Bool {
        guard configuration.requiresBearerToken else { return true }
```

The router's only gate is that `authorize` call — `MCPSSERequestRouter.swift:52-53` for
stream open and `:104-106` for messages. A grep for host/origin validation across the
whole SSE path returns nothing:

```
$ grep -rni "host\b|origin|referer|sec-fetch" \
    MCPSSERequestRouter.swift MCPSSETransport.swift \
    MCPHTTPRequestParser.swift MCPHTTPMessage.swift \
  | grep -vi "bindHost|localhost|hostname|NWEndpoint"
(no matches)
```

And `clean` is on the same dispatcher the SSE transport uses.
`Sources/GargantuaMCP/main.swift:53-58`:

```swift
let dispatcher = MCPRequestDispatcher(
    serverInfo: MCPServerInfo(name: "gargantua", version: mcpServerVersion),
    tools: MCPPhase2Tools.all + MCPPhase3Tools.all,
    log: stderrLog,
    statusReporter: serverStatusStore
)
```

`main.swift:286` — `dispatcher.register(tool: .clean, handler: cleanHandler.toolHandler)`
— and `main.swift:311` hands that same dispatcher to `MCPSSETransport`.

**Refutation attempted, and what actually holds.** Two real defenses exist and they are
why this is not a plain CSRF hole. `MCPSSERequestRouter.swift:98-100` rejects preflight
outright:

```swift
        if request.method == "OPTIONS" {
            return .text(403, "Forbidden", "CORS preflight is not allowed.")
        }
```

and the server sets no `Access-Control-Allow-Origin` header, so an ordinary cross-origin
page cannot read the SSE `endpoint` event and therefore cannot learn the UUID `sessionId`
it would need to POST to `/message`.

DNS rebinding defeats both, because it removes cross-origin from the picture entirely:
the attacker's page is served from `attacker.example`, its DNS record is re-pointed to
`127.0.0.1`, and the browser then treats `http://attacker.example:7493/sse` as
**same-origin**. No preflight, no CORS headers needed, responses fully readable — so the
`sessionId` is readable too. The one header that still betrays the attack is `Host:
attacker.example`, which nothing checks.

**Why it matters.** A user who has enabled the MCP SSE transport (Settings → Network,
off by default) and then visits a hostile web page can have that page enumerate their
filesystem via `scan`/`explain` and delete every `safe`-classified item via `clean`. The
remaining mitigations bound the damage rather than prevent it: `protected` items are hard
rejected (`MCPCleanToolHandler.swift:216-219`), the rate limiter allows one clean per 60
seconds, and a notification with a 5-second cancel window fires first
(`main.swift:244-247`). Note the attacker may pass `"method": "delete"` for permanent,
non-Trash deletion — `MCPCleanToolHandler+Validation.swift:18-24` accepts it.

**Repro.** Cheap partial repro proving the missing check, without any rebinding setup:
1. `swift run GargantuaMCP -- --transport sse --port 7493 --bind localhost`
2. `curl -sN -H 'Host: evil.example' http://127.0.0.1:7493/sse`
3. Observe a `200` and an `endpoint` event carrying a `sessionId`. Expected after the
   fix: `403`.

Full chain repro requires a rebinding DNS server and is out of scope for this audit —
tagged UNVERIFIED above.

**Proposed fix.** Validate the `Host` header against a loopback allow-list in
`MCPSSERequestRouter.authorize`, so both `openStream` and `handleRequest` inherit it from
their single existing call site. Add to `MCPSSERequestRouter.swift`:

```swift
    /// DNS-rebinding defense. A rebound page reaches us with the attacker's
    /// hostname in Host; a genuine local client always uses a loopback literal.
    /// Applies only to localhost binds — a LAN bind is reached by hostname on
    /// purpose and is already bearer-token gated.
    private static func hasAllowedHost(
        _ request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration
    ) -> Bool {
        guard configuration.bindScope == .localhost else { return true }
        guard let host = request.header("host")?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        // Strip the optional :port, tolerating a bracketed IPv6 literal.
        let hostname: String
        if host.hasPrefix("[") {
            hostname = String(host.dropFirst().prefix(while: { $0 != "]" }))
        } else {
            hostname = String(host.prefix(while: { $0 != ":" }))
        }
        return ["127.0.0.1", "::1", "localhost"].contains(hostname)
    }
```

and change `authorize` (`:134-144`) to require both:

```swift
    private func authorize(
        _ request: MCPHTTPRequest,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> Bool {
        Self.hasAllowedHost(request, configuration: configuration)
            && MCPSSEAuthorization.isAuthorized(
                authorizationHeader: request.header("authorization"),
                configuration: configuration,
                storedToken: storedToken
            )
    }
```

Host validation rather than Origin validation, because a rebound same-origin request
sends no `Origin` header on a GET at all — `Host` is the field that always carries the
attacker's name. Keeping `localhost` in the allow-list because MCP client configs in the
README use `127.0.0.1` but users hand-edit to `localhost` constantly; it cannot be
rebound to a foreign IP without also controlling the user's resolver, at which point they
have already lost.

**Acceptance criteria.**
- [ ] `curl -H 'Host: evil.example' http://127.0.0.1:7493/sse` returns `403`.
- [ ] `curl http://127.0.0.1:7493/sse` (Host defaults to `127.0.0.1:7493`) still returns `200` with an `endpoint` event.
- [ ] Tests at `Tests/GargantuaCoreTests/Services/MCP/MCPSSERequestRouterTests.swift` cover: foreign Host on `GET /sse` rejected; foreign Host on `POST /message` rejected; `127.0.0.1`, `localhost`, `[::1]`, and each with an explicit `:7493` accepted; missing Host header rejected; and a `.lan` configuration unaffected by hostname.
- [ ] `Scripts/test.sh` green.

---

---

### [SEC-03] Route the MCP `clean` tool through the license gate

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift:151-175`, `Sources/GargantuaMCP/main.swift:254-286`
- **Depends on:** none (independent of [SEC-01], same root cause)

**What's wrong.** `LicenseGate.shared.canExecuteDestructiveAction()` has exactly three
call sites in the entire repo, and none is on the MCP path. The `clean` tool deletes
files regardless of license or trial state in a `GARGANTUA_LICENSING=1` build.

**Evidence.** The complete set of gate call sites:

```
Sources/GargantuaLicensing/LicenseGate.swift:18         (the declaration)
Sources/GargantuaCore/Views/Licensing/DestructiveActionGate.swift:27
Sources/GargantuaCore/Services/SpotlightOrphanRuleStore.swift:240
Sources/GargantuaCore/Services/UninstallExecutor.swift:200
```

`MCPCleanToolHandler.handle` (`:151-175`) performs, in order: decode →
`resolveAndValidate` → dry-run short-circuit → rate limit → `executeAndAudit`. No gate.
The handler's own doc comment (`:9-41`) enumerates every guardrail it implements —
unknown IDs, protected reject, `confirm: true`, dry run, rate limit, audit — and licensing
is not among them, which reads as an oversight rather than a documented exemption.

**Why it matters.** The gate is the product's paid boundary. An agent-driven clean is
exactly the workflow a power user would lean on, so this is the leak most likely to be
load-bearing in practice. It also produces incoherent behavior: the same delete is
blocked in Deep Clean and allowed through Claude Code.

**Repro.** With an expired trial in a licensed build (see [SEC-01] repro step 2), run
`swift run GargantuaMCP`, issue a `scan`, then a `clean` with `confirm: true` and
`dry_run: false` on a returned `safe` item id. Files move to Trash. Expected: a
tool-domain failure naming the license state.

**Proposed fix.** Gate inside the injected `cleaner` closure in `main.swift`, not inside
`MCPCleanToolHandler`. The handler is pure and synchronous by design (its `Cleaner`
typealias is a non-async closure, `:63`), and `canExecuteDestructiveAction()` is `async`
on an actor; putting it in the handler would force an async hop into a deliberately
synchronous type. The closure at `main.swift:254` already bridges async work through
`runBlocking`, so it is the natural seam.

In `Sources/GargantuaMCP/main.swift`, at the top of the `cleaner` closure:

```swift
private let cleaner: MCPCleanToolHandler.Cleaner = { items, method in
    if case .blocked = try runBlocking({ await LicenseGate.shared.canExecuteDestructiveAction() }) {
        throw MCPToolError.invalidParams(
            "Gargantua's trial has expired. Destructive MCP operations require a license key; "
                + "scans and dry runs remain available."
        )
    }
    let decision = cleanNotificationService.request(
```

The dry-run path never reaches `cleaner` (`MCPCleanToolHandler.swift:156-165`), so
previews stay available to unlicensed users — which is the correct product behavior and
matches the GUI, where scanning is always free.

**Acceptance criteria.**
- [ ] With a blocked gate decision, a non-dry-run `clean` returns a JSON-RPC error whose message names the trial/license state, and no file is moved.
- [ ] With a blocked gate decision, a `dry_run: true` `clean` still returns a normal plan.
- [ ] Test at `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerTests.swift` injects a `cleaner` that throws the licensing error and asserts the failure path writes a best-effort audit entry (existing `tryRecordAudit` behavior, `:279-286`).
- [ ] `Scripts/test.sh` green.

---

---

### [SEC-04] Write the audit entry before the destructive act, not after

- **Severity:** Medium
- **Confidence:** High
- **Effort:** M (half day)
- **Files:** `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift:242-273`, `Sources/GargantuaCore/Services/DeveloperToolExecutionAdapter.swift:119-144`
- **Depends on:** none

**What's wrong.** Both destructive paths that write audit records do the deletion first
and the audit write second. If the process dies between the two — crash, `SIGKILL`, power
loss, the user force-quitting during a long prune — the files are gone and no record of
the attempt exists.

**Evidence.** `MCPCleanToolHandler.swift:248-268`:

```swift
        do {
            let result = try cleaner(found, method)
            // Success path: audit is MANDATORY. A successful destructive op
            // with no durable record breaks PRD §7.4 ("all MCP-initiated
            // actions logged"). Fail-loud so the operator learns about the
            // missing audit before it piles up.
            do {
                try recordAudit(
```

The comment states the invariant correctly and the ordering then fails to guarantee it —
"fail loud" only helps when the process survives to reach the `catch`.

Same shape in `DeveloperToolExecutionAdapter.swift:119-144`: `runner.run(...)` executes
the prune at `:119`, and `try auditRecorder.write(entry)` lands at `:144`.

**Why it matters.** Gargantua's differentiation claim is traceability — README:
"Cleanup actions prefer Trash and write audit records for destructive workflows." The
window is small but the failure is silent and total: a user investigating "what deleted
my cache" after a crash finds nothing. For a permanent (`method: "delete"`) MCP clean,
the audit log is the only record that ever existed.

**Repro.** No natural repro; demonstrate by construction. Inject a `Cleaner` that deletes
a fixture file and then calls `exit(1)`, and observe `~/Library/Logs/Gargantua/audit.json`
has no entry for the operation. Build the fixture under
`/tmp/gargantua-audit-fixtures/`.

**Proposed fix.** Two-phase record: write an `attempted` entry before the act, then update
it to the outcome after. `AuditEntry` already carries a stable `id` (`recordAudit` takes
`entryID: UUID`), and `AuditWriter` is append-only JSONL, so the cheapest correct shape is
two lines sharing an id, with readers preferring the later one.

In `MCPCleanToolHandler.executeAndAudit`, before `try cleaner(found, method)`:

```swift
        // Intent record: written before anything touches disk so a crash mid-clean
        // still leaves evidence of what was attempted. Superseded by the outcome
        // entry with the same id below; AuditWriter readers take the last entry
        // per id.
        tryRecordAudit(
            entryID: auditUUID,
            clientID: clientID,
            requested: found,
            result: nil,
            methodHint: method
        )
```

leaving the existing post-act `recordAudit` in place unchanged. This needs a
last-entry-wins rule in the audit reader (`AuditWriter.swift:199-213` reads and decodes
every line) and in the retention compactor (`:236-260`), which is why this is M not S.

Choosing append-two-lines over rewriting the entry in place because `AuditWriter` is
explicitly designed for concurrent append without interleaving (see its header comment at
`:10`), and in-place mutation would forfeit that property.

**Acceptance criteria.**
- [ ] A test at `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerTests.swift` injects a `Cleaner` that throws after the intent write and asserts an entry with the operation's `auditID` exists in the recorder.
- [ ] A test asserts a successful clean produces exactly one *effective* entry per `auditID` when read back through the audit reader (last wins), not two visible rows in the UI.
- [ ] Audit retention compaction keeps the latest entry per id.
- [ ] `Scripts/test.sh` green.

---

---

### [SEC-05] The MCP rate limit resets whenever the client renames itself

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift:242-255`, `Sources/GargantuaCore/Services/MCP/MCPRateLimiter.swift`, `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift:167`
- **Depends on:** none

**What's wrong.** The `clean` rate limit is keyed on the client's *self-declared* name
from the `initialize` handshake. `initialize` is an ordinary dispatchable method with no
once-per-connection guard, and re-running it overwrites the stored identity. A client can
therefore re-`initialize` under a new name between cleans and get a fresh budget every
time, on a single connection, without reconnecting.

**Evidence.** The identity is captured — and unconditionally overwritten — at
`MCPRequestDispatcher.swift:243-250`:

```swift
        let capturedIdentity: MCPClientIdentity?
        lock.lock()
        if let client = parsed.clientInfo,
           let normalizedName = Self.normalizedClientName(client.name) {
            capturedIdentity = MCPClientIdentity(
                name: normalizedName,
                version: client.version
            )
            clientIdentities[connection] = capturedIdentity
```

and consumed as the limiter's shard key at `MCPCleanToolHandler.swift:167`:

```swift
        let clientID = clientIDProvider() ?? Self.unknownClientSentinel
        try enforceRateLimit(clientID: clientID)
```

The dispatcher's own doc comment at `:28-29` already describes the behavior as
"last-initialize-wins", so the overwrite is known; what is missing is that it also resets
a security control.

**Refutation attempted.** Two adjacent bypasses *are* closed and I confirmed both: an
empty or whitespace-only name normalizes to `nil` rather than becoming its own shard
(`normalizedClientName`, referenced at `:244`), and omitting `clientInfo` entirely
collapses every such caller onto the shared `"unknown"` sentinel
(`MCPCleanToolHandler.swift:147,167`). The rename path is the one that remains.

**Why it matters.** The limiter is the control that bounds how fast an agent — or, given
[SEC-02], a hostile web page — can issue destructive operations. It is also worth noting
the budget counts *operations*, not items: a single permitted `clean` can carry every
item id from a full scan, so even an honored limit does not bound the damage of one call.

**Repro.** Against `swift run GargantuaMCP`: `initialize` as `"a"`, `scan`, `clean` (succeeds),
`clean` again (rejected, retry-after ~60s), `initialize` as `"b"`, `clean` (succeeds
immediately). Expected: the second `clean` stays rejected for the full window.

**Proposed fix.** Bind the rate-limit shard to the connection, not the declared name.
`MCPConnectionID` is already the key for the scan-session cache and for identity eviction,
so the plumbing exists. In `main.swift:283`, change the provider from the client name to
the connection:

```swift
    clientIDProvider: { String(describing: dispatcher.currentCallConnection()) },
```

and keep the declared name for *audit attribution only* — the audit entry's `clientID`
field (`MCPCleanToolHandler.swift:334`) should stay human-meaningful. That means splitting
the single provider into two: `rateLimitKeyProvider` (connection) and `clientIDProvider`
(declared name). Connection-scoped rather than name-scoped because the connection is
established by the transport and cannot be re-declared by the peer.

**Acceptance criteria.**
- [ ] A test asserts that re-`initialize` with a different `clientInfo.name` on the same connection does **not** reset the clean budget.
- [ ] A test asserts the audit entry still records the declared client name, not the connection id.
- [ ] `Scripts/test.sh` green.

---

---

### [SEC-06] The MCP clean consent notification silently disappears in the documented setup

- **Severity:** Medium
- **Confidence:** High (code); the bundled-launch case is **UNVERIFIED — needs runtime repro**
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/MCP/MCPCleanNotificationService.swift:270-284`, `Sources/GargantuaMCP/main.swift:244-247`, `README.md:229-238,273`
- **Depends on:** none

**What's wrong.** The user-facing notification with a cancel window — advertised in the
README as one of `clean`'s guardrails — is silently replaced by a no-op whenever the MCP
server process has no bundle identifier. The README's own recommended client
configuration launches it as `swift run GargantuaMCP`, which has no bundle identifier. In
that configuration destructive cleans proceed with no prompt at all.

**Evidence.** `MCPCleanNotificationService.swift:274-283`:

```swift
    public static func automatic(
        gracePeriod: TimeInterval = 5,
        log: (@Sendable (String) -> Void)? = nil
    ) -> any MCPCleanNotificationService {
        guard Bundle.main.bundleIdentifier != nil else {
            log?("notification service: unbundled process, using Noop (cleans will auto-proceed).")
            return NoopMCPCleanNotificationService()
        }
        return UNCleanNotificationService(gracePeriod: gracePeriod, log: log)
    }
```

The log line states the consequence plainly — "cleans will auto-proceed" — but it goes to
stderr, which the MCP client swallows. `main.swift:244-247` uses this factory:

```swift
private let cleanNotificationService = MCPCleanNotificationFactory.automatic(
    gracePeriod: 5,
    log: stderrLog
)
```

And README:229-238 documents the client config as
`"command": "swift", "args": ["run", "GargantuaMCP", "--", "--stdio"]`, while README:273
promises "The app attempts a local notification with a short cancel window before files
move." Both cannot be true at once for the documented setup.

**Refutation attempted.** I checked whether the app-spawned path is bundled and could not
resolve it from source alone: `MCPServerProcessController` prefers a bundled
`GargantuaMCP` executable and only falls back to `/usr/bin/env swift run GargantuaMCP`
(`MCPServerProcessController.swift:55-72`). Whether a helper executable inside the app
bundle resolves `Bundle.main.bundleIdentifier` to the parent app depends on where it sits
in the bundle, which I did not verify at runtime — hence the UNVERIFIED tag on that half.
The `swift run` half is unambiguous and is the documented developer path.

**Why it matters.** "Fail open" is the wrong default for a consent gate on file deletion.
It also compounds [SEC-02]: the notification is the mitigation I credited for keeping that
finding out of Critical, and here it evaporates precisely in the setup a developer is most
likely to be running.

**Proposed fix.** Fail closed, with an explicit opt-out. Change `automatic` so an
unbundled process *refuses* destructive cleans rather than silently allowing them, unless
the operator passes a flag saying they accept it:

```swift
    public static func automatic(
        gracePeriod: TimeInterval = 5,
        allowsUnattendedClean: Bool = false,
        log: (@Sendable (String) -> Void)? = nil
    ) -> any MCPCleanNotificationService {
        guard Bundle.main.bundleIdentifier != nil else {
            if allowsUnattendedClean {
                log?("notification service: unbundled process with --allow-unattended-clean; cleans auto-proceed.")
                return NoopMCPCleanNotificationService()
            }
            log?("notification service: unbundled process; destructive cleans refused.")
            return RefusingMCPCleanNotificationService()
        }
        return UNCleanNotificationService(gracePeriod: gracePeriod, log: log)
    }
```

with `RefusingMCPCleanNotificationService` returning `.cancelled`, which the existing
handler already renders as a clean per-item failure
(`main.swift:261-272`) rather than a crash. Wire `allowsUnattendedClean` to a new
`--allow-unattended-clean` flag in `MCPRuntimeOptions`. Refusing rather than warning
because a warning on stderr is exactly what already exists and is not reaching anyone.

**Acceptance criteria.**
- [ ] With no bundle identifier and no flag, a non-dry-run `clean` returns per-item failures and no file is moved.
- [ ] With `--allow-unattended-clean`, the prior auto-proceed behavior returns.
- [ ] README's `clean` guardrail list states the notification requires a bundled launch.
- [ ] `Scripts/test.sh` green.

---

---

### Verified, no defect found (security)

These were audited against the threat model and found sound. Recording them so a later
reader does not re-derive the same conclusions.

- **Privileged helper XPC client authentication.**
  `Sources/GargantuaPrivilegedHelper/main.swift:16` uses
  `connection.setCodeSigningRequirement(...)`, which the framework evaluates against the
  peer's **audit token**, not its PID — no PID-reuse TOCTOU window. The target uid comes
  from `NSXPCConnection.current()?.effectiveUserIdentifier` (`:48`), explicitly *not* the
  client-supplied `request.invokingUserID`, so a compromised-but-signed peer cannot
  redirect a Trash move at root. Recursive ownership handover uses `lchown` (`:277-287`),
  which does not follow symlinks. `deleteFromTrash` resolves the Trash directory from the
  uid via `getpwuid` and requires the target be a direct child of it (`:210-234`).
- **Privileged removability allow-list.**
  `Sources/GargantuaCore/Services/PrivilegedRemovabilityPolicy.swift:30-52` is hardcoded,
  not user-editable, and not rule-driven — the file's own comment (`:14-18`) explains why,
  and the reasoning is correct. `isInSubtree` (`:114-116`) requires a `/` boundary, so the
  `/foo` vs `/foobar` prefix trap is closed. Firmlink canonicalization (`:64-70`) is
  applied to both sides of every comparison.
- **Process spawning.** `Sources/GargantuaCore/Services/ProcessSpawner.swift` uses
  `posix_spawn`, **not** `posix_spawnp` (`:84-92`), so `PATH` is never searched for the
  executable; the precondition is documented at `:42-43`. No `sh -c` anywhere in
  `Sources/`. `childEnvironment` (`:145-164`) *prepends* the resolved binary's own
  directory to `PATH` rather than inheriting an untrusted one, and only for the child.
- **Scheduled scans cannot delete.** `Sources/GargantuaScheduler/main.swift` runs
  `ScheduledScanRunner.runIfDue()` only, and a grep for `CleanupEngine`, `removeItem`,
  `trashItem`, and `recycle` across all `ScheduledScanService*.swift` returns nothing.
  Unattended destructive execution is not reachable.
- **AI cannot downgrade a safety classification.** The invariant holds structurally rather
  than by check: engines receive a `ScanRule` synthesized from the already-classified
  result (`AIExplanationController.swift:190-204`, note `safety: result.safety` at `:195`)
  and return prose. No AI service writes a `SafetyLevel` — a grep for `safety =` across
  `CloudAIService*.swift`, `*Explainer*.swift`, and `AIInferenceEngine.swift` returns
  nothing.
- **Licensing secrets.** `LicensePolarConfig.swift` contains only a public organization
  UUID, public API base, checkout link, and portal link — no token. `gitleaks detect`
  over all 951 commits found nothing, confirming the Polar org access token discussed on
  2026-07-13 never landed in the repo.
- **Receipt tamper-resistance.** The activation receipt lives in the Keychain
  (`KeychainLicenseReceiptStorage`, `LicenseReceiptStorage.swift:104-173`) with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and the legacy `license.json`
  migration is one-shot behind a Keychain-backed marker that **fails closed** on any
  non-`errSecItemNotFound` status (`:42-57`). Dropping a forged `license.json` into
  Application Support does not mint licensed status.
- **Sparkle feed.** `Sources/Gargantua/AppUpdateController.swift:89-91` requires the
  `SUFeedURL` to have an `https://` prefix and an `SUPublicEDKey` to be present before
  wiring the updater. Sparkle is pinned to 2.9.2 in `Package.resolved`, i.e. the version
  that patched CVE-2026-47121/47122 (commit `afd3242`).
- **Trial clock resettability is moot, not a finding.** `TrialClock` stores the
  first-launch date in `UserDefaults` (`TrialClock.swift:8-24`), so `defaults delete`
  resets the trial. This is not worth hardening: the source is AGPL and `swift build`
  produces a fully unlocked binary, so trial circumvention has no marginal value over
  simply building from source. The clamp at `:77` correctly prevents clock *backdating*
  from minting more than a full window.

---

---

### Correctness

---

### [BUG-01] Give spawned developer tools a writable working directory — this is the pnpm bug

- **Severity:** High
- **Confidence:** High — **reproduced at the command line this session**
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/ProcessSpawner.swift:50-99`, `Sources/GargantuaCore/Services/DefaultProcessRunner.swift`, `Sources/GargantuaCore/Services/DeveloperToolPreviewAdapter.swift:42-59,123-124`
- **Depends on:** none

**What's wrong.** Gargantua never sets a working directory for the tools it spawns, so a
Finder- or Dock-launched app runs them with the inherited cwd of `/`. `pnpm` writes a
probe temp file into the current directory while resolving its store path, and `/` is
read-only on macOS. The preview command therefore fails with `EROFS` and exit 226, and
the panel renders "Preview failed". Run from a terminal, the cwd is writable and
everything works — which is exactly why this looks like "pnpm is broken in the app but
fine in my shell".

**Evidence.** Reproduced directly, this session, with the same binary the resolver picks:

```
$ cd / && pnpm store path ; echo "EXIT=$?"
[EROFS] EROFS: read-only file system, open '/_tmp_1793_90b689e5f1e15a1116551cc9f472b251'
EXIT=226

$ cd /tmp && pnpm store path ; echo "EXIT=$?"
/Users/Jason/Library/pnpm/store/v11
EXIT=0
```

The cwd is the only variable — same binary, same environment. Note `pnpm --version`
succeeds from `/` (it writes nothing), which is why availability detection passes and the
tool is listed as installed before the preview fails.

No working directory is ever set. A grep for the three ways to do it returns nothing:

```
$ grep -rn "chdir|currentDirectory|addchdir" \
    Sources/GargantuaCore/Services/ProcessSpawner.swift \
    Sources/GargantuaCore/Services/DefaultProcessRunner.swift
(no matches)
```

`ProcessSpawner.spawnInNewProcessGroup` (`:50-99`) configures file actions
(`:107-117`) and spawn attributes (`:119-125`) and never calls
`posix_spawn_file_actions_addchdir_np`.

The failing command is `pnpm store path`, `DeveloperToolPreviewAdapter.swift:123-124`:

```swift
        case .pnpm:
            ["store", "path"]
```

and a non-zero exit becomes a thrown error rendered as a failed card, `:49-59`:

```swift
        guard output.exitCode == 0 else {
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if tool == .docker, DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw DeveloperToolPreviewError.commandFailed(
                tool: tool,
                exitCode: output.exitCode,
                stderr: stderr
            )
        }
```

**Refutation attempted — and one popular theory disproved.** The obvious suspect is the
launchd-minimal `PATH` from a GUI launch, and it is **not** the cause here. Resolution
never consults `PATH` (`posix_spawn`, absolute candidates only), and `ProcessSpawner`
already prepends the resolved binary's directory to the child `PATH`
(`:145-164`) — the fix shipped in 0.4.2 for exactly this class of problem. I also checked
whether the resolver picks a broken binary: on this machine only one pnpm candidate exists
(`~/.local/share/mise/shims/pnpm`, a mise shim), and I verified it works correctly —
`--version` → `11.17.0`, `store path` → exit 0 — **when the cwd is writable**. The shim is
healthy; the cwd is the defect. I also eliminated parser drift: `pnpm store path` emits a
single absolute path line, which the parser handles, and it is never reached because the
command exits non-zero first.

**Why it matters.** This breaks a headline feature in the shipped app for every pnpm user
who launches Gargantua the normal way. It is also latent for any other tool that touches
the cwd — the fix is one line and immunizes all of them.

**Repro.**
1. Launch the built `.app` from Finder (not `swift run`, and not from a terminal — the cwd
   is what matters).
2. Developer Tools → Scan tools.
3. The pnpm card shows "Preview failed … exit 226 … EROFS: read-only file system".

**Proposed fix.** Set the child's working directory to the user's home directory in
`ProcessSpawner`. Add to `configureFileActions`, or as its own step in
`spawnInNewProcessGroup` before the spawn:

```swift
    /// Developer tools are spawned with whatever cwd the app inherited — `/` for a
    /// Finder/Dock launch, which is read-only. `pnpm store path` writes a probe temp
    /// file into the cwd and dies with EROFS there. Home is always writable and is a
    /// neutral place for a tool that has no project context.
    private static func configureWorkingDirectory(
        _ fileActions: inout posix_spawn_file_actions_t?
    ) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try check(posix_spawn_file_actions_addchdir_np(&fileActions, home))
    }
```

called alongside the existing `try configureFileActions(...)` at `:71`.

Choosing the home directory over a fresh temp directory because home always exists, needs
no cleanup, and is what a user running `pnpm store path` by hand would most likely be in;
a per-spawn temp directory would add a lifecycle to manage for no additional safety.

**Acceptance criteria.**
- [ ] A test at `Tests/GargantuaCoreTests/Services/ProcessSpawnerTests.swift` spawns `/bin/pwd` and asserts stdout is the user's home directory, not the test runner's cwd.
- [ ] Launched from Finder, the Developer Tools pnpm card renders a store path instead of "Preview failed".
- [ ] `Scripts/test.sh` green.

---

---

### [BUG-02] Stop hardcoding the pnpm store's reclaimable size to zero

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/DeveloperToolPreviewAdapter.swift:150-176`
- **Depends on:** [BUG-01] (you cannot see this until the preview succeeds)

**What's wrong.** Even once [BUG-01] is fixed and the pnpm preview works, the pnpm row
reports 0 bytes reclaimable — always. The adapter explicitly overwrites the parsed value
with zero, while `go`, `npm`, and `yarn` in the very next branch get real measured
directory sizes.

**Evidence.** `DeveloperToolPreviewAdapter.swift:150-162`:

```swift
        let parsed = parsePreview(tool: tool, commandPreview: commandPreview, output: output)
        switch tool {
        case .pnpm:
            return parsed.map { item in
                item.id == "pnpm-store" ? item.withReclaimableBytes(0) : item
            }
        case .go, .npm, .yarn:
            let sizedIDs: Set<String> = ["go-build-cache", "go-module-cache", "npm-cache", "yarn-cache"]
            return parsed.map { item in
                guard sizedIDs.contains(item.id), let path = item.detail else {
                    return item
                }
                let url = URL(fileURLWithPath: path)
```

**Why it matters.** The whole value of the panel is telling the user how much a cleanup
will reclaim. A permanent "0 bytes" on pnpm is worse than no number: it actively tells the
user there is nothing to reclaim when a pnpm store is routinely several gigabytes. Note
`pnpm store prune` genuinely cannot be measured in advance — it removes only unreferenced
packages — so zero is defensible as "unknown", but it is displayed as a size, not as
unknown.

**Proposed fix.** Return `nil` rather than `0` so the row renders the existing
"estimate unavailable" affordance instead of a false zero. `DeveloperToolCleanupOperation`
already has `estimateUnavailableDetail` copy for exactly this case (used at
`DeveloperToolsExecutionFlow.swift:32-34`), so the UI path exists.

```swift
        case .pnpm:
            // `pnpm store prune` removes only unreferenced packages, so the store's
            // total size is not the reclaimable size. Report unknown rather than a
            // zero the user will read as "nothing to clean".
            return parsed.map { item in
                item.id == "pnpm-store" ? item.withReclaimableBytes(nil) : item
            }
```

Preferring "unknown" over measuring the whole store because the store total would be a
*wrong* number in the other direction — it would promise gigabytes that a prune will not
free. This requires `withReclaimableBytes` to accept an optional; check its signature and
widen if needed.

**Acceptance criteria.**
- [ ] The pnpm row shows the estimate-unavailable copy, not "0 bytes".
- [ ] A test asserts `previewItems(tool: .pnpm, …)` yields `reclaimableBytes == nil` for `pnpm-store`.
- [ ] `Scripts/test.sh` green.

---

---

### [BUG-03] Verify local-model deletion before reporting it as deleted

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Services/ModelDownloadManager.swift:88-91,121-123`
- **Depends on:** none

**What's wrong.** Deleting the local MLX model discards the removal error and then reports
success unconditionally. If the directory cannot be removed, Settings says "Not downloaded"
while roughly 680 MB remains on disk.

**Evidence.** `ModelDownloadManager.swift:88-91`:

```swift
    public func deleteModel() {
        removeModelDirectory()
        state = .notDownloaded
    }
```

and `:121-123`:

```swift
    private func removeModelDirectory() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }
```

The `try?` swallows the error and `state` is assigned regardless of outcome.

**Why it matters.** This is optimistic UI that never reconciles, in a disk-cleaning
application, about the largest single artifact the app itself downloads. The user believes
they reclaimed 680 MB and did not, and because the state now says "Not downloaded" the app
offers to download it again rather than offering to remove it. The failure is also
permanent from the UI's perspective — nothing re-checks the directory.

**Repro.** Make `modelDirectory` undeletable (e.g. `chflags uchg` on a fixture directory
under `/tmp/gargantua-audit-fixtures/` pointed at by an injected path), call `deleteModel()`,
and observe `state == .notDownloaded` with the directory still present.

**Proposed fix.** Make removal report its outcome and only advance state on success. The
`state` enum already has a `.failed(String)` case rendered by `SettingsNoticeRow`, so the
UI path exists:

```swift
    public func deleteModel() {
        do {
            try FileManager.default.removeItem(at: modelDirectory)
            state = .notDownloaded
        } catch CocoaError.fileNoSuchFile {
            // Already gone — the desired end state, not a failure.
            state = .notDownloaded
        } catch {
            state = .failed("Could not remove the local model: \(error.localizedDescription)")
        }
    }
```

Treating "already absent" as success explicitly, because `removeModelDirectory` is also
called on the cancel/cleanup path at `:85` where the directory legitimately may not exist —
folding that into the generic failure branch would produce a spurious error there.

**Acceptance criteria.**
- [ ] A failing removal leaves `state == .failed(...)` and the Settings row shows the message.
- [ ] Deleting a model that is already absent still results in `.notDownloaded`, no error.
- [ ] Both branches covered by a test. Note the suite is already split by domain — `ModelDownloadManagerHashingTests.swift`, `…ManifestTests.swift`, `…MarkerTests.swift` (see commit `6516aaa`) — so add a peer `ModelDownloadManagerDeletionTests.swift` rather than reviving a single monolithic file.
- [ ] `Scripts/test.sh` green.

---

---

### UX

---

### [UX-05] Stop rendering a failed Dashboard triage as a clean bill of health

- **Severity:** High
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/DashboardView.swift:263-266`, `Sources/GargantuaCore/Views/Dashboard/DashboardTriageEvidenceView.swift:75-93`
- **Depends on:** none

**What's wrong.** When the Dashboard's triage scan throws, the error is recorded into the
progress object and the scan is marked finished with zero items. The triage evidence view
never reads those errors, so it falls through to its empty state — which is a green
`checkmark.circle` and the sentence "The lightweight local pass did not find safe or
review-tier cleanup groups." A crashed scan is therefore presented to the user as a
successful scan that found nothing wrong.

**Evidence.** The error is captured and discarded, `DashboardView.swift:263-266`:

```swift
            } catch {
                progress.recordError(error.localizedDescription)
                progress.finish(itemsFound: 0)
            }
```

The view that renders the outcome, `Dashboard/DashboardTriageEvidenceView.swift:75-90`:

```swift
            Image(systemName: hasRunTriage ? "checkmark.circle" : "list.bullet.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasRunTriage ? GargantuaColors.safe : GargantuaColors.accent)
            ...
                Text(hasRunTriage ? "No triage groups found" : "No triage evidence yet")
```

`hasRunTriage` is true after a failed run just as after a successful one, and the tint is
`GargantuaColors.safe` — the same green the Trust Layer uses for "safe to delete". A grep
for `errors` across the entire file returns nothing, so the recorded error has no consumer.

**Refutation attempted.** I checked whether the error surfaces anywhere else on the
Dashboard before concluding it is invisible — there is no banner, no toast, and no alert
bound to `session` for this path. I also confirmed the correct pattern exists elsewhere in
the codebase, so this is an omission rather than a house style: `DeepCleanView.swift:189-199`
renders scan errors from `scanProgress.errors` in its idle view.

**Why it matters.** This is worse than missing feedback — it is *wrong* feedback, on the
first screen the user sees, in an app whose entire pitch is trust. A user whose triage
silently fails (missing Full Disk Access, an unreadable directory, a rules-load failure)
is told their Mac is clean. They will believe it. Of everything in this audit, this is the
finding most likely to make a user distrust the product once they discover it.

**Repro.** Inject a failing scan adapter into `DashboardView`'s triage path, or revoke Full
Disk Access and run triage on a machine where that causes the adapter to throw. Observe the
green checkmark and "No triage groups found". Expected: an error state naming the failure.

**Proposed fix.** Give `DashboardTriageEvidenceView` an error branch, driven by the same
`scanProgress.errors` array `DeepCleanView` already uses. Pass the errors in alongside
`hasRunTriage`:

```swift
    private var emptyContent: some View {
        if !scanErrors.isEmpty {
            return triageFailedContent(errors: scanErrors)
        }
        ...
    }
```

with `triageFailedContent` using `exclamationmark.triangle` tinted `GargantuaColors.review`
and copy naming the first error plus a Retry affordance. Reusing the existing
`scanProgress.errors` channel rather than adding a new error property because the value is
already recorded at `DashboardView.swift:264` and is simply unread — this is a wiring fix,
not new state.

**Acceptance criteria.**
- [ ] With a scan that throws, the triage card renders an error state and **no** green checkmark.
- [ ] With a scan that succeeds and legitimately finds nothing, the green checkmark still renders.
- [ ] A test at `Tests/GargantuaCoreTests/Views/DashboardTriageEvidenceTests.swift` asserts the two cases render different states.
- [ ] `Scripts/test.sh` green.

---

---

### [UX-06] Surface failed deletions in the Duplicate Finder

- **Severity:** High
- **Confidence:** High
- **Effort:** M (half day)
- **Files:** `Sources/GargantuaCore/Views/DuplicateFinderContainerView.swift:120-136`
- **Depends on:** none

**What's wrong.** The Duplicate Finder consumes only the successful half of its cleanup
result. `result.failedItems` is never rendered — there is no summary view, no banner, and
no alert. Failed items are simply not removed from the selection, and `refreshResults()`
prunes only paths that no longer exist, so a file that failed to delete quietly reappears
in the list as though nothing happened. There is also no busy state while `engine.clean`
runs.

**Evidence.** `DuplicateFinderContainerView.swift:127-136`:

```swift
        let result = await engine.clean(items, method: method)
        do {
            try AuditWriter().record(result: result)
        } catch {
            duplicateFinderContainerLogger.warning("Failed to write audit entry: \(error.localizedDescription)")
        }
        selectedIDs.subtract(result.succeededItems.map(\.item.id))
        refreshResults()
        onCleanupCompleted?(result)
```

`result.failedItems` appears nowhere in the file. Contrast every other destructive surface,
which routes its result into `CleanupSummaryView` — the component that exists precisely to
show succeeded/failed breakdowns and offers the "retry failed" path
(`CleanupSummaryView.swift:114`).

**Refutation attempted.** I checked whether the failure reaches the user by another route.
`onCleanupCompleted?(result)` feeds the dashboard's aggregate counters, not a per-item
failure UI. `state.isRefreshing` is set but never read by any view, so even the refresh is
invisible. The license gate *is* correctly present on this path
(`:123-126`), so this is specifically a result-reporting gap, not a missing guard.

**Why it matters.** This is the Duplicate Finder — the one surface where the audit brief
correctly notes that deleting the wrong copy is catastrophic and unrecoverable. A user who
selects one copy of each duplicate pair, hits Send to Trash, and has half the operations
fail on permissions gets no signal at all; the list looks partly unchanged and they have no
way to know whether the file they kept is the one they meant to keep. Silence is the worst
possible outcome here.

**Repro.**
1. Duplicate Finder → scan a scope containing a file the user cannot delete (a root-owned
   file, or one inside a directory without write permission). Build a fixture under
   `/tmp/gargantua-audit-fixtures/` rather than using real data.
2. Select it and confirm Send to Trash.
3. Observe: no error, no summary; the row is still present after refresh.

**Proposed fix.** Route the result into the shared `CleanupSummaryView`, matching the other
five destructive surfaces, and add a cleaning phase to the container state so the results
view is not inert during `engine.clean`. The container already owns a phase enum
(idle/scanning/results/error) — add `.cleaning` and `.summary(CleanupResult)` cases and
render the existing summary component for the latter. Reusing `CleanupSummaryView` rather
than adding a bespoke banner because it already implements the succeeded/failed breakdown,
the per-failure reason copy, and the retry path — all of which this surface currently lacks
entirely.

**Acceptance criteria.**
- [ ] After a cleanup where at least one item fails, the Duplicate Finder shows a summary listing the failures with reasons.
- [ ] A spinner or cleaning phase renders while `engine.clean` is in flight.
- [ ] A test asserts a `CleanupResult` containing a failed item drives the summary state rather than returning straight to results.
- [ ] `Scripts/test.sh` green.

---

---

### [UX-01] Make Disk Explorer's up-navigation reachable; stop Escape destroying the session

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/DiskExplorerView+Layout.swift:11-29`, `Sources/GargantuaCore/Models/DiskExplorerState.swift:135-144,202-206`, `Sources/GargantuaCore/Views/DiskExplorerView.swift:48,125-153`
- **Depends on:** none

**What's wrong.** Drill-out from the Disk Explorer *exists*, but the two affordances a
user reaches for first do the wrong thing, and the one that does the right thing is
invisible. Escape and the header Back button both call `exitToIdle()`, which resets the
breadcrumb to Home, wipes the per-directory `pathCache`, and returns to the pre-scan CTA.
The genuine "up one level" control is ⌘[, and its button is rendered at zero size, zero
opacity, and hidden from accessibility.

**Evidence.** The entire keyboard layer, `DiskExplorerView+Layout.swift:11-29`:

```swift
    @ViewBuilder
    var keyboardShortcutLayer: some View {
        HStack(spacing: 0) {
            Button("Back") { state.exitToIdle() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Up") {
                guard state.pathStack.count > 1 else { return }
                state.navigateTo(index: state.pathStack.count - 2)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state.pathStack.count <= 1)
            Button("Refresh") { state.refreshCurrent() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isLoading)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
```

What Escape actually does, `DiskExplorerState.swift:135-144`:

```swift
    public func exitToIdle() {
        pathCache = [:]
        items = []
        clearExpansion()
        maxSize = 1
        displayModeIsExplicit = false
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        isLoading = false
        phase = .idle
    }
```

The header Back button is wired to the same call — `DiskExplorerView.swift:48`:
`onBack: { exitToIdle() }`.

So the working up-navigation is the breadcrumb (`DiskExplorerView.swift:125-153`, each
crumb a `Button` calling `navigateTo(index:)`) and ⌘[. Nothing teaches either: the
treemap hint view says only "Click any tile to drill in".

**Refutation attempted.** I checked for a context-menu "up" entry (`DirectoryRowView.swift:96-104`
and `DirectoryTreemapCellView.swift:52-60` offer only Reveal in Finder and Move to Trash),
for ⌘↑ (not bound anywhere), and for a `..` parent row (does not exist). I also confirmed
the root case is safe rather than crashy: at depth 1 the last crumb's button is
`.disabled` (`DiskExplorerView.swift:147`) and `navigateTo` guards
`index < pathStack.count - 1` (`DiskExplorerState.swift:203`). The finding is
discoverability and Escape's semantics, not a missing capability.

**Why it matters.** A treemap that is easy to descend and hard to ascend is the classic
disk-visualizer failure. The concrete harm is Escape: a user ten levels deep who taps
Escape expecting Finder's "go up" loses the entire drill-down *and* the size cache, so
returning costs a full rescan of every level. That is a destructive-feeling action on the
most reflexive key on the keyboard.

**Repro.**
1. Disk Explorer → Scan. Drill three levels deep by clicking treemap tiles.
2. Press Escape.
3. Observe: back at the pre-scan idle CTA, breadcrumb gone, all cached sizes discarded.
   Expected: up one level to the parent directory.

**Proposed fix.** Three changes, all small.

(a) Rebind Escape to "up one level", falling back to exit only at the root. In
`DiskExplorerView+Layout.swift`, replace the `Back` button's action:

```swift
            Button("Back") {
                if state.pathStack.count > 1 {
                    state.navigateTo(index: state.pathStack.count - 2)
                } else {
                    state.exitToIdle()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
```

(b) Give ⌘[ a visible control. Add an "Up" button to the breadcrumb row in
`DiskExplorerView.swift:125-153`, immediately left of the first crumb, showing
`chevron.left`, disabled at depth 1, with `.help("Up one level (⌘[)")` so the shortcut is
discoverable by hover.

(c) Stop hiding the shortcut layer from assistive tech. Drop `.accessibilityHidden(true)`
at `DiskExplorerView+Layout.swift:28` — with (b) in place the Up action has a real
control, and ⌘R Refresh should be in the accessibility tree regardless.

Rebinding Escape rather than adding a separate key because Escape is the key users
already press, and the current binding is the actively harmful one; leaving it as
"destroy session" and adding a *third* control would not stop the data loss.

**Acceptance criteria.**
- [ ] At depth > 1, Escape moves up exactly one crumb and `pathCache` is not cleared.
- [ ] At depth 1 (Home), Escape still returns to the idle phase.
- [ ] A visible, labeled Up control appears in the breadcrumb row and is disabled at depth 1.
- [ ] Tests at `Tests/GargantuaCoreTests/Models/DiskExplorerStateTests.swift` assert `navigateTo(index: count - 2)` preserves `pathCache` and pops one crumb.
- [ ] `Scripts/test.sh` green.

---

---

### [UX-02] Make the "Others (N)" aggregate reachable instead of a dead end

- **Severity:** Medium
- **Confidence:** High
- **Effort:** M (half day)
- **Files:** `Sources/GargantuaCore/Views/DiskExplorerView+Layout.swift:102-141`, `Sources/GargantuaCore/Views/DirectoryRowView.swift:32-39,44,134-143`, `Sources/GargantuaCore/Views/DiskExplorerView.swift:215-217,252-288`
- **Depends on:** [UX-01] (same surface; fix together)

**What's wrong.** In any directory with at least 12 sized children, every child smaller
than 1% of the largest is folded into a synthetic "Others (N)" entry. That entry is inert:
it cannot be clicked, expanded, revealed in Finder, or drilled into — and because the list
view renders the same collapsed set as the treemap, switching display mode does not
recover the hidden folders. They are unreachable from the Disk Explorer entirely.

**Evidence.** The collapse, `DiskExplorerView+Layout.swift:102-107`:

```swift
    static func collapseSmall(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let sized = items.filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
        guard sized.count >= 12 else { return items }
        guard let largest = sized.map(\.size).max(), largest > 0 else { return items }

        let threshold = max(largest / 100, 1)
```

The inert row, `DirectoryRowView.swift:32-39`:

```swift
        Button {
            if item.isOthersAggregate {
                // Aggregate row is informational; matches treemap behavior.
            } else if item.isPermissionDenied {
                openURL(Self.fullDiskAccessURL)
            } else if !isFilesAggregate {
                onDrillDown()
            }
```

No expand chevron either (`:44` excludes `isOthersAggregate`), and no context-menu
actions (`canRevealInFinder` at `:134-139` excludes it, and `canTrash` derives from it).
`drillDown` refuses the item independently at `DiskExplorerState.swift:196`.

Both modes share the collapsed set — `DiskExplorerView.swift:215-217`:

```swift
    private var displayItems: [DirectoryItem] {
        DiskExplorerView.collapseSmall(state.items)
    }
```

used by `treemapView` at `:227` and by `listView` at `:259`, the latter with a comment at
`:253-256` confirming the sharing is deliberate.

**Why it matters.** The collapse is well-motivated for the treemap — the code comment at
`:93-101` correctly explains that unlabelable 60×60 tiles are worse than a rollup. The bug
is applying it to the *list*, where a row is legible at any size and where the whole point
is enumeration. On a real `~/Library` (dozens of children, one or two huge) this silently
hides most subdirectories from a tool whose job is "understand where space goes".

**Repro.**
1. Disk Explorer → Scan → drill into a directory with ≥12 sized children where one
   dominates (`~/Library` is the reliable case).
2. Switch to List mode.
3. Observe an "Others (N)" row. Click it, try its disclosure chevron, right-click it —
   nothing is available, and the N folders it represents appear nowhere in either mode.

**Proposed fix.** Two changes, in order of value.

(a) Do not collapse in list mode. In `DiskExplorerView.swift`, split the accessor:

```swift
    /// Treemap-only rollup: sub-1% tiles are unlabelable, so they collapse.
    private var treemapItems: [DirectoryItem] {
        DiskExplorerView.collapseSmall(state.items)
    }

    /// The list enumerates. A row is legible at any size, so nothing is hidden.
    private var listItems: [DirectoryItem] {
        state.items
    }
```

pointing `treemapView:227` at `treemapItems` and `listView:259` at `listItems`.

(b) Make the treemap's aggregate an escape hatch rather than a dead end: give the
"Others (N)" tile and row a click action that switches to list mode
(`state.setDisplayMode(.list)`), and change its `help`/accessibility label to "N smaller
folders — show as list". That preserves the treemap's legibility while guaranteeing the
data is always one click away.

Doing (a) rather than making the aggregate expandable in place because the list already
scrolls and already sorts largest-first; an expandable synthetic node adds a second
hierarchy concept to the state model for no gain.

**Acceptance criteria.**
- [ ] In list mode, a directory with ≥12 sized children shows every child as its own row and no "Others (N)" row appears.
- [ ] In treemap mode, the "Others (N)" tile still appears and clicking it switches the view to list mode showing those folders.
- [ ] A test at `Tests/GargantuaCoreTests/Views/DiskExplorerCollapseTests.swift` asserts `collapseSmall` is not applied to the list path — e.g. given 20 items where 15 are sub-1%, the list item count is 20 and the treemap item count is 6.
- [ ] `Scripts/test.sh` green.

---

---

### [UX-03] Stop telling users the MCP SSE endpoint is read-only

- **Severity:** Medium
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/MCPTransportSettingsSection.swift:18`
- **Depends on:** none (but read with [SEC-02] and [DOC-01])

**What's wrong.** The Settings → Network toggle that exposes the MCP SSE endpoint
describes it to the user as exposing read-only tools. It exposes `clean`, which deletes
files.

**Evidence.** `MCPTransportSettingsSection.swift:16-19`:

```swift
        SettingsSectionContainer(
            "MCP Transport",
            subtitle: "Local Server-Sent Events endpoint exposing read-only Gargantua tools to MCP clients."
        ) {
```

Against `Sources/GargantuaMCP/main.swift:53-58` (both registries), `:286`
(`register(tool: .clean, …)`), and `:308-318` (same dispatcher handed to the SSE
transport).

**Why it matters.** This is the consent surface for the entire network-exposure decision.
A user weighing "should I turn this on" is given a materially false description of the
blast radius — and, per [SEC-02], on localhost that endpoint has no authentication at all.
Of everything in this audit, this is the sentence most likely to have caused a user to
make a decision they would not otherwise have made.

**Proposed fix.** Tell the truth, and say what protects them:

```swift
            subtitle: "Local Server-Sent Events endpoint for MCP clients. Exposes scan and "
                + "analysis tools plus the guarded `clean` tool, which can delete files. "
                + "Protected items are always rejected."
```

If [DOC-01]'s optional `--read-only` flag is implemented, add a toggle here and make the
subtitle conditional — that is the better end state, since it lets a user who only wants
agent-driven *scanning* have exactly that.

**Acceptance criteria.**
- [ ] The Settings subtitle no longer contains the words "read-only" while `clean` is registered on the SSE transport.
- [ ] The subtitle names file deletion explicitly.

---

---

### [UX-07] Batch: nine post-action failures that are logged but never shown

- **Severity:** Medium
- **Confidence:** High
- **Effort:** M (half day for the batch)
- **Files:** see the table below
- **Depends on:** none

**What's wrong.** Nine distinct user-triggered actions handle their failure by writing to
the log and nothing else. They share one root cause — the codebase is rigorous about *scan*
failures and lax about everything that happens *after* an action — so they are cheaper to
fix as one pass than as nine tickets.

**Evidence.** Each verified this session:

| Action | Silent failure | file:line |
| --- | --- | --- |
| Activation via `gargantua://activate` deep link | `logger.warning("Deep-link activation failed: …")`, no UI | `Views/Licensing/LicenseActivationLink.swift:28-30` |
| Audit-trail write after cleanup (6 sites) | `logger.warning("Failed to write audit entry: …")` | `DeepCleanView.swift:263`, `DevArtifactScanView.swift:202`, `AIModelsView.swift:306`, `DuplicateFinderContainerView.swift:132`, `FileHealthContainerCleanupFlow.swift:113`, `CleanupSummaryView.swift:127` |
| Disk Explorer row → Move to Trash | `recycle([url]) { _, _ in … }` discards the error | `DirectoryRowView.swift:151-156` |
| Disk Explorer tile → Move to Trash | same discard | `DirectoryTreemapCellView.swift:86-91` |
| "View Audit Trail" button | `if fileExists { reveal }`, no else — inert when the audit write failed | `CleanupSummaryView+Sections.swift:378-383` |
| Settings → "Deactivate this Mac" | `try? await store.deactivate()`; no spinner, no result | `GargantuaLicensing/LicenseGate.swift:73-75`, `Views/Licensing/LicenseSettingsSection.swift:49-57` |
| Rules pane when bundled rules fail to load | `catch { categories = [] }` — looks like "no rules exist" | `RuleViewerView.swift:184-187,238-240` |
| Permissions → helper "Open Settings" | `try?` discards `register()` failure | `PermissionsSettingsSection.swift:62-64` |
| Dashboard → dismiss scheduled-scan card | `try?` on the acknowledge write; card returns next launch | `DashboardView.swift:325-328` |

The Disk Explorer discard, quoted from `DirectoryRowView.swift:151-156`:

```swift
    private func moveToTrash() {
        let url = URL(fileURLWithPath: item.path)
        NSWorkspace.shared.recycle([url]) { _, _ in
            DispatchQueue.main.async { onItemTrashed?() }
        }
    }
```

Both completion parameters — the resulting URLs and the `Error?` — are discarded.

**Why it matters.** Individually these are small. Two are not: the **deep-link activation
failure** is paying-customer-facing and belongs to the same family as the
`activationLimitReached` copy that dead-ended a real customer in July, and the **audit-write
silence** undermines the specific guarantee the product markets — the summary card invites
the user to "View Audit Trail" for a record that may not exist, and the button then does
nothing (two rows of this table compounding).

**Proposed fix.** Three mechanical passes, in descending value:
1. Deep-link activation: present the Unlock sheet with `LicenseErrorCopy.message(for: error)`,
   reusing the paste-key path's existing error rendering.
2. Audit-write failures: add one warning row to `CleanupSummaryView` — "This cleanup could
   not be recorded to the audit trail" — driven by a `auditWriteFailed: Bool` on the summary
   input, and disable the "View Audit Trail" button when the file is absent.
3. Trash failures and the remaining `try?` sites: capture the error and route it to each
   surface's existing error channel. Disk Explorer has none, so add an `@State` alert
   following the `lastError` pattern Background Items already uses
   (`BackgroundItemsView.swift:102-112`).

**Acceptance criteria.**
- [ ] A failed deep-link activation presents a sheet naming the reason.
- [ ] A cleanup whose audit write fails shows a warning row, and "View Audit Trail" is disabled.
- [ ] A failed Move to Trash in Disk Explorer raises an alert rather than silently refreshing.
- [ ] `Scripts/test.sh` green.

---

---

### [UX-04] Replace the three bare `ProgressView()` spinners with `AccretionDiskView`

- **Severity:** Low
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/Gargantua/MainContentView.swift:137,207,238`
- **Depends on:** none

**What's wrong.** Three sidebar destinations render a bare system `ProgressView()` as their
placeholder while the SwiftData store is still loading. On this app's void background the
system spinner is effectively invisible, so the user who clicks Profiles, Rules, or
Settings before persistence is ready sees an empty black pane rather than a loading state.
`AccretionDiskView` is the project's spinner for exactly this reason and is used correctly
everywhere else.

**Evidence.** All three are the same shape. `MainContentView.swift:133-139`:

```swift
                            case "profiles":
                                if let persistence {
                                    ProfileContainerView(persistence: persistence)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
```

repeated verbatim for `case "rules"` (`:200-209`) and `case "settings"` (`:229-239`). The
containing `Group` sits on `GargantuaColors.void_`.

**Refutation attempted.** I grepped the whole of `Sources/` for `ProgressView` and got 11
hits; 8 are false positives — helper functions whose *names* contain "ProgressView"
(`cleanupProgressView`, `downloadProgressView`, `scanProgressView`), one comment
(`DirectoryTreemapCellView.swift:152`), and two inside `AlertListView.swift`, which
[CPX-01] establishes is dead code. These three are the only live bare `ProgressView()`
instances in the app. Every other loading state in the codebase already uses
`AccretionDiskView` — for example `DiskExplorerView+Layout.swift:55` and
`DirectoryRowView.swift:169`.

**Why it matters.** Low severity because the window is short — it only shows before
`PersistenceController` finishes loading. It is worth fixing anyway because the failure
mode is indistinguishable from a hang: a black pane gives the user no reason to wait.

**Proposed fix.** Extract one placeholder and use it at all three sites, matching the
idle-spinner styling already used elsewhere:

```swift
    private var persistenceLoadingView: some View {
        AccretionDiskView(activityRate: 18, size: 48, color: GargantuaColors.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading")
    }
```

Extracting rather than replacing inline three times so a fourth persistence-gated
destination cannot reintroduce the bare spinner.

**Acceptance criteria.**
- [ ] `grep -rn "ProgressView()" Sources/Gargantua/ Sources/GargantuaCore/` returns no results outside dead code.
- [ ] Profiles, Rules, and Settings each show a visible spinner before persistence loads.

---

---

### Complexity

---

### [CPX-01] Delete three orphaned SwiftUI views

- **Severity:** Low
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/AlertListView.swift` (190 lines, whole file), `Sources/GargantuaCore/Views/ScanRootsSettingsSupport.swift:4`
- **Depends on:** none

**What's wrong.** Three view types have zero references anywhere in `Sources/` outside
their own declaring file and zero references in `Tests/`.

**Evidence.** Reference counts taken this session:

| Symbol | Declared | Referencing files in `Sources/` | Test files |
| --- | --- | --- | --- |
| `AlertListView` | `Views/AlertListView.swift:8` (`public struct`) | only its own file | 0 |
| `AlertRowView` | `Views/AlertListView.swift:156` | only its own file (used by `AlertListView`) | 0 |
| `ScanRootErrorRow` | `Views/ScanRootsSettingsSupport.swift:4` | only its own file | 0 |

`AlertListView.swift` is 190 lines and dies entirely; `AlertRowView` is dead transitively
because its only consumer is `AlertListView`.

**Refutation attempted.** SwiftUI views can look dead when referenced only from a parent's
body, so a bare grep is not sufficient evidence on its own — I checked for each symbol
across all of `Sources/` and `Tests/`, not just for a declaration. `AlertItem`, the model
`AlertListView` renders, *is* alive elsewhere (notably `AlertItem.formatBytes`, patched in
`e2207c6`), which is probably why the view survived: the model kept the file feeling used.

**Why it matters.** Low. It is 230 lines of view code that will be maintained, linted, and
read by future contributors for no reason, and it dilutes the "is this used?" signal for
the next person doing this analysis.

**Proposed fix.** Delete `Sources/GargantuaCore/Views/AlertListView.swift` outright and
remove the `ScanRootErrorRow` struct from `ScanRootsSettingsSupport.swift`. Confirm the
build still links both configurations, since `AlertListView` is `public` and could in
principle be a library consumer's entry point — Gargantua ships `GargantuaCore` as a
library product (`Package.swift:26`), so if you care about that theoretical consumer,
deprecate for one release instead. Recommending deletion: there is no external consumer of
this library today.

**Acceptance criteria.**
- [ ] `swift build` and `GARGANTUA_LICENSING=1 swift build` both succeed after deletion.
- [ ] `Scripts/test.sh` still reports 2410 passing tests.
- [ ] `grep -rn "AlertListView\|AlertRowView\|ScanRootErrorRow" Sources/ Tests/` returns nothing.

---

---

### Tooling

---

### [TOOL-01] Decide whether trivy is live, then either wire it into CI or delete its config

- **Severity:** Low
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `trivy.yaml`, `.github/workflows/ci.yml`
- **Depends on:** none

**What's wrong.** `trivy.yaml` is tracked in git and the README advertises trivy as an
active defense ("Dependency scanning: `trivy fs` plus an OSV wrapper run against
`Package.resolved`"), but no workflow invokes trivy. The four workflows are `ci.yml`
(rules drift, lint, tests+coverage), `mutation.yml`, `release.yml`, and `rules-sync.yml`.
The OSV half is real — `Scripts/osv-spm-scan.sh` exists and ran clean this session — but
nothing runs trivy on any schedule or trigger.

**Evidence.** `.github/workflows/ci.yml` defines exactly three jobs: `rules-drift`
(`:10-21`), `lint` (`:23-38`), `test` (`:40-99`). No trivy step. `trivy.yaml` was last
touched 2026-04-25.

**Why it matters.** Low severity because OSV covers the same ground and reported clean.
It matters as a docs-accuracy issue: SECURITY.md-adjacent claims in the README should be
true, and a config file that looks like a control but runs nowhere is worse than no config.

**Proposed fix.** Prefer deleting `trivy.yaml` and dropping the trivy line from the
README's security section, keeping the OSV wrapper as the single dependency scanner —
two scanners over 17 SwiftPM packages is redundant, and the one that runs is the one
worth keeping. If instead you want trivy live, add to `ci.yml` under a new job:

```yaml
  deps:
    name: Dependency scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: Scripts/osv-spm-scan.sh
```

which at least makes the *real* scanner a gate — today `osv-spm-scan.sh` is only ever run
by hand.

**Acceptance criteria.**
- [ ] Either `trivy.yaml` is gone and the README no longer claims trivy runs, or a workflow invokes trivy on pull requests.
- [ ] `Scripts/osv-spm-scan.sh` runs in CI on pull requests.

---

---

### [TOOL-02] Clear the 433 Swift-6-fatal warnings in the test target

- **Severity:** Low
- **Confidence:** High
- **Effort:** M (half day)
- **Files:** `Tests/GargantuaCoreTests/Services/MaintenanceEngineAuditHookTests.swift:14,95,101,113,119`, `Tests/GargantuaCoreTests/Views/ProcessInventorySessionTests.swift:56-63`, `Tests/GargantuaCoreTests/Views/BackgroundItemsSessionTests.swift:228,257,260`, `Tests/GargantuaCoreTests/Services/ClaudeCodeAgentProcessExecutorTests.swift:139`, `Tests/GargantuaCoreTests/Services/MCP/MCPExplainToolHandlerInputTests.swift:69,81`, `Tests/GargantuaCoreTests/Services/CloudAITransportTests.swift:68`
- **Depends on:** none

**What's wrong.** A full recompile emits 1225 warnings, every one of them in `Tests/`.
433 are `this is an error in the Swift 6 language mode`: `NSLock.lock()`/`unlock()` and
`DispatchSemaphore.wait()` called from async contexts, and `var` captured and mutated
inside concurrent closures. Production code emits zero warnings.

**Evidence.** Counts from `swift build --build-tests` after touching every source file:

```
767  '#require(_:_:)' is redundant because '…' never equals 'nil'
240  instance method 'lock'/'unlock' is unavailable from asynchronous contexts   [Swift 6 error]
 97  instance method 'wait' is unavailable from asynchronous contexts            [Swift 6 error]
 96  mutation of captured var in concurrently-executing code                     [Swift 6 error]
 25  result of call to 'withLock' is unused
```

(The per-warning counts are inflated by repeated emission across compilation units; the
distinct source locations are the ~20 listed in **Files** above.)

**Why it matters.** Not a runtime risk — this is test-only code and the suite passes. It
is a migration wall: the package is `swift-tools-version: 5.10` and any move to the Swift
6 language mode turns 433 warnings into build failures at once. Fixing them now, while
they are understood, is much cheaper than fixing them under a migration deadline.

**Proposed fix.** Three mechanical substitutions, no design decisions:
- `NSLock.lock()/unlock()` in async test helpers → `Mutex` or an `actor` holding the
  state; or hoist the locked section into a synchronous `withLock { }` whose result is
  used.
- `DispatchSemaphore.wait()` in async tests → `await` the `Task` handle the test already
  has (several of these tests were changed to store task handles in `8a735eb`, "join
  stored session tasks instead of deadline polls" — the same treatment applies here).
- Captured-`var` mutation → replace the `var` with a small `final class Box: @unchecked
  Sendable` or an actor, which is the pattern already used elsewhere in the suite.

The 767 redundant-`#require` warnings are separate and trivially fixed by dropping
`try #require(...)` where the expression is non-optional; they are noise but not a
migration blocker, so do them second.

**Acceptance criteria.**
- [ ] `swift build --build-tests 2>&1 | grep -c "error in the Swift 6 language mode"` returns `0`.
- [ ] `Scripts/test.sh` still reports 2410 passing tests (no test deleted to silence a warning).

---

---

### [TOOL-03] Commit or discard the ten-day-old unlock-sheet change

- **Severity:** Low
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `Sources/GargantuaCore/Views/Licensing/UnlockGargantuaSheet.swift:70-108`
- **Depends on:** none

**What's wrong.** The working tree carries an uncommitted +12/−9 change to the unlock
sheet, dated 2026-07-14. It is the fix for the screenshot complaint that "Already bought?
Enter key" was wrapping to two lines and picking up the default focus ring, making it look
like a broken text field. The fix moves the affordance below the action row, restyles it
as a caption-sized underlined accent link with `lineLimit(1)`, and adds
`.focusable(false)`.

**Evidence.** `git diff` shows the button removed from the `HStack` at `:70` and re-added
as a standalone block after the action row, with `GargantuaFonts.caption`,
`GargantuaColors.accent`, `.underline()`, `.lineLimit(1)`, and `.focusable(false)`.

**Why it matters.** Low severity, but this is a customer-visible fix to the *purchase*
sheet sitting unshipped, and the repo's own convention is to flush uncommitted work before
stacking new changes. It also means a licensed build made today from a clean checkout
still shows the broken layout.

**Proposed fix.** Verify it renders (`GARGANTUA_LICENSING=1 Scripts/run.sh`, trigger the
Unlock sheet from an expired trial), then commit as
`fix(licensing): restyle the "already bought" affordance as its own link row`.

**Acceptance criteria.**
- [ ] `git status --short` shows no modification to `UnlockGargantuaSheet.swift`.
- [ ] The sheet renders with the link on its own line and no focus ring, confirmed by screenshot.

---

---

### Docs

---

### [DOC-01] Correct the README's claim that the destructive MCP registry is opt-in

- **Severity:** Low
- **Confidence:** High
- **Effort:** S (<1h)
- **Files:** `README.md:275`, `Sources/GargantuaMCP/main.swift:53-58,286`
- **Depends on:** none

**What's wrong.** README:275 states: "The read-only and destructive tools live in separate
registries in code, so a read-only server can't accidentally advertise the destructive
`clean` tool — exposing it requires explicitly opting the destructive registry in." The
separate-registries half is true; the opt-in half is not. The shipped server registers
both unconditionally, on every transport.

**Evidence.** `Sources/GargantuaMCP/main.swift:53-58` passes
`tools: MCPPhase2Tools.all + MCPPhase3Tools.all` with no condition, `:286` registers the
`clean` handler unconditionally, and `:308-318` hands that same dispatcher to the SSE
transport. There is no flag, env var, or CLI option that omits the destructive registry —
`MCPRuntimeOptions.swift` parses transport mode, port, bind scope, and token only.

**Why it matters.** It is the load-bearing sentence in the README's MCP safety story, and
a reader auditing the security posture (the exact audience that paragraph is written for)
would conclude the destructive surface is off unless enabled. It compounds [SEC-02]: a
user reading that sentence would not expect `clean` to be reachable on the SSE port.

**Proposed fix.** Either make the claim true or correct it. Correcting it is the honest
one-line change:

> The read-only and destructive tools live in separate registries in code
> (`MCPPhase2Tools` / `MCPPhase3Tools`), so a fork or an embedding host can register only
> the read-only set. The bundled `GargantuaMCP` binary registers both.

Making it true is also cheap and arguably better, and pairs naturally with [SEC-02]: add
a `--read-only` flag to `MCPRuntimeOptions` that omits `MCPPhase3Tools.all` from both the
dispatcher's tool list and the `register(tool: .clean, ...)` call. If you do that, say so
in the README instead.

**Acceptance criteria.**
- [ ] README's MCP section describes the actual registration behavior of the shipped binary.
- [ ] If a `--read-only` flag is added: `swift run GargantuaMCP -- --read-only` lists five tools and `tools/call` for `clean` returns method-not-found.

---

---

## 4. Answers to the three named investigations

### 4.1 Disk Explorer back-navigation — **verdict: navigable, but the obvious way back is a trap**

**Short answer.** You can always get back out. The problem is that the two controls a user
will actually reach for — the Escape key and the header Back button — do not go back one
level; they destroy the whole session. The control that does go up one level, ⌘[, is
invisible.

**The navigation model** is a breadcrumb stack of path strings, not an object reference,
which is why nothing ever dangles. `DiskExplorerState.swift:49-51`:

```swift
    public var pathStack: [DiskExplorerCrumb] = [
        DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")
    ]
```

with the focused directory derived as `pathStack.last?.path ?? NSHomeDirectory()`
(`:81-83`). State is owned at `MainContentView` level, so navigating away in the sidebar
and back preserves the trail.

**Drill-in** is a single click, and all four routes converge on one method,
`DiskExplorerState.drillDown(into:)` (`:193-200`): treemap cell
(`DiskExplorerView.swift:236`), list row (`:265`), the focus-mode hero card, and the
focus-mode "other items" rows.

**Every drill-out affordance, complete:**

| Affordance | What it does | Discoverable? |
| --- | --- | --- |
| Breadcrumb crumb click | Truncates the stack to that index (`navigateTo`, `:202-206`) | Yes — visible at top |
| **⌘[** | Up exactly one level (`DiskExplorerView+Layout.swift:16-21`) | **No** — zero-opacity, zero-size, `.accessibilityHidden(true)` |
| **Escape** | `exitToIdle()` — full session reset (`+Layout.swift:14-15`) | Yes, but it does the wrong thing |
| Header "Back" | `exitToIdle()` (`DiskExplorerView.swift:48`) | Yes, but same |
| Rescan | Resets to Home; confirmation dialog when depth > 0 (`+Layout.swift:43-49`) | Yes |

Affordances that **do not exist**, verified by reading every DiskExplorer and Directory
file: no ⌘↑ (the Finder idiom), no `..` parent row or tile, no up entry in either context
menu (`DirectoryRowView.swift:96-104` and `DirectoryTreemapCellView.swift:52-60` offer
only Reveal in Finder and Move to Trash), and no double-click, scroll, swipe, or pinch
gesture.

**Root, permission-denied, and post-rescan behavior — all three are sound.** At the root
the last crumb's button is `.disabled` (`DiskExplorerView.swift:147`) and `navigateTo`
independently guards `index < pathStack.count - 1` (`:203`), so there is no crash path.
A permission-denied folder **cannot be focused at all** — `drillDown` guards
`!item.isPermissionDenied` (`:194`) and both surfaces reroute the click to the Full Disk
Access settings pane instead — so no trapped state arises. `DiskExplorerFocusUnavailableView`,
despite its name, is not the permission-denied state; it is the "focus mode chosen but no
dominant child exists" state and it renders inside `resultsView`, so the breadcrumb and
keyboard layer remain available above it. After a refresh, focus is re-resolved by path
(`refreshCurrent()`, `:114-122`, leaves `pathStack` untouched); a deleted directory yields
an empty state rather than a dangling reference.

**Two real defects fall out**, written up as [UX-01] (Escape's semantics and ⌘['s
invisibility) and [UX-02] (the unreachable "Others (N)" set).

**One further asymmetry, worth knowing but not worth a finding on its own.** In list mode
the expansion chevron shows grandchildren inline, and clicking one drills straight into it
(`DiskExplorerView.swift:276`), appending the grandchild's crumb and **skipping the
intermediate directory**. The breadcrumb then reads `Home > X > B` when the real path is
`Home/X/A/B`, so "up" from B lands at X rather than at B's true parent A. The breadcrumb
is a visit trail, not a filesystem path. It is defensible as designed behavior and it never
strands the user, so I am recording it rather than filing it — but if [UX-01] is fixed by
making up-navigation prominent, this will start to look like a bug to users, and the fix is
to push both crumbs during a grandchild drill.

### 4.2 Dead indicators — **verdict: 13 real gaps, and one screen that reports failure as success**

**Short answer.** The app is disciplined about *scan* failures and undisciplined about
*everything after the delete*. Scan paths consistently log and set user-visible state.
Post-cleanup paths — failed deletions, failed audit writes, failed model removal, failed
deep-link activation — are frequently log-only. The worst single case is the Dashboard,
where a **failed** triage scan renders a green checkmark telling the user there is nothing
to clean.

**Method.** For each user-triggered action I traced the button's action closure through to
every terminal state (success / empty / error / cancelled / permission-denied) and checked
that each renders something perceivable. My first pass grepped only `logger.error` and came
back nearly clean; that was under-sweeping — the real silences use `logger.warning`,
`try?`, and discarded completion-handler parameters. Every row below was re-verified
against the source before being written down.

| # | Surface | Action | Missing feedback | Proposed indicator | file:line |
| --- | --- | --- | --- | --- | --- |
| 1 | Dashboard | Run Triage | A **failed** scan renders the success empty state — `checkmark.circle` tinted `GargantuaColors.safe` plus "No triage groups found". Indistinguishable from a genuinely clean machine | Error branch keyed off `scanProgress.errors`, as `DeepCleanView.swift:189-199` already does | `DashboardView.swift:263-266`; `Dashboard/DashboardTriageEvidenceView.swift:75-93` |
| 2 | Duplicate Finder | Confirm "Send to Trash" | `result.failedItems` is never rendered — no summary, no banner. Failed items silently reappear in the list after `refreshResults()`. Also no busy state while `engine.clean` runs | Show `CleanupSummaryView` from the result, as every other destructive surface does | `DuplicateFinderContainerView.swift:120-136` |
| 3 | Settings → AI | Delete local model | `try?` discards the removal error, then `state = .notDownloaded` unconditionally. Settings reports "Not downloaded" while ~680 MB may still be on disk | Verify removal before flipping state; else `.failed(message)` (the UI already renders `.failed`) | `ModelDownloadManager.swift:88-91,121-123` |
| 4 | Licensing | Click `gargantua://activate?key=…` from a purchase email | Failure is log-only. The user clicks an activation link, the app comes forward, and nothing appears | Present the Unlock sheet / alert with `LicenseErrorCopy.message(for:)`, as the paste-key path does | `Views/Licensing/LicenseActivationLink.swift:28-30` |
| 5 | All six destructive flows | Audit-trail write after cleanup | Audit write failure is `logger.warning` only, while the summary card advertises "View Audit Trail" | One warning row in the summary: "This cleanup could not be recorded to the audit trail" | `DeepCleanView.swift:263`, `DevArtifactScanView.swift:202`, `AIModelsView.swift:306`, `DuplicateFinderContainerView.swift:132`, `FileHealthContainerCleanupFlow.swift:113`, `CleanupSummaryView.swift:127` |
| 6 | Disk Explorer (list row) | Context menu "Move to Trash" | `recycle([url]) { _, _ in … }` discards the error; the row just remains after refresh | Capture the completion error into an alert (Background Items' `lastError` pattern) | `DirectoryRowView.swift:151-156` |
| 7 | Disk Explorer (treemap tile) | Context menu "Move to Trash" | Identical error discard | Same as #6 | `DirectoryTreemapCellView.swift:86-91` |
| 8 | Cleanup summary | "View Audit Trail" | `if fileExists { reveal }` with no else — the button looks inert exactly when #5 has happened | Disable when absent, or explain | `CleanupSummaryView+Sections.swift:378-383` |
| 9 | Settings → License | "Deactivate this Mac" | `LicenseGate.deactivate()` is `try? await store.deactivate()`; no spinner, no success/failure feedback, card silently stays "Licensed to …" | Return a `Result` and reuse the section's existing `inlineFeedback` row | `GargantuaLicensing/LicenseGate.swift:73-75`; `Views/Licensing/LicenseSettingsSection.swift:49-57` |
| 10 | Rules viewer | Open Rules pane when bundled rules fail to load | `catch { categories = [] }` renders an empty pane — load failure looks like "no rules exist" | Error state in the list pane (`userRuleErrors` plumbing already exists for custom rules) | `RuleViewerView.swift:184-187,238-240` |
| 11 | Settings → Permissions | "Open Settings" for the privileged helper | `try?` discards a `register()` failure, so the Login Items toggle may never appear | Surface the register error in `helperDetail` | `PermissionsSettingsSection.swift:62-64` |
| 12 | Dashboard | Dismiss scheduled-scan summary card | `try?` on the acknowledge write; a failed persist resurrects the card next launch | Minor — a retry or notice | `DashboardView.swift:325-328` |
| 13 | Main window | Profiles / Rules / Settings before persistence resolves | Bare `ProgressView()` is invisible on the void background | `AccretionDiskView` | `Sources/Gargantua/MainContentView.swift:137,207,238` |

Rows 1, 2, 3, and 13 are written up as findings [UX-05], [UX-06], [BUG-03], and [UX-04].
Rows 4–12 are real but individually small; they share one root cause and are best fixed as
a batch — see [UX-07].

**Quoted evidence for the top three.**

Row 1, `DashboardView.swift:263-266` — the failure is recorded into progress and then
dropped on the floor:

```swift
            } catch {
                progress.recordError(error.localizedDescription)
                progress.finish(itemsFound: 0)
            }
```

and `Dashboard/DashboardTriageEvidenceView.swift:75-90` renders, with no reference to
`errors` anywhere in the file:

```swift
            Image(systemName: hasRunTriage ? "checkmark.circle" : "list.bullet.clipboard")
                .foregroundStyle(hasRunTriage ? GargantuaColors.safe : GargantuaColors.accent)
            ...
                Text(hasRunTriage ? "No triage groups found" : "No triage evidence yet")
```

Row 2, `DuplicateFinderContainerView.swift:127-136` — only `succeededItems` is consumed:

```swift
        let result = await engine.clean(items, method: method)
        do {
            try AuditWriter().record(result: result)
        } catch {
            duplicateFinderContainerLogger.warning("Failed to write audit entry: \(error.localizedDescription)")
        }
        selectedIDs.subtract(result.succeededItems.map(\.item.id))
        refreshResults()
        onCleanupCompleted?(result)
```

Row 3, `ModelDownloadManager.swift:88-91` and `:121-123`:

```swift
    public func deleteModel() {
        removeModelDirectory()
        state = .notDownloaded
    }
    ...
    private func removeModelDirectory() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }
```

**Surfaces checked and found genuinely fine**, so this is not a grep that came back empty:

- **Deep Clean / Dev Purge / AI Models / File Health cleanup flows** — phase-driven
  (`beginCleanup` → console → `finishCleanup` → summary); scan failures route through
  `session.failScan(message)`; scan warnings render from `scanProgress.errors`
  (`DeepCleanView.swift:189-199`, `AIModelsView.swift:162-192`). Only the audit-write
  silence (row 5) mars them.
- **Duplicate Finder and File Health *scans*** (as opposed to their deletes) — both log
  *and* call `state.failScan(message)` on every error branch
  (`DuplicateFinderContainerView+Scan.swift:19,46`;
  `FileHealthContainer/FileHealthScanCoordinator.swift:29,48`).
- **Smart Uninstaller** — single and batch execute set `.failed(message)` phases; batch
  synthesizes failed results per plan so nothing is masked; a dedicated
  `SmartUninstallerView+Error.swift` exists.
- **Background Items / Process Inventory** — every action outcome routes to a `lastError`
  alert; rows show a busy state during actions via `busyItemIDs`.
- **File Organizer** — the best state machine in the codebase:
  `idle/proposing/preview/applying/applied/undoing/undone/failed(message)`, with per-row
  trash errors and an explicit user-cancel path.
- **Feedback sheet, Unlock sheet, paste-key activation, menu-bar widget, Profiles,
  Settings (Automation, exclusions, scan roots, MCP token, Cloud AI key, model download)**
  — all set user-visible notices on failure; several roll back optimistic toggles.
- **Empty-vs-loading ordering** — `DiskExplorerView.contentMode` (`:201-213`) tests
  `isLoading` before `items.isEmpty`, so an empty state cannot render mid-scan.
- **Superseded-result races** — every async completion I read guards on a generation
  counter before writing state. This class has clearly already been hunted; commit
  `8a735eb` and the 0.4.6 changelog confirm it.

**The honest caveat.** None of this was observed at runtime. Perceptual failures — a
spinner that spins for 40 seconds with no item counter, a disabled state too subtle to
read against the void — cannot be found by reading and remain uncovered. See §9.

### 4.3 Developer Tools / pnpm — **verdict: real defect, reproduced, root cause is the working directory**

**Short answer.** pnpm is broken in the shipped app, the cause is that Gargantua spawns
tools with the working directory it inherited (`/` for a Finder launch), and `pnpm store
path` cannot run from a read-only directory. Written up as [BUG-01]; a second, independent
defect makes the pnpm row report a permanent zero ([BUG-02]).

**The reproduction**, run this session:

```
$ cd / && pnpm store path ; echo "EXIT=$?"
[EROFS] EROFS: read-only file system, open '/_tmp_1793_90b689e5f1e15a1116551cc9f472b251'
EXIT=226

$ cd /tmp && pnpm store path ; echo "EXIT=$?"
/Users/Jason/Library/pnpm/store/v11
EXIT=0
```

Same binary, same environment; the working directory is the only variable. `pnpm --version`
succeeds from `/` because it writes nothing, which is why the tool passes availability
detection and *then* fails at preview — producing a card that says "installed" and
"Preview failed" at the same time.

**Hypotheses eliminated.** The launchd-minimal `PATH` theory is **wrong** here: resolution
uses `posix_spawn` against absolute candidate paths and never searches `PATH`, and the
child `PATH` already gets the resolved binary's directory prepended
(`ProcessSpawner.swift:145-164`) — that was the 0.4.2 fix and it is still working. Parser
drift is **wrong**: `pnpm store path` emits one absolute path line, which the parser
handles, and it is never reached because the command exits non-zero first. A dry-run flag
is **not** the issue: the preview command is read-only by design. Exit codes are **not**
swallowed on this path — a non-zero exit throws and renders as a visible failed card.

I also specifically checked whether the resolver picks a *broken* binary, because the only
pnpm candidate present on this machine is a mise shim
(`~/.local/share/mise/shims/pnpm`, the last entry in `pnpmCandidatePaths`,
`DeveloperToolBinaryResolver.swift:31-40`). It is healthy: `--version` → `11.17.0`,
`store path` → exit 0 from a writable directory. The shim is not the problem.

**Per-tool verdict table.** Every preview command below was executed this session from
cwd `/` — the exact condition a Finder-launched app creates — using the binary
`DeveloperToolBinaryResolver` would select on this machine (first executable candidate in
its list).

| Tool | Resolves to | Preview command | Exit from `/` | Verdict |
| --- | --- | --- | --- | --- |
| Homebrew | `/opt/homebrew/bin/brew` | `cleanup -n` | **0** | Works. Parser matches real `Would remove …` output |
| Docker | `/usr/local/bin/docker` | `system df` | 1 | Correct — daemon is stopped; stderr matches `isDockerDaemonNotRunning`, so it renders the "Daemon stopped" CTA, not an error. Live JSON parse **not verified** (daemon down, deliberately not started) |
| Xcode | `/usr/bin/xcrun` | `simctl list -j devices unavailable` | **0** | Works. Valid JSON; zero unavailable devices here, so the delete operation is correctly hidden |
| **pnpm** | `~/.local/share/mise/shims/pnpm` | `store path` | **226** | **BROKEN — `EROFS`. This is the reported bug** |
| npm | `/opt/homebrew/bin/npm` | `config get cache` | **0** | Works → `/Users/Jason/.npm` |
| Yarn | `/usr/local/bin/yarn` | `cache dir` | **0** | Works → `/Users/Jason/Library/Caches/Yarn/v6` |
| Go | `/opt/homebrew/bin/go` | `env -json GOCACHE GOMODCACHE` | **0** | Works. Valid JSON |
| Cargo | `~/.cargo/bin/cargo` | `--version` | **0** | Works. Preview reads `~/.cargo/registry/src` directly rather than parsing output |

**pnpm is the only tool affected**, because it is the only one that writes into the
current directory. That is a precise and reassuring result: [BUG-01] is a one-line fix with
a narrow blast radius, not a systemic breakage.

**One adjacent observation, not a finding.** The resolver's candidate list is absolute-path
based, so it can select a *different* binary than the user's shell does. Here it picks
Homebrew's `npm` and an Intel-Homebrew `yarn` at `/usr/local/bin/yarn`, while the user's
interactive `PATH` resolves both to nvm's copies. Both resolved binaries work correctly, so
there is nothing to fix, but it means a version shown in the panel may not match what
`npm --version` prints in the user's terminal.

---

## 5. Complexity and architecture assessment

### Numbers first

**Largest files.** The biggest source file in the repo is 535 lines. That is a genuinely
healthy number for 82,624 lines across 544 files, and it is the main reason this codebase
reads well.

| Lines | File |
| --- | --- |
| 535 | `Sources/GargantuaCore/Services/CleanupEngine.swift` |
| 490 | `Sources/GargantuaCore/Services/CloudAIModels.swift` |
| 485 | `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` |
| 460 | `Sources/GargantuaCore/Parsing/RuleParser.swift` |
| 451 | `Sources/GargantuaCore/Services/CzkawkaAdapter.swift` |
| 446 | `Sources/GargantuaCore/Services/DeveloperToolPreviewOutputParser.swift` |
| 441 | `Sources/GargantuaCore/Services/AIModelIntelligenceScanAdapter.swift` |
| 425 | `Sources/GargantuaCore/Services/PathExpander.swift` |
| 422 | `Sources/GargantuaCore/Services/BackgroundItemScanner.swift` |
| 414 | `Sources/GargantuaCore/Views/CloudAISettingsSection+Sections.swift` |
| 410 | `Sources/GargantuaCore/Views/DuplicateFinderView.swift` |
| 407 | `Sources/GargantuaMCP/main.swift` |
| 398 | `Sources/GargantuaCore/Views/ClaudeCodeAgent/ClaudeCodeAgentTranscriptView.swift` |
| 394 | `Sources/GargantuaCore/Services/UninstallExecutor.swift` |
| 392 | `Sources/GargantuaCore/Services/MCP/MCPTransportSettings.swift` |

Only two of these (`CleanupEngine` at 535, `DeveloperToolPreviewOutputParser`'s enum body
at 304) breach a SwiftLint threshold, and both are marginal.

**Longest functions.** Of 2,118 functions measured, 36 exceed 60 body lines and exactly
one exceeds 100.

| Body lines | Location |
| --- | --- |
| 181 | `Sources/GargantuaCore/Services/DefaultProcessRunner.swift:40` — `run(executable:arguments:…)` |
| 100 | `Sources/GargantuaCore/Services/CzkawkaAdapter.swift:289` — `makeResult` |
| 91 | `Sources/GargantuaCore/Services/ClaudeCodeAgentRunner.swift:39` — `makeLaunchPlan` |
| 89 | `Sources/GargantuaCore/Services/ProcessActionExecutor.swift:56` — `stop` |
| 89 | `Sources/GargantuaCore/Services/NativeScanAdapter+Evaluate.swift:57` — `evaluate` |
| 84 | `Sources/GargantuaCore/Services/NativeScanAdapter+Evaluate.swift:193` — `makeResult` |
| 83 | `Sources/GargantuaCore/Services/NativeScanAdapter.swift:107` — `scan` |
| 82 | `Sources/GargantuaPrivilegedHelper/main.swift:83` — `handleBackgroundItem` |
| 82 | `Sources/GargantuaCore/Services/CleanupEngine.swift:278` — `cleanSingle` |
| 81 | `Sources/GargantuaCore/Services/ClaudeCodeOneShotRunner.swift:35` — `run` |
| 80 | `Sources/GargantuaCore/Services/CzkawkaAdapter.swift:169` — `scan` |
| 80 | `Sources/GargantuaCore/Services/CodexOneShotRunner.swift:31` — `run` |
| 80 | `Sources/GargantuaCore/Services/CloudAIService.swift:67` — `perform` |
| 78 | `Sources/GargantuaCore/Services/FclonesAdapter.swift:107` — `scan` |
| 78 | `Sources/GargantuaCore/Services/DirectorySizeScanner.swift:60` — `streamChildren` |

`DefaultProcessRunner.run` at 181 lines is the clear outlier and the one function here
worth splitting on its own merits — it owns spawn, two pipe drains, timeout escalation,
and byte-capping in one body.

**Nesting.** Every deep-indentation hot spot is SwiftUI view-builder nesting (modifier
chains and closures), not control flow. Outside `Views/`, the deepest indentation in the
entire codebase is 32 columns, and every instance is a multi-line initializer argument
list rather than branching (`RemnantScanner+Evaluation.swift:51-52`,
`DirectorySizeScanner.swift:99-110`). **Control-flow nesting is not a problem in this
codebase** and no refactor should be justified on it.

**Debt markers.** Zero. A grep for `TODO`/`FIXME`/`HACK`/`XXX` across `Sources/` returns
three hits, and all three are false positives: two are the literal license-key placeholder
`"GARG-XXXX-XXXX-XXXX-XXXX"` (`LicenseSettingsSection.swift:76`,
`UnlockGargantuaSheet.swift:58`) and one is a comment about `/private/tmp/dmg.XXXXXX`
mount paths (`NativeScanAdapter+Evaluate.swift:215`). For an 82k-line codebase this is
genuinely unusual and worth saying out loud.

### The `Type+Extension.swift` question, answered

There are 108 `+`-suffixed files. The honest verdict: **this is real decomposition, not a
god-object smeared across files** — with one exception and one systematic tax.

Evidence for the verdict. No family shows ordering dependencies between files. Several are
provably safe by construction: `RemnantScanner` (6 files) is an immutable `Sendable`
struct with `let`-only stored properties, so its extensions *cannot* share mutable state;
`EventHorizonContext` (6 files) is an immutable value type whose extensions are each a
static factory for one tool; `DeveloperToolPanel` (5 files) keeps one `@State` in the base
and makes every extension a pure view-builder function taking parameters.
`ScheduledScanService` (7 files) does not even have a `ScheduledScanService` type — the
base file is 8 lines of comments and each "extension" file declares independent types, so
the `+` naming is a namespace convention rather than a type split.

**The one exception: `SmartUninstallerViewModel`** — one `@Observable` class, 784 lines
across 5 files, where every extension mutates the same `phase` / `selectedIDs` /
`multiSelected` state machine. `+Execute` guards on `.reviewingPlan` and writes `.failed`;
`+AppPicker` prunes `apps`, `multiSelected`, and `categoryCounts`; `+Batch` drives
`batchScanning` → `batchExecuting`. It is mitigated by the split following phase
boundaries with a `SmartUninstallerPhase` enum enforcing order at runtime, so it reads as
one state machine filed by phase rather than arbitrary smearing. It is still the only
place in the repo where the "god object across files" critique lands.

**The systematic tax:** splitting a SwiftUI view across files forces its `@State`
properties from `private` to `internal` so the extensions can reach them. The base files
document this honestly — `ProcessInventoryView.swift:10-12` says outright that "stored
properties are internal rather than private so those cross-file extensions can reach
them". The cost is that `internal` stops meaning "deliberate module-level API" in
`Views/`, which is what makes dead-code analysis there so noisy. `DiskExplorerView+Layout`
shows the better pattern: it routes everything through the `state` object instead, and its
comment at `:8-10` explains exactly that choice.

**One misfiled file worth a one-line fix:** `CloudAIService+Features.swift` (283 lines) is
almost entirely public model structs (`CloudAIRecommendation`, `CloudAIDeepAnalysis`,
`CloudCleanupPlan`), not service behavior. It is a models file wearing an extension
filename.

### Layering

**Services are clean.** Zero `View` types, `some View`, or `@ViewBuilder` anywhere in
`Sources/GargantuaCore/Services/`. Twelve service files import AppKit, all for
`NSWorkspace`-class OS facilities (trash, reveal, running-app checks). Exactly one service
imports SwiftUI — `AppAppearancePreference.swift` — and only to expose a `ColorScheme`
mapping, which is the right call.

**Views leak a little I/O**, in five places. None is severe; listed worst-first:

| File:line | What it does | Judgment |
| --- | --- | --- |
| `Views/DuplicateFinderContainerView+Scan.swift:67` | `Task.detached` stats every result path via `fileManager.fileExists` to prune stale duplicates | Real violation — scanning work in a view file |
| `Views/SystemInfoBar.swift:204` | `attributesOfFileSystem` polled on a 2-second loop | Real — recurring I/O in a view |
| `Views/SmartUninstaller/SmartUninstallerViewModel+AppPicker.swift:205` | `fileExists` over app bundle paths | Borderline — view *model*, not view body |
| `Views/CleanupSummaryView+Sections.swift:380` | `fileExists` + reveal of the audit log | Minor — could route through `AuditWriter` |
| `Views/DeveloperToolLogoBadge.swift:186` | `fileExists` over candidate icon paths | Mild — read-only display lookup |

Everything else that greps as filesystem work in `Views/` is path-*string* manipulation
for display or reveal-in-Finder URLs, with no I/O. That is benign and should not be
"fixed".

### Untested critical paths

Coverage sits above the 78% CI floor, but percentage is the wrong lens. Naming the
critical paths that carry the least test weight:

1. **The privileged helper's XPC surface end-to-end.** `PrivilegedBackgroundItemValidator`
   has tests, but the `listener(_:shouldAcceptNewConnection:)` code-signing-requirement
   path in `GargantuaPrivilegedHelper/main.swift:7-22` is not exercised by the suite —
   it needs two signed processes. This is the highest-consequence code in the repo and
   its authentication step is verified by reading, not by test.
2. **The MCP SSE transport's authorization decisions as a whole.** `MCPSSEAuthorization`
   is unit-tested and `MCPSSETransportTests` covers the localhost-no-token and
   OPTIONS-403 cases, but there is no test asserting what *may not* reach a destructive
   tool over SSE — which is why [SEC-02] and [SEC-05] both survived.
3. **The license gate's coverage of destructive surfaces.** There is no test that
   enumerates destructive entry points and asserts each is gated. Such a test would have
   caught [SEC-01] and [SEC-03] mechanically. See [REF-02] below.
4. **Developer Tools execution against a non-trivial working directory.** The suite injects
   a `ProcessRunner`, so no test ever spawns a real process from a real cwd — which is
   exactly the blind spot [BUG-01] lived in.

### Recommended refactors — five, each tied to a bug or a shipped cost

**[REF-01] Split `DefaultProcessRunner.run` (181 lines) into spawn / drain / reap.**
*Blast radius:* one file, but it is the chokepoint every external tool flows through —
Homebrew, Docker, pnpm, npm, yarn, go, cargo, czkawka, fclones, Claude Code, Codex.
*Reason tied to a bug:* [BUG-01] lives here. The working-directory decision has no
obvious home in a 181-line function that already juggles two pipe drains and a timeout
escalation ladder, and the absence of a seam is part of why it was never noticed. Splitting
it also gives the fix a natural test point.

**[REF-02] Introduce one enumerable registry of destructive entry points.**
*Blast radius:* small — a new type plus one call-site change per surface (currently 8).
*Reason tied to a bug:* [SEC-01] and [SEC-03] are the same bug found twice, and commit
`99bf0e3` shows a careful developer sweeping this exact class and still missing one. Today
"is every destructive path gated?" is answerable only by grep and human diligence. Make it
a `DestructiveSurface` enum whose cases each carry their gate, and write one test that
iterates `allCases` and asserts a gate exists. That converts a recurring judgment call
into a compile-and-test failure.

**[REF-03] Decompose `SmartUninstallerViewModel` (784 lines, 5 files) along its phases.**
*Blast radius:* medium — the Smart Uninstaller surface only, but all of it. *Reason tied to
a shipped cost:* this is the one family where extensions genuinely share mutable state, and
the Uninstaller is also where the 0.4.6 over-attribution bug shipped ("Uninstalling an app
no longer flags a sibling app from the same vendor"). Extracting the plan-building and
attribution logic out of the view model into a testable service would let that class of
bug be caught by a unit test instead of a user. Do this only if you touch the Uninstaller
again; do not do it speculatively.

**[REF-04] Move the triage scoring out of the view layer.**
*Blast radius:* small — `ProcessInventoryView+Triage.swift` (92 lines) and its
Background Items sibling. *Reason:* it is 92 lines of domain arithmetic (assigning 90/80/55
point contributions) living on a SwiftUI `View` type, which means the scoring rules cannot
be tested without instantiating a view. This is the clearest case in the codebase of
business logic parked on UI.

**[REF-05] Give the Disk Explorer's navigation a single reachable-set invariant.**
*Blast radius:* the Disk Explorer only. *Reason tied to a bug:* [UX-01] and [UX-02] are
both "the user can get somewhere they cannot get back from, or cannot get to at all", and
they arise from two independent decisions (Escape's binding, and `collapseSmall` applying
to the list). One place that answers "which items are reachable from here, and how do I go
up" would have made both impossible.

**Explicitly not recommended:** no refactor for file size, nesting depth, or the
`Type+Extension` pattern in general. The numbers do not support it and the pattern is
working.

---

## 6. Three killer features

Each is earned by something observed in the code during this audit, and each exploits an
asset that already exists in the repo.

### 6.1 Undo — a reversible cleanup ledger

**The insight that motivates it.** Gargantua already writes a structured, per-file audit
record for every destructive operation: `AuditEntry` carries `files: [AuditFile]` with
path and size, `cleanupMethod`, `bytesFreed`, and a stable UUID
(`MCPCleanToolHandler.swift:324-335`), appended as JSONL to
`~/Library/Logs/Gargantua/audit.json`. Separately, the privileged helper *already returns
the resulting Trash path* for every item it moves — `PrivilegedUninstallItemResult(…,
trashPath: trashURL.path)` (`GargantuaPrivilegedHelper/main.swift:182-187`) and
`PrivilegedBackgroundItemResponse(…, trashPath:)` (`:153-157`). So the two halves of an
undo — what was removed, and where it went — are both already computed and already
persisted. Nothing consumes the pairing. The product is one join away from reversibility
and does not offer it.

**What it does.** After any cleanup, Gargantua shows "Undo last cleanup" for as long as
the items remain in the Trash. Clicking it restores every file to its original location,
reports anything it could not restore (emptied Trash, a path now occupied, a file that
needed the helper), and writes its own audit entry so the restore is itself traceable. A
Cleanup History screen lists past operations with their reclaimed bytes and an Undo button
on each one that is still reversible.

**Why it fits this product and why the competitors structurally cannot ship it.**
Reversibility is already one of the four words in Gargantua's own pitch, and today it is
delivered only as "we put it in the Trash, good luck". Every mainstream cleaner optimizes
for the size of the number it deletes; none can offer undo because none records
per-file provenance in a durable, user-inspectable form — an audit trail is a liability if
your product's value proposition is an opaque "1,000 junk files found". Gargantua already
pays the cost of that trail for trust reasons. Undo is the feature that makes the cost
pay for itself, and it is the single most requestable thing a file-deletion app can offer.

**Implementation sketch.** New `RestoreEngine` service in `GargantuaCore/Services/`,
mirroring `CleanupEngine`. The data model needs one addition: `AuditFile`
(`Sources/GargantuaCore/Models/AuditEntry.swift:150-161`) holds only `path` and `size`
and must gain `trashPath: String?`. The value already exists one layer up —
`CleanupItemResult.trashURL` (`CleanupEngine.swift:11`, "The new URL (Trash location) if
the item was moved successfully") — and is simply dropped when the audit entry is built
(`MCPCleanToolHandler.swift:314`: `AuditFile(path: $0.path, size: $0.size)`). Add
`restorable: Bool` derived at read time from `FileManager.fileExists(atPath: trashPath)`.
Reuse `AuditWriter`'s reader (`:199-213`) for history. Roughly one to two weeks including
the history UI. **Riskiest unknown:** restoring a root-owned item requires the privileged
helper to gain a `restoreFromTrash` operation, which means widening
`PrivilegedRemovabilityPolicy` — the one allow-list this audit found to be correctly
locked down. Design that operation as "move from the user's own Trash back to a path the
policy already allows removing", so it grants no new reach. **What to cut to pay for it:**
the Cleanup History UI can ship as a plain list before it becomes a designed surface, and
undo can launch supporting only user-owned files, deferring the helper work entirely.

### 6.2 Explain-before-you-delete for agents: a signed cleanup plan

**The insight that motivates it.** The MCP `clean` tool has a `dry_run` mode that returns
a plan shaped exactly like a real run and is deliberately exempt from the rate limiter and
the audit log because "they don't touch the disk"
(`MCPCleanToolHandler.swift:20-24,156-165`). Meanwhile `clean` resolves item ids only
against the calling connection's own scan cache
(`MCPScanSessionCacheRegistry`), so a plan is already bound to a specific scan. And the
audit entry already records `confirmationMethod: .mcp` and a `clientID`. The pieces for
"an agent proposes, a human approves, the approval is provable" are all present; what is
missing is the handoff between the dry run and the real one.

**What it does.** An agent runs `clean` with `dry_run: true` and gets back a *plan token*
alongside the preview. The plan appears in Gargantua's UI as a pending request — "Claude
Code wants to remove 4.2 GB across 18 items, here is every path and why" — with Approve
and Reject. The agent's subsequent real `clean` must present the plan token, and the
server accepts it only if a human approved that exact item set. The audit entry records
the plan token, so afterwards you can prove which human approved which agent's request.

**Why it fits and why competitors cannot.** No other cleaner has an agent interface at
all, so no other cleaner has this problem — which is precisely the point: Gargantua is
early enough in agent-driven maintenance to define what safe looks like. It resolves the
tension this audit found repeatedly, where the guardrails on the MCP path ([SEC-02],
[SEC-05], [SEC-06]) are all attempts to bound an *unattended* destructive capability. A
plan-approval handshake replaces "how do we make unattended deletion safe enough" with
"deletion is never unattended", which is a much better position to defend. It is also the
kind of thing a developer tells another developer about.

**Implementation sketch.** `MCPCleanToolHandler` gains a `planStore` (an actor keyed by
plan UUID holding the item-id set, the connection, and an expiry). Dry run mints and
returns a token; real runs require `plan_id` and validate the item set matches exactly.
The approval surface reuses the existing `MCPCleanNotificationService` seam — it already
has a request/decision shape with `.proceed` / `.cancelled`
(`main.swift:255-275`), so a richer approval UI slots in behind the same protocol.
Roughly one to two weeks. **Riskiest unknown:** the UX when Gargantua's main app is not
running — the plan needs somewhere to live and someone to show it, which probably means
the menu-bar widget becomes the approval surface. **What to cut:** ship it as
opt-in (`--require-plan-approval`), so existing agent workflows are not broken and the
feature can prove itself before becoming the default.

### 6.3 "Why is this here?" — provenance search across the rules corpus

**The insight that motivates it.** Gargantua's `explain` tool already accepts an arbitrary
absolute path and reverse-matches it against the active profile's rule set to produce the
same Trust Layer verdict a scan would assign, without running a scan
(`GargantuaMCP/main.swift:192-201`, via `NativeScanAdapter.classify(path:)`). It enriches
that with `pkgutil` receipt provenance — pkg id, version, install date
(`PackageReceiptExpander`). And `rules-sync.json` pins the exact upstream `gargantua-rules`
commit every bundled rule came from, surfaced per-rule in the Provenance & Trust panel.
The app can already answer "what is this file, who put it there, which reviewed rule
covers it, and who reviewed that rule" — but only for paths that happen to appear in a
scan, and only one at a time.

**What it does.** A search box, in the app and as an MCP tool, that answers "why is this
here?" for any path or any pattern. Type `~/Library/Caches/com.foo.bar` and get: the
owning application, the installing package receipt with its install date, the rule that
classifies it, that rule's safety rating and reasoning, the upstream commit and PR that
introduced the rule, and whether anything else on disk belongs to the same owner. Type a
bundle id and get every path attributable to it.

**Why it fits and why competitors cannot.** This is the product thesis stated as a
feature. Gargantua's differentiation is that every verdict traces to a named, publicly
reviewed rule — but today you only see that trace for items a scan surfaced, which means
the explainability is a property of the *results list* rather than a capability the user
can point at anything. Closed-box competitors cannot ship this because there is nothing to
show: their rules are a vendor secret, so "which rule covers this path and who reviewed
it" has no answer they are willing to give. For the developer audience it is also the
highest-frequency real question — the one that starts with "what is this 8 GB directory
and can I delete it".

**Implementation sketch.** Mostly assembly, which is why it is the cheapest of the three.
A `PathProvenanceService` in `GargantuaCore/Services/` joining `NativeScanAdapter.classify`,
`PackageReceiptExpander.lookupReceipts(forPath:)`, `AppBundleReader`, and the
`rules-sync.json` provenance already parsed for the Rule Viewer. A new read-only MCP tool
(`describe_path`) exposing the same join — note it should be scoped more tightly than
today's `explain`, which this audit found to be an unscoped, unrated-limited
existence-and-metadata oracle over the whole filesystem (§4 below). Roughly one week for
the service plus the MCP tool; the in-app search surface is the larger half. **Riskiest
unknown:** performance of reverse-matching an arbitrary path against the full rule corpus
on every keystroke — `explainPathClassify` currently rebuilds the entire adapter per call
(`main.swift:192-201`), which is fine for an occasional tool call and far too slow for
search. Needs a cached, prebuilt reverse index. **What to cut:** ship the MCP tool first
with no UI at all. It is immediately useful to the agent audience and defers the indexing
work until the interactive surface demands it.

---

## 7. Prioritized backlog

Ordered by what to actually do first, accounting for dependencies, effort, and which fixes
unblock others. Work this table top-down.

| # | ID | Title | Sev | Effort | Depends on |
| --- | --- | --- | --- | --- | --- |
| 1 | TOOL-03 | Commit or discard the ten-day-old unlock-sheet change | Low | S | — |
| 2 | BUG-01 | Give spawned developer tools a writable working directory | High | S | — |
| 3 | SEC-02 | Reject SSE requests whose Host header is not a loopback literal | High | S | — |
| 4 | SEC-01 | Gate Developer Tools command execution behind the license gate | High | S | — |
| 5 | UX-05 | Stop rendering a failed Dashboard triage as a clean bill of health | High | S | — |
| 6 | UX-06 | Surface failed deletions in the Duplicate Finder | High | M | — |
| 7 | UX-03 | Stop telling users the MCP SSE endpoint is read-only | Med | S | — |
| 8 | SEC-03 | Route the MCP `clean` tool through the license gate | Med | S | — |
| 9 | SEC-06 | Fail closed when the clean consent notification is unavailable | Med | S | — |
| 10 | SEC-05 | Key the MCP rate limit on the connection, not the declared name | Med | S | — |
| 11 | UX-01 | Fix Disk Explorer up-navigation (Escape semantics, visible ⌘[) | Med | S | — |
| 12 | BUG-02 | Stop hardcoding the pnpm store's reclaimable size to zero | Med | S | BUG-01 |
| 13 | BUG-03 | Verify local-model deletion before reporting it as deleted | Med | S | — |
| 14 | UX-07 | Batch: nine post-action failures that are logged but never shown | Med | M | — |
| 15 | UX-02 | Make the "Others (N)" aggregate reachable | Med | M | UX-01 |
| 16 | SEC-04 | Write the audit entry before the destructive act | Med | M | — |
| 17 | UX-04 | Replace the three bare `ProgressView()` spinners | Low | S | — |
| 18 | DOC-01 | Correct the README's destructive-registry claim | Low | S | — |
| 19 | CPX-01 | Delete three orphaned SwiftUI views | Low | S | — |
| 20 | TOOL-01 | Resolve trivy: wire it into CI or delete its config | Low | S | — |
| 21 | TOOL-02 | Clear the 433 Swift-6-fatal warnings in the test target | Low | M | — |

**Severity totals:** 5 High, 10 Medium, 6 Low. 21 findings.

**Why this order.**

TOOL-03 is rank 1 despite being the lowest-severity item on the list, because it is
uncommitted work sitting in the tree. Flush it before stacking seventeen changes on top of
it — otherwise the first fix that touches licensing entangles with it.

BUG-01 is the highest value-per-hour fix in the audit: one line, it repairs a headline
feature that is broken in the shipped app today, and it is the only finding here that a
user has already noticed and reported.

SEC-02, SEC-01, and UX-03 form a natural batch. All three are small, all three concern
"what can delete files and who is allowed to ask", and UX-03 in particular is one string
change that stops the app misinforming users about the decision SEC-02 makes dangerous.
Doing SEC-02 and UX-03 in the same commit means the network-exposure story is coherent
again in a single change.

UX-05 is ranked fifth despite being a UX finding because it is High severity, one hour of
work, and it sits on the first screen the user sees. An app that reports a *failed* scan as
a green checkmark has inverted its own core promise, and the fix is wiring an error value
that is already being recorded.

UX-06 follows immediately even though it is M-effort, because it is the same class of
defect — the app telling the user an operation went fine when it did not — on the one
surface where the consequence is unrecoverable. Fix UX-05 and UX-06 together and the
"Gargantua does not lie about outcomes" property holds again.

SEC-03, SEC-06, and SEC-05 continue the licensing/MCP theme at Medium severity, all
S-effort.

UX-01 before UX-02 because they are the same surface and UX-01 is the smaller change;
UX-02 also becomes more obviously correct once up-navigation is prominent.

SEC-04 sits below the S-effort security work despite equal severity purely because it is
the only M-effort item in that group — it needs a last-entry-wins rule in the audit reader
and the retention compactor, not just a reordering.

The bottom four are genuine cleanups with no user-facing consequence. TOOL-02 is last
because it is half a day of mechanical test edits that buys nothing until a Swift 6
migration is actually on the table.

**Two structural follow-ups worth beans of their own**, from §5: [REF-02] (one enumerable
registry of destructive entry points, which converts "did we gate everything?" from a grep
into a test) and [REF-01] (splitting `DefaultProcessRunner.run`, which is where BUG-01
lived). REF-02 in particular would have mechanically caught SEC-01 and SEC-03, so it is the
one refactor here that pays for itself in prevented bugs rather than tidiness.

---

## 8. Appendix: beans backlog script

**Do not run this from the audit.** Paste and run it yourself.

```bash
#!/usr/bin/env bash
# Gargantua deep audit 2026-07-25 — backlog.
# Report: docs/audits/2026-07-25-deep-audit.md
set -euo pipefail

R="docs/audits/2026-07-25-deep-audit.md"

beans create "Commit or discard the pending unlock-sheet restyle" -t task -p high \
  -d "[TOOL-03] in $R. Working tree has an uncommitted +12/-9 change to UnlockGargantuaSheet.swift from 2026-07-14 (the 'Already bought? Enter your key' link restyle). Flush it before stacking the rest of the audit backlog."

beans create "Give spawned developer tools a writable working directory" -t bug -p critical \
  -d "[BUG-01] in $R. Gargantua never sets a cwd for spawned tools, so a Finder-launched app runs them from '/'. 'pnpm store path' writes a probe temp file into the cwd and dies with EROFS (exit 226), which is why the Developer Tools pnpm card shows 'Preview failed' in the app but works from a terminal. Reproduced at the CLI. Fix: posix_spawn_file_actions_addchdir_np to the home directory in ProcessSpawner.swift. pnpm is the only tool affected of the eight tested."

beans create "Reject MCP SSE requests whose Host header is not a loopback literal" -t bug -p critical \
  -d "[SEC-02] in $R. Localhost SSE binds require no bearer token (MCPTransportSettings.swift:69) and nothing validates the Host or Origin header, so a DNS-rebinding web page can drive the server — including the destructive 'clean' tool, which is registered on that transport unconditionally. Fix: validate Host against 127.0.0.1/::1/localhost in MCPSSERequestRouter.authorize."

beans create "Gate Developer Tools command execution behind the license gate" -t bug -p high \
  -d "[SEC-01] in $R. DeveloperToolsExecutionFlow.confirmExecution -> execute -> DeveloperToolExecutionAdapter runs docker system prune, brew autoremove, pnpm store prune and 12 more with no DestructiveActionGate.blockReason() check. Commit 99bf0e3 swept 'all GUI destructive paths' and missed this one. Fix: gate in confirmExecution and attach .destructiveActionGate(reason:) to the view."

beans create "Stop describing the MCP SSE endpoint as read-only in Settings" -t bug -p high \
  -d "[UX-03] in $R. MCPTransportSettingsSection.swift:18 tells the user the endpoint exposes 'read-only Gargantua tools'. It exposes 'clean', which deletes files. This is the consent surface for the whole network-exposure decision. Pair with SEC-02."

beans create "Route the MCP clean tool through the license gate" -t bug -p normal \
  -d "[SEC-03] in $R. MCPCleanToolHandler never calls LicenseGate.shared.canExecuteDestructiveAction(); an expired trial still deletes files via an agent. Fix in the cleaner closure in GargantuaMCP/main.swift so the handler stays synchronous. Dry runs must stay available."

beans create "Fail closed when the MCP clean consent notification is unavailable" -t bug -p normal \
  -d "[SEC-06] in $R. MCPCleanNotificationFactory.automatic returns a no-op service when the process has no bundle identifier — which is the case for 'swift run GargantuaMCP', the README's own documented client config. Cleans then auto-proceed with no prompt. Fix: refuse destructive cleans unless an explicit --allow-unattended-clean flag is passed."

beans create "Key the MCP clean rate limit on the connection, not the declared client name" -t bug -p normal \
  -d "[SEC-05] in $R. The limiter shards on clientInfo.name from initialize, and initialize has no once-per-connection guard (MCPRequestDispatcher.swift:243-250, last-initialize-wins). A client renames itself between cleans for an unlimited budget. Fix: shard on MCPConnectionID; keep the declared name for audit attribution only."

beans create "Fix Disk Explorer up-navigation: Escape semantics and an invisible up control" -t bug -p normal \
  -d "[UX-01] in $R. Escape and the header Back button both call exitToIdle(), which wipes the breadcrumb and the path cache instead of going up a level. The only real up-one-level control is Cmd-[, whose button is opacity 0, zero-sized, and accessibilityHidden. Fix: rebind Escape to up-one-level with an exit fallback at root, add a visible Up control to the breadcrumb, drop accessibilityHidden."

beans create "Report the pnpm store reclaimable size as unknown instead of zero" -t bug -p normal \
  -d "[BUG-02] in $R. DeveloperToolPreviewAdapter.swift:152-155 hardcodes the pnpm-store item to 0 bytes while go/npm/yarn get measured sizes. A permanent '0 bytes' reads as 'nothing to clean' on a store that is routinely gigabytes. Fix: return nil so the existing estimate-unavailable copy renders. Blocked by BUG-01."

beans create "Make the Disk Explorer Others(N) aggregate reachable" -t bug -p normal \
  -d "[UX-02] in $R. In any directory with >=12 sized children, everything under 1% of the largest collapses into an inert 'Others (N)' row that cannot be clicked, expanded, revealed or drilled — in both list and treemap mode, since both render collapseSmall output. Those folders are unreachable. Fix: do not collapse in list mode; make the treemap aggregate switch to list mode on click."

beans create "Write the destructive audit entry before the act, not after" -t bug -p normal \
  -d "[SEC-04] in $R. MCPCleanToolHandler.executeAndAudit and DeveloperToolExecutionAdapter.execute both delete first and audit second. A crash between the two leaves files gone with no forensic record, in a product whose thesis is traceability. Fix: two-phase intent+outcome entry sharing one UUID, with last-entry-wins in the audit reader and retention compactor."

beans create "Replace the three bare ProgressView spinners with AccretionDiskView" -t bug -p low \
  -d "[UX-04] in $R. MainContentView.swift:137,207,238 render a bare system ProgressView while persistence loads for Profiles, Rules and Settings. The system spinner is invisible on the void background, so the pane reads as a hang. These are the only live bare ProgressView instances in the app."

beans create "Correct the README claim that the destructive MCP registry is opt-in" -t task -p low \
  -d "[DOC-01] in $R. README:275 says exposing 'clean' 'requires explicitly opting the destructive registry in'. GargantuaMCP/main.swift:55 registers MCPPhase2Tools.all + MCPPhase3Tools.all unconditionally on every transport. Either correct the sentence or add a --read-only flag and document that."

beans create "Delete three orphaned SwiftUI views" -t task -p low \
  -d "[CPX-01] in $R. AlertListView (190 lines, whole file) plus AlertRowView, and ScanRootErrorRow in ScanRootsSettingsSupport.swift, have zero references outside their declaring files and zero test references. Note AlertListView is public and GargantuaCore ships as a library product."

beans create "Resolve trivy: wire it into CI or delete its config" -t task -p low \
  -d "[TOOL-01] in $R. trivy.yaml is tracked and the README advertises trivy as an active dependency scanner, but no workflow invokes it. The OSV wrapper is real but is also never run in CI. Prefer deleting trivy.yaml and adding Scripts/osv-spm-scan.sh as a CI step."

beans create "Clear the 433 Swift-6-fatal warnings in the test target" -t task -p low \
  -d "[TOOL-02] in $R. A full recompile emits 1225 warnings, all in Tests/ (production code is clean). 433 are 'error in the Swift 6 language mode': NSLock lock/unlock and DispatchSemaphore.wait in async contexts, and captured-var mutation in concurrent closures, across ~20 source locations. Mechanical to fix now; a wall during any Swift 6 migration."

beans create "Introduce one enumerable registry of destructive entry points" -t task -p normal \
  -d "[REF-02] in $R section 5. SEC-01 and SEC-03 are the same missing-license-gate bug found twice, and commit 99bf0e3 shows a careful sweep of this exact class still missing one. Add a DestructiveSurface enum whose cases each carry their gate, plus one test iterating allCases asserting a gate exists. Converts a recurring judgment call into a test failure."

beans create "Stop rendering a failed Dashboard triage as a clean bill of health" -t bug -p critical \
  -d "[UX-05] in $R. DashboardView.swift:263-266 records a triage scan error into progress and finishes; DashboardTriageEvidenceView never reads scanProgress.errors, so a FAILED scan renders the success empty state — checkmark.circle tinted GargantuaColors.safe plus 'No triage groups found'. A crashed scan is presented as a clean machine, on the first screen the user sees. Fix: error branch keyed off scanProgress.errors, as DeepCleanView.swift:189-199 already does."

beans create "Surface failed deletions in the Duplicate Finder" -t bug -p high \
  -d "[UX-06] in $R. DuplicateFinderContainerView.swift:120-136 consumes only result.succeededItems; result.failedItems is never rendered — no summary, no banner. Failed items silently reappear in the list after refreshResults(). No busy state while engine.clean runs either. This is the surface where deleting the wrong copy is unrecoverable, so silence is the worst outcome. Fix: route the result into the shared CleanupSummaryView like the other five destructive surfaces."

beans create "Verify local-model deletion before reporting it as deleted" -t bug -p normal \
  -d "[BUG-03] in $R. ModelDownloadManager.deleteModel() calls removeModelDirectory() (a bare try?) then sets state = .notDownloaded unconditionally, so Settings reports 'Not downloaded' while ~680MB may still be on disk. Ironic in a disk cleaner. Fix: only advance state on success; use the existing .failed(String) case. Treat file-not-found as success for the cancel path."

beans create "Batch: nine post-action failures that are logged but never shown" -t bug -p normal \
  -d "[UX-07] in $R. Nine user-triggered actions handle failure with a log line and no UI, sharing one root cause (the codebase is rigorous about scan failures, lax about post-action ones). Highest value two: the gargantua://activate deep-link failure is log-only and paying-customer-facing (LicenseActivationLink.swift:28-30), and audit-write failures are silent across six destructive flows while the summary card still invites 'View Audit Trail' — a button that then does nothing. Also: Disk Explorer trash errors discarded in both row and tile, Deactivate-this-Mac, Rules load failure, helper register, scheduled-scan dismiss."

beans create "Split DefaultProcessRunner.run into spawn / drain / reap" -t task -p low \
  -d "[REF-01] in $R section 5. 181 body lines (DefaultProcessRunner.swift:40) owning spawn, two pipe drains, timeout escalation and byte-capping — the single longest function in the codebase and the chokepoint every external tool flows through. BUG-01 lived here; the absence of a seam is part of why the missing cwd went unnoticed."
```

---

## 9. Appendix: what I did not cover

Being thorough here costs nothing, so this is the honest list.

**I did not drive the running application.** This is the largest gap and it affects all of
Phase 4. I did not launch `Scripts/run.sh`, click through the sidebar, or take a single
screenshot. Every UX finding in this report ([UX-01] through [UX-04]) is derived from
reading the view code and tracing state, not from watching the app behave. The one
exception is the pnpm investigation, where I reproduced the failure directly at the command
line with the same binary and working directory the app uses — that finding is
runtime-verified, the rest are not. Concretely, the following were **not** walked:
Dashboard, Deep Clean, Dev Artifact Scan, File Health, File Organizer, Smart Uninstaller,
Background Items, Process Inventory, Rule Viewer, Profiles, Scheduled Scans, the Settings
tabs, the menu-bar widget, and the licensing/unlock sheet in a `GARGANTUA_LICENSING=1`
build. Anything that only manifests at runtime — layout breakage, focus order, animation
glitches, VoiceOver behavior, window-resize minimums, first-run permission flows — is
simply not in this report.

**The DNS-rebinding chain in [SEC-02] is not demonstrated end to end.** I verified every
link in code (no token on localhost, no Host check, `clean` registered on SSE) and gave a
one-command partial repro proving the missing Host validation, but I did not stand up a
rebinding DNS server and drive a real browser through it. The finding is tagged UNVERIFIED
on that specific point.

**[SEC-06]'s bundled-launch case is unresolved.** I proved the `swift run` path produces a
no-op notification service. Whether a `GargantuaMCP` executable living inside the app
bundle resolves `Bundle.main.bundleIdentifier` to the parent app — and therefore gets a
real notification — depends on where it sits in the bundle, which I did not test at
runtime.

**Areas I read shallowly or not at all.**

- **Duplicate Finder correctness.** The prompt flagged this as catastrophic-if-wrong
  (deleting the wrong copy) and I did not audit the hashing strategy, collision handling,
  partial-read shortcuts, symlinked duplicates, or the "keep one" selection logic.
  `FclonesAdapter` was opened only far enough to measure function length. **This is the
  most valuable thing a second session could pick up.**
- **Size and count math.** I did not audit reclaimable-size accumulation, double-counting
  when a file matches two rules, hard-linked files counted twice, sparse files, or APFS
  clones. The `e2207c6` singular-byte fix suggests a class worth sweeping and I did not
  sweep it.
- **Uninstaller leftover attribution.** Not audited beyond confirming the license gate is
  present at `UninstallExecutor.swift:200`. The 0.4.6 changelog records a fixed
  over-attribution bug, so the area has history.
- **Persistence and migration.** Profile/settings/exclusion storage, upgrade migration,
  corrupt-file recovery, and concurrent write are entirely uncovered.
- **Cancellation and lifecycle.** What happens on cancel mid-scan, quit mid-clean, sleep
  mid-operation, or Full Disk Access revoked during a scan — reasoned about, never tested.
- **Rule loading hardening.** I confirmed rules are bundled and validated
  (`Scripts/validate-rules.sh`, 97 tests) but did not test Yams against a billion-laughs or
  deeply-nested YAML payload, and did not audit rule fields for ReDoS in glob or regex
  construction.
- **Performance.** No measurement of any kind. No large-tree scan, no allocation profile,
  no memory high-water mark, no main-thread-blocking audit. The 0.4.6 changelog claims a
  scan went from ~2 minutes to ~22 seconds; I neither confirmed nor challenged that.
- **Mutation testing.** `muter` is configured and has its own workflow; I did not run it.

**Things I deliberately did not do, per the audit's own rules.** No destructive operation
was executed against real data: no Deep Clean execute, no Uninstaller scrub, no Quarantine
apply, no duplicate delete, and no developer-tool prune. `pnpm store prune` in particular
was never run — only the read-only `pnpm store path`. No bundled rule file was modified. No
commit, branch, or push was made. Nothing outside the repo was written except read-only
inspection.

**One subagent claim I killed rather than reported.** A parallel sweep concluded that the
pnpm failure was caused by the resolver selecting a dead mise shim ("No version is set for
shim: pnpm"). I ran that shim myself and it works — `--version` returns `11.17.0`,
`store path` exits 0. The claim was wrong and does not appear in this report. I mention it
because it is the one place where an unverified hand-off would have sent an implementer
after the wrong fix entirely, and it is the reason every finding above was re-derived
from the source before it was written down.
