# Product Requirements Document
## Gargantua — Native macOS System Cleaner & Optimizer

**Project Name:** Gargantua
**Company:** Inceptyon Labs LLC
**Author:** Jason
**Date:** April 14, 2026
**Version:** 5.0 — Final
**Domains:** gargantua.dev · gargantua.app (pending registration)
**Changelog:**
- v1.0: Initial feature spec
- v2.0: Trust Layer, tighter MVP, AI integration, cleanup profiles
- v3.0: Hybrid engine strategy (Mole bootstrap → native scanner), MCP server spec
- v4.0: AI advisory-only constraint, profile-aware YAML safety overrides, lazy model loading, bundle size budget, monetization model, naming candidates, TCC subprocess guidance
- v5.0: Finalized name (Gargantua), branding integration, consolidated final document

**Implementation Note (April 23, 2026):** This PRD captures the product direction and the original Mole-to-native transition plan. The current repo implementation has already completed the runtime cutover to native scanning/status/analyze paths for shipped features, bundles YAML cleanup and uninstall rules in-app, and documents community rule contribution workflow in `CONTRIBUTING.md` and `docs/rules/`.

---

## 1. Vision & Objective

**Gargantua** — named after the black hole in Interstellar — is a native macOS application that devours your Mac's junk. It replaces CleanMyMac X with a free, privacy-first, developer-focused alternative. The app bootstraps on **Mole's** domain knowledge while building toward a fully native Swift scanning engine, layers in AI intelligence — both on-device and cloud — and exposes an MCP server so AI agents can interact with the cleaner programmatically.

### The One-Liner

**"Gargantua devours your Mac's junk. Open source. Explainable. AI-assisted. Zero BS."**

### Goals

- Eliminate the $40+/year CleanMyMac subscription for power users and developers.
- Make every cleanup action explainable and auditable — the "trust gap" is the #1 thing to solve.
- Build a native scanning engine informed by Mole's battle-tested path knowledge, not permanently dependent on it.
- Ship as a signed, notarized `.app` bundle with zero telemetry.
- Expose an MCP server so the app becomes a first-class citizen in agentic AI workflows.
- Target macOS 14 (Sonoma)+; Apple Silicon native.

### Target User (ICP)

**Primary: Developer Mac Owners**

Already have Homebrew, Docker, Node.js, Xcode. Accumulate massive junk (node_modules, build artifacts, simulator caches, Docker images). Trust open source, hate subscriptions, comfortable with CLI but want a polished GUI for maintenance tasks they don't want to think about.

**Secondary: Privacy-Conscious Prosumers**

Tech-savvy non-developers who care about telemetry and want a GUI. Served through the same interface via cleanup profiles (§5.3).

### Non-Goals

- Real-time antivirus daemon (out of scope for v1).
- Cross-platform support (macOS only).
- Competing with CleanMyMac on marketing polish — compete on trust and transparency.

---

## 2. Core Design Principle: The Trust Layer

> *"If users feel safe clicking 'Clean' without anxiety, you win. If they hesitate, you lose."*

The Trust Layer is the foundational design system. Not a feature — an architectural decision that permeates every scan result, every action button, every piece of UI copy.

### 2.1 Safety Classification

Every item surfaced by any scan receives a `SafetyLevel`:

| Level | Badge | Meaning | Default Action |
|---|---|---|---|
| `safe` | 🟢 Green | Regenerated automatically by the system or app. No risk. | Auto-selected for cleanup |
| `review` | 🟡 Yellow | Probably safe, but may contain user data or preferences. | Not selected; expandable details |
| `protected` | 🔴 Red | System-critical, actively in use, or explicitly whitelisted. | Cannot select without override |

### 2.2 Explainability

Every item includes:

- **What it is** — human-readable name (e.g., "Chrome browser cache")
- **Why it's safe** — one-line explanation (e.g., "Cache files are regenerated automatically when you browse")
- **Who created it** — source attribution (Apple / known app / unknown developer)
- **Size** — bytes reclaimable
- **Last accessed** — staleness indicator
- **Confidence** — percentage confidence in safety classification

Example UI card:
```
🟢 Chrome Cache                                    10.5 GB
   Safe: Browser cache files. Regenerated automatically on next visit.
   Source: Google Chrome (signed, verified developer)
   Last accessed: 3 days ago
   Confidence: 99%
```

### 2.3 Audit Trail

- Every destructive operation logged to `~/Library/Logs/Gargantua/audit.json`
- Entry includes: timestamp, tool/engine used, command, files affected (paths + sizes), safety level, confirmation method
- "Undo" button linking to Trash for recent ops
- 90-day retention, configurable

### 2.4 Confirmation Tiers

| Scenario | Confirmation UX |
|---|---|
| All items `safe` | Single "Clean" button with total size |
| Mix of `safe` and `review` | Summary dialog listing `review` items explicitly |
| Any `protected` items selected | Full modal with item-by-item acknowledgment |

### 2.5 AI Is Advisory Only — YAML Rules Are Authoritative

**Critical constraint:** AI (all tiers) can explain, contextualize, and suggest, but it can **never** change a safety classification. The deterministic YAML rules are the sole source of truth for `SafetyLevel`.

| Action | AI Allowed? |
|---|---|
| Explain why a file has its current safety level | ✅ Yes |
| Provide additional context ("this cache is 8 months old") | ✅ Yes |
| Suggest the user might want to reclassify an item | ✅ Yes (as a suggestion with reasoning) |
| Automatically change a 🟡 to a 🟢 | ❌ Never |
| Override a 🔴 Protected classification | ❌ Never |

**Why:** LLMs hallucinate confidently. If the AI incorrectly marks a local database as safe and the user deletes it, we've violated the core trust promise. One incident like this kills adoption. The YAML rules are deterministic, auditable, and community-reviewed — they are the safety floor that AI cannot lower.

If the AI believes a classification is wrong, it surfaces this as: *"💡 AI Note: This item is marked Review, but it appears to be a regenerable cache. Consider adding it to your safe list in Settings → Scan Rules."* The user makes the final call.

---

## 3. Engine Strategy: Mole Bootstrap → Native Scanner

This is the most consequential architecture decision in the project. The strategy is: **ship fast with Mole, transition to a native engine that's better for our Trust Layer and MCP server.**

This section documents the transition strategy that shaped the product. In the current repo, the shipped implementation has already moved past the Mole-wrapper runtime for the main app flows.

### 3.1 Why Not Just Wrap Mole Forever?

Mole (44k stars, MIT, actively maintained) is excellent. But permanently depending on it creates friction with our core goals:

| Need | Mole Wrapper | Native Scanner |
|---|---|---|
| Per-item safety classification | Reverse-engineer from category output | Built-in — every rule carries safety metadata |
| Per-item explanations | Static mapping after the fact | Baked into rule definitions |
| Confidence scoring | Not possible | Derived from rule specificity + file metadata |
| MCP server granularity | Coarse (categories) | Fine (individual items with full metadata) |
| macOS API integration | None (subprocess) | Full access to NSFileManager, Spotlight metadata, code signing, Launch Services |
| App uninstall intelligence | Good but opaque | Can query LSRegisterURL, NSWorkspace, bundle inspection |
| Supply chain risk | Dependent on tw93's decisions | Self-owned |
| Update latency | Wait for upstream | Ship immediately |

### 3.2 Why Not Build Native From Scratch?

Because the real value in Mole isn't the code — it's the **domain knowledge**: which paths to scan, which caches are safe, which apps leave remnants where, how CoreSimulator volumes work, which browser stores data in which directory. That knowledge took years and thousands of users to accumulate. Replicating it through trial and error would take 6-12 months and produce worse results.

### 3.3 The Hybrid Strategy

Historical transition plan:

```
Phase 1 (MVP)                    Phase 1.5 (Parallel)              Phase 2+
─────────────                    ────────────────────              ──────────
┌─────────────┐                  ┌─────────────────┐              ┌─────────────────┐
│ Mole Binary │──json──▶ UI      │ Port Mole's     │              │ Native Scanner  │
│ (bundled)   │                  │ path knowledge  │              │ (Swift)         │
│             │                  │ into declarative│              │                 │
│ mo clean    │                  │ YAML rule files │              │ Rules Engine    │
│ mo purge    │                  │ with Trust Layer│──────▶       │ + Trust Layer   │──▶ UI
│ mo analyze  │                  │ metadata        │              │ + MCP Server    │
│ mo status   │                  │                 │              │ + AI Integration│
└─────────────┘                  └─────────────────┘              └─────────────────┘
                                                                        │
                                                                  Mole kept as
                                                                  optional fallback
                                                                  for edge cases
```

### 3.4 Declarative Scan Rules (The Portable Knowledge Layer)

The key architectural insight: extract Mole's scan logic into a declarative rule format that both the Mole wrapper AND the native scanner can use. This is the bridge between phases.

```yaml
# Example: cleanup_rules/browser/chrome.yaml
rules:
  - id: chrome_cache
    name: "Chrome Browser Cache"
    paths:
      - "~/Library/Caches/Google/Chrome"
      - "~/Library/Caches/com.google.Chrome"
    pattern: "**/*"
    exclude:
      - "*.sqlite"  # bookmark/history DBs
    safety: safe
    confidence: 99
    explanation: "Browser cache files. Regenerated automatically when you browse."
    source:
      name: "Google Chrome"
      bundle_id: "com.google.Chrome"
      verify_signature: true
    regenerates: true
    category: browser_cache
    tags: [cache, browser, chromium]

  - id: chrome_local_storage
    name: "Chrome Local Storage"
    paths:
      - "~/Library/Application Support/Google/Chrome/Default/Local Storage"
    safety: review
    confidence: 70
    explanation: "Website local storage. May contain login sessions and preferences."
    source:
      name: "Google Chrome"
      bundle_id: "com.google.Chrome"
    regenerates: false
    category: browser_data
    tags: [user_data, browser, chromium]
    # Profile-aware overrides: same rule, different behavior per profile
    safety_overrides:
      - condition: "age > 90d"
        safety: safe
        explanation_suffix: "No browser activity in 90+ days."
        profiles: [deep]

  - id: chrome_extensions
    name: "Chrome Extensions"
    paths:
      - "~/Library/Application Support/Google/Chrome/Default/Extensions"
    safety: protected
    confidence: 95
    explanation: "Installed browser extensions. Removing these will uninstall your extensions."
    source:
      name: "Google Chrome"
      bundle_id: "com.google.Chrome"
    regenerates: false
    category: browser_extensions
    tags: [user_data, browser, chromium, extensions]
```

```yaml
# Example: cleanup_rules/developer/node.yaml — showing profile overrides
rules:
  - id: node_modules
    name: "Node.js Dependencies"
    paths:
      - "~/Projects/**/node_modules"
      - "~/Developer/**/node_modules"
      - "~/GitHub/**/node_modules"
    safety: review    # base: requires review
    confidence: 85
    explanation: "npm/yarn dependency folders. Can be restored with 'npm install'."
    source:
      name: "Node.js / npm"
    regenerates: true
    regenerate_command: "npm install"
    category: dev_artifacts
    tags: [developer, node, dependencies]
    # The Developer profile automatically classifies old node_modules as safe
    safety_overrides:
      - condition: "age > 30d"
        safety: safe
        confidence: 95
        explanation_suffix: "No project activity in 30+ days. Restore with 'npm install'."
        profiles: [developer, deep]
      - condition: "age > 7d"
        safety: safe
        confidence: 90
        explanation_suffix: "Inactive for over a week. Restore with 'npm install'."
        profiles: [deep]
```

**Profile-aware overrides prevent Review bucket fatigue.** Without them, the Developer profile would dump hundreds of node_modules into 🟡 Review and users would either ignore the app or blindly "select all." With overrides, the Developer profile automatically classifies stale dev artifacts as 🟢 Safe with clear reasoning, while the Light profile keeps them as 🟡 Review for cautious users.

**Rule file organization:**
```
cleanup_rules/
├── system/
│   ├── caches.yaml
│   ├── logs.yaml
│   ├── temp.yaml
│   └── trash.yaml
├── browser/
│   ├── chrome.yaml
│   ├── safari.yaml
│   ├── firefox.yaml
│   ├── arc.yaml
│   └── brave.yaml
├── developer/
│   ├── xcode.yaml
│   ├── node.yaml
│   ├── homebrew.yaml
│   ├── docker.yaml
│   ├── rust.yaml
│   ├── python.yaml
│   └── go.yaml
├── apps/
│   ├── spotify.yaml
│   ├── slack.yaml
│   ├── dropbox.yaml
│   └── ...
└── uninstall/
    ├── remnant_locations.yaml    # 52+ locations from Mole
    └── launch_agents.yaml
```

**This is also a massive open-source contribution story.** Community members submit PRs to add rules for apps they use. Each rule is human-readable, auditable, and carries Trust Layer metadata. This becomes the "AdGuard filter list" equivalent for Mac cleanup.

Implementation note: the repo now includes a starter kit for this workflow in `CONTRIBUTING.md`, `docs/rules/`, `docs/rules/templates/`, and `Scripts/validate-rules.sh`.

### 3.5 Phase-by-Phase Engine Transition

The table below reflects the planned transition path. The current implementation has already surpassed the runtime assumptions in Phase 1 / 1.5 for the shipped cleanup flows by removing the active `mo` dependency from the app runtime.

| Phase | Clean Engine | Uninstall Engine | Analyze Engine | Status Engine |
|---|---|---|---|---|
| 1 (MVP) | Mole `mo clean` + Trust Layer mapping | — (Phase 2) | Mole `mo analyze` | Mole `mo status --json` |
| 1.5 | Native scanner (YAML rules) for categories with good coverage; Mole fallback for rest | — | Mole `mo analyze` | Native via `sysctl` / `IOKit` |
| 2 | Native scanner (full coverage) | Native via `NSWorkspace` + `LSRegisterURL` + YAML remnant rules | SwiftUI treemap view | Native |
| 3+ | Native scanner | Native | Native | Native |

### 3.6 What We Keep From Mole Long-Term

- **The scan rule database** — ported into YAML, continuously enriched
- **The safety philosophy** — dry-run defaults, whitelisting, confirmation before delete
- **Optional CLI companion** — originally envisioned as an optional validation path; not part of the current shipped runtime architecture

---

## 4. Complementary CLI Tools

These fill gaps that neither Mole nor our native scanner cover.

### 4.1 Duplicate File Finder — fclones

**Tool:** [fclones](https://github.com/pkolaczk/fclones) (Rust, MIT, `brew install fclones`)

Best-in-class duplicate finder. Rust, parallel I/O, SSD/HDD-aware, JSON output, two-phase workflow, hash caching. This stays as a bundled binary long-term — duplicate detection is a hard algorithmic problem not worth reimplementing.

**Features:** Duplicate scanning, filtering (size/name/regex/depth), resolution (trash/delete/hardlink/symlink), `--rf-over N`, `--isolate` cross-directory, hash caching.

**Trust Layer:** All duplicates 🟡 review by default. AI Advisor can upgrade with explanation.

### 4.2 File Health Scanner — czkawka_cli

**Tool:** [czkawka](https://github.com/qarmin/czkawka) (Rust, MIT, GitHub releases)

Covers: similar images (perceptual hashing), similar videos, empty files/folders, broken symlinks, temp files, corrupted files, big files. Also stays as a bundled binary — perceptual hashing is specialized.

**Trust Layer:** Empty folders/files → 🟢. Broken symlinks → 🟢. Similar images → 🟡. Corrupted files → 🟡.

### 4.3 Homebrew & Docker — User's Own CLI

Detected at runtime, hidden if not installed. `brew cleanup`, `brew autoremove`, `brew doctor`, `docker system prune`, `docker system df`.

### 4.4 Tool Dependency Matrix

| Tool | Bundled? | Long-term Plan | Rollback Strategy |
|---|---|---|---|
| Mole (`mo`) | Yes (Phase 1) | Replace with native scanner (Phase 2+) | Pin to tested version |
| fclones | Yes (permanent) | Keep — algorithmic problem not worth reimplementing | Pin + rollback in Settings |
| czkawka_cli | Yes (permanent) | Keep — perceptual hashing is specialized | Pin + rollback in Settings |
| Homebrew | No | User's own | N/A |
| Docker | No | User's own | N/A |

**Failure isolation:** Each tool runs in its own `Process` with timeout. Crash/hang → catch, log, disable feature with visible warning, continue operating.

---

## 5. User Interface Design

### 5.1 Design Principles

- **Trust-first** — every screen answers "is this safe?" before "how much space?"
- **Scan → Preview → Act** — universal three-step flow
- **Three-bucket results** — Safe / Review / Protected split on every scan
- **Progressive disclosure** — summary default, expandable details
- **Native macOS** — system materials, vibrancy, SF Symbols
- **Dark mode first** with full light mode support
- **Accessible** — VoiceOver, keyboard nav, Dynamic Type

### 5.2 Navigation Structure

```
Sidebar
├── Dashboard (health + actionable alerts)
├── ─────────────
├── Deep Clean
├── Smart Uninstaller
├── Disk Explorer
├── ─────────────
├── Duplicates
├── File Health
│   ├── Similar Images
│   ├── Large Files
│   ├── Empty Files & Folders
│   └── Broken Symlinks
├── ─────────────
├── Developer Tools
│   ├── Dev Artifact Purge
│   ├── Homebrew
│   └── Docker
├── ─────────────
├── AI Advisor (§6)
├── ─────────────
└── Settings
    ├── Cleanup Profiles
    ├── Scan Rules (view/edit YAML rules)
    ├── Whitelists
    ├── Tool Versions & Engine
    ├── AI Configuration
    ├── MCP Server (§7)
    └── Audit Log
```

### 5.3 Cleanup Profiles

| Profile | Pre-selected Categories | Target User |
|---|---|---|
| **Developer** | All caches + dev artifacts + Docker + Homebrew + installers | Primary ICP |
| **Light Cleanup** | Browser caches + system logs + Trash + installers | Prosumers |
| **Deep Clean** | Everything + similar images + empty files + broken symlinks | Quarterly cleanup |
| **Custom** | User-defined, saved as named profile | Advanced users |

### 5.4 Dashboard

- **Health Score** — gauge (0-100) from CPU, memory, disk, temp
- **Actionable Alerts** — "23 GB of reclaimable dev artifacts" / "Docker using 12 GB of build cache"
- **Trends** — sparklines showing reclaimable space over time
- **Quick Scan** — runs active profile's categories
- **Hardware Info** — model, chip, RAM, macOS version
- **Engine Status** — which engine (Mole / Native) is active, tool versions, errors
- **MCP Server Status** — running/stopped, connected clients

### 5.5 Scan Results Pattern

1. **Summary bar** — items found, reclaimable space, scan duration
2. **Three-bucket split:**
   - 🟢 **Safe to Clean** — expanded, pre-selected
   - 🟡 **Review Required** — collapsed, not selected
   - 🔴 **Protected** — shown, not actionable without override
3. **Item list** — checkboxes, size, path, last accessed, explanation, confidence
4. **Action bar** — "Clean Safe Items" / "Clean Selected" with total
5. **Confirmation dialog** — exact list of what happens; "Move to Trash" default

---

## 6. AI Integration

AI solves three problems traditional cleaners can't: explainability, smart classification, and natural language interaction.

### 6.1 Three-Tier Architecture

```
┌───────────────────────────────────────────────────┐
│                AI Service Protocol                │
│                                                   │
│  ┌───────────┐ ┌────────────┐ ┌────────────────┐ │
│  │  Tier 1   │ │  Tier 2    │ │    Tier 3      │ │
│  │ On-Device │ │ Claude API │ │ Claude Code    │ │
│  │   (MLX)   │ │  (Cloud)   │ │ Agent (-p)     │ │
│  │           │ │            │ │                │ │
│  │ Private   │ │ Fast +     │ │ Agentic +      │ │
│  │ Free      │ │ Capable    │ │ Autonomous     │ │
│  │ Offline   │ │ Opt-in     │ │ Power user     │ │
│  └───────────┘ └────────────┘ └────────────────┘ │
└───────────────────────┬───────────────────────────┘
                        │
              Unified AIServiceProtocol
                        │
              Trust Layer Integration
```

All tiers conform to one Swift protocol. App selects highest available tier by default, user override in Settings. All AI features degrade gracefully — app is fully functional with AI disabled.

### 6.2 Tier 1: On-Device AI (MLX)

**Backend:** MLX Swift bindings or `mlx-lm` subprocess
**Model:** Quantized 4-bit, sub-3B parameter model preferred (e.g., Llama 3.2 1B or 3B). A 7B+ model is overkill for file path explanations — this is a domain-specific task, not general reasoning.
**Privacy:** 100% on-device, zero network

| Feature | Description |
|---|---|
| File Explanation | Click "?" on any result → local LLM explains what it is and why the YAML rule assigned its safety level |
| Classification Advisory | LLM reviews 🟡 items and *suggests* the user might want to reclassify — but never changes the badge itself (see §2.5) |
| Natural Language Search | "Show me everything related to Xcode" → maps to scan filters |
| Cleanup Summary | Post-cleanup narrative: "Cleaned 23 GB: Chrome cache (10 GB), Xcode sims (8 GB)..." |

**Model lifecycle (critical for bundle size and performance):**

- **Never bundled in the app.** The app ships at < 50 MB without AI models. Model is an optional post-install download.
- **Lazy loading.** Model is loaded into memory only when the user explicitly clicks an AI feature (e.g., the "?" explain button). Not loaded at app launch.
- **Eager unloading.** Model is evicted from memory after 60 seconds of inactivity. A cleanup app that consumes 5 GB of RAM to explain a 10 MB cache file would be immediately uninstalled by our ICP.
- **Phase 1 fallback.** Without a model, explanations come from the YAML rule's `explanation` string. This is good enough for launch — the AI explain button simply doesn't appear until a model is downloaded.
- **Storage:** `~/Library/Application Support/Gargantua/models/`

**Fine-tuned LoRA (Phase 2+):** Train a small LoRA adapter on macOS file path explanations using MLX's built-in LoRA fine-tuning. This allows using a much smaller base model (1B) while getting domain-specific quality that rivals a 7B general model. Training data: curated dataset of (file_path, explanation, safety_rationale) tuples. Cheap to produce, massive quality uplift for this narrow domain.

### 6.3 Tier 2: Claude API (Cloud)

**Backend:** Anthropic API (claude-sonnet-4-20250514)
**Privacy:** Opt-in. File metadata only (paths, sizes, categories — never contents). User provides API key.
**Cost:** ~$0.001-0.01 per analysis

| Feature | Description |
|---|---|
| Deep Analysis Report | Comprehensive scan analysis with prioritized cleanup plan |
| Anomaly Detection | "12 copies of same Xcode archive across folders" / "Docker cache unpruned for 6 months" |
| Target-Based Cleanup | "Free up 20 GB for video project" → recommends safest combination |
| Duplicate Conflict Resolution | "Keep the one in ~/Documents/active — it was modified most recently" |
| Scan Rule Suggestions | Analyzes user's system and suggests new YAML rules for apps not yet covered |

### 6.4 Tier 3: Claude Code Agent (`claude -p`)

**Backend:** Claude CLI in non-interactive mode
**Prerequisite:** Claude Code installed and authenticated

| Feature | Description |
|---|---|
| Investigative Cleanup | "Why is my disk 90% full?" → runs analysis tools, produces narrative report |
| Project Archaeology | "Which old repos can I archive?" → checks git status, last commits, dep freshness |
| Custom Maintenance Scripts | Generates tailored shell scripts + launchd plists for scheduled cleanup |
| Scheduled AI Audits | Runs on schedule via launchd, produces maintenance reports |
| MCP-Integrated Agent | Agent connects to the app's MCP server to perform cleanup through the Trust Layer |

**Safety:** `--allowedTools` scoped to read-only by default. Destructive plans require user confirmation in GUI. `--max-turns` capped. All actions in audit trail.

### 6.5 AI Feature Matrix

| Feature | Tier 1 | Tier 2 | Tier 3 | No AI |
|---|---|---|---|---|
| File explanations | ✅ Basic | ✅ Detailed | ✅ Detailed | YAML strings |
| Classification advisory (suggestion only) | ✅ | ✅ Better | ✅ Best | ❌ |
| Natural language search | ✅ Simple | ✅ | ✅ | ❌ |
| Cleanup summary | ✅ | ✅ | ✅ | ❌ |
| Deep analysis | ❌ | ✅ | ✅ | ❌ |
| Anomaly detection | ❌ | ✅ | ✅ | ❌ |
| Investigative analysis | ❌ | ❌ | ✅ | ❌ |
| Custom scripts | ❌ | ❌ | ✅ | ❌ |
| MCP agent integration | ❌ | ❌ | ✅ | ❌ |
| **Privacy** | 🟢 Full | 🟡 Metadata | 🟡 Metadata | 🟢 Full |
| **Cost** | Free | ~$0.01/scan | ~$0.05/task | Free |
| **RAM impact** | ~1-3 GB (lazy loaded, auto-unloads) | None | None | None |

### 6.6 AI Service Protocol

```swift
protocol AIServiceProtocol {
    var tier: AITier { get }
    var isAvailable: Bool { get }
    
    func explain(item: ScanResult) async throws -> Explanation
    func classifySafety(items: [ScanResult]) async throws -> [SafetyAssessment]
    func analyzeScan(manifest: ScanManifest) async throws -> AnalysisReport?
    func interpretQuery(naturalLanguage: String) async throws -> ScanFilter?
    func generateSummary(cleanup: CleanupResult) async throws -> String
}
```

---

## 7. MCP Server

The Gargantua app exposes a Model Context Protocol (MCP) server, making it a first-class tool for AI agents. Any MCP-compatible client (Claude Code, Claude Desktop, custom agents) can scan, analyze, and clean the Mac through the Trust Layer's safety guardrails.

### 7.1 Why MCP?

- **Developer story:** "Clean your Mac from your terminal agent" — this is the kind of thing our developer ICP would love
- **AI-native integration:** Claude Code agents can use the cleaner as a tool without screen-scraping CLI output
- **Composability:** The cleaner becomes one tool in a larger agentic workflow (e.g., "set up my dev environment" includes cleaning up the old one)
- **Ecosystem play:** As more apps expose MCP servers, being part of that ecosystem is strategic

### 7.2 MCP Server Spec

**Transport (Phase 2):** stdio only — targets Claude Code (`claude -p`) which is the primary MCP consumer for our ICP.
**Transport (Phase 3):** Add SSE over localhost for Claude Desktop and other GUI clients.
**Port (SSE, Phase 3):** User-configurable, default `localhost:7493`
**Auth:** Local-only by default. Optional bearer token for non-localhost connections (Phase 3).

### 7.3 MCP Tools

```typescript
// Tool: scan
// Runs a scan using the active cleanup profile or specified categories
{
  name: "scan",
  description: "Scan the Mac for reclaimable space. Returns categorized results with safety levels.",
  parameters: {
    profile: "developer" | "light" | "deep" | "custom",  // optional, default: active profile
    categories: ["browser_cache", "dev_artifacts", ...],  // optional, overrides profile
    dry_run: true  // always true when called via MCP
  },
  returns: {
    total_reclaimable: "23.5 GB",
    items: [
      {
        id: "chrome_cache_001",
        name: "Chrome Browser Cache",
        path: "~/Library/Caches/Google/Chrome",
        size: "10.5 GB",
        safety: "safe",
        confidence: 99,
        explanation: "Browser cache files. Regenerated automatically.",
        source: "Google Chrome",
        last_accessed: "2026-04-11T14:30:00Z",
        category: "browser_cache"
      },
      // ...
    ],
    summary: {
      safe_count: 45, safe_size: "18.2 GB",
      review_count: 12, review_size: "5.3 GB",
      protected_count: 3
    }
  }
}

// Tool: clean
// Executes cleanup on specified items. Requires explicit item IDs.
{
  name: "clean",
  description: "Clean specified items. Only accepts items from a prior scan. Moves to Trash by default.",
  parameters: {
    item_ids: ["chrome_cache_001", "xcode_derived_data_002", ...],
    method: "trash" | "delete",  // default: trash
    confirm: true  // must be true; MCP cannot bypass confirmation
  },
  returns: {
    cleaned: 12,
    freed: "15.3 GB",
    method: "trash",
    audit_id: "audit_2026-04-14_001"
  }
}

// Tool: analyze
// Returns system health and disk usage overview
{
  name: "analyze",
  description: "Get system health score, disk usage breakdown, and recommendations.",
  returns: {
    health_score: 85,
    disk: { total: "500 GB", used: "380 GB", free: "120 GB" },
    top_consumers: [...],
    recommendations: [
      "23 GB of dev artifacts older than 30 days",
      "Docker build cache hasn't been pruned in 3 months"
    ]
  }
}

// Tool: explain
// Get a detailed explanation of a specific path or scan item
{
  name: "explain",
  description: "Explain what a file or directory is, its safety level, and whether it can be cleaned.",
  parameters: {
    path: "~/Library/Caches/com.apple.dt.Xcode"  // or item_id from scan
  },
  returns: {
    name: "Xcode Derived Data Cache",
    safety: "safe",
    confidence: 95,
    explanation: "Build artifacts from Xcode projects. Regenerated on next build. Safe to remove.",
    size: "8.2 GB",
    last_accessed: "2026-04-10T09:15:00Z"
  }
}

// Tool: list_profiles
// Returns available cleanup profiles
{
  name: "list_profiles",
  description: "List available cleanup profiles and their categories.",
  returns: {
    profiles: [
      { name: "developer", categories: [...], description: "..." },
      { name: "light", categories: [...], description: "..." }
    ],
    active: "developer"
  }
}

// Tool: status
// Returns real-time system metrics
{
  name: "status",
  description: "Get real-time system health metrics (CPU, memory, disk, network).",
  returns: {
    health_score: 92,
    cpu: { usage: 45.2, cores: 10 },
    memory: { used: "14.2 GB", total: "32 GB", percent: 44.4 },
    disk: { used: "380 GB", total: "500 GB", percent: 76 },
    uptime: "6d 12h"
  }
}
```

### 7.4 MCP Safety Guardrails

- **Scan is always dry-run** — MCP `scan` never deletes anything; it only reports what could be cleaned
- **Clean requires explicit item IDs** — agent can't say "clean everything"; must reference specific items from a prior scan
- **Trust Layer enforced** — MCP clients cannot bypass safety levels. 🔴 Protected items cannot be cleaned via MCP at all. 🟡 Review items require the `confirm: true` parameter.
- **Audit trail** — all MCP-initiated actions logged with client identifier
- **Rate limiting** — max 1 clean operation per 60 seconds via MCP to prevent automated runaway deletion
- **User notification** — app shows a notification when an MCP client initiates a clean action, with option to cancel

### 7.5 MCP Usage Examples

**Claude Code agent cleaning dev artifacts:**
```bash
claude -p "My disk is almost full. Use Gargantua MCP to scan for dev artifacts and clean anything safe." \
  --mcp-config ~/.claude/mcp_config.json \
  --allowedTools "mcp__gargantua__scan,mcp__gargantua__clean,mcp__gargantua__analyze" \
  --max-turns 5
```

**Claude Desktop conversation:**
```
User: "How much space can I free up?"
Claude: [calls scan tool with "developer" profile]
"You have 34 GB of reclaimable space. The biggest items are:
 - 15 GB of node_modules across 12 old projects
 - 8 GB of Xcode derived data
 - 6 GB of Docker build cache
 All of these are marked safe to clean. Want me to clean them?"
User: "Yes, clean the safe items"
Claude: [calls clean tool with safe item IDs]
"Done. Freed 29 GB. Everything was moved to Trash in case you need it back."
```

**Custom agent in a dev environment setup script:**
```python
# Part of a "set up my new project" workflow
import subprocess, json

# Clean up before starting
result = subprocess.run(
    ["claude", "-p", "Use Gargantua to free up space for my new project. "
     "Scan dev artifacts and clean anything safe. Report what you freed.",
     "--mcp-config", "mcp_config.json",
     "--output-format", "json",
     "--max-turns", "5"],
    capture_output=True, text=True
)
report = json.loads(result.stdout)
print(f"Freed {report.get('freed', 'unknown')} before project setup")
```

### 7.6 MCP Configuration

Gargantua generates its own MCP config entry for easy registration:

```json
// Auto-generated at ~/Library/Application Support/Gargantua/mcp_server.json
{
  "mcpServers": {
    "gargantua": {
      "command": "/Applications/Gargantua.app/Contents/Resources/bin/gargantua-mcp",
      "args": ["--port", "7493"],
      "env": {}
    }
  }
}
```

User can add this to their Claude Code config (`~/.claude.json`) or Claude Desktop config with one click from Gargantua's Settings → MCP Server panel.

---

## 8. Application Architecture

### 8.1 Tech Stack

| Layer | Technology |
|---|---|
| UI | SwiftUI (macOS 14+) |
| Scanning (Phase 1) | Mole subprocess + YAML rule mapping |
| Scanning (Phase 2+) | Native Swift `FileManager` + YAML rules engine |
| Duplicates | fclones subprocess (permanent) |
| File Health | czkawka_cli subprocess (permanent) |
| AI (On-Device) | MLX Swift / `mlx-lm` subprocess |
| AI (Cloud) | Anthropic Swift SDK |
| AI (Agent) | `claude` CLI via `Process` |
| MCP Server | Swift NIO (SSE) / stdio handler |
| Data Layer | SwiftData (scan history, settings, profiles, audit) |
| Background | Swift Concurrency (`async/await`, `TaskGroup`) |
| Distribution | Signed + notarized `.app`, Homebrew Cask |

### 8.2 System Architecture

```
┌───────────────────────────────────────────────────────────┐
│                    SwiftUI Frontend                       │
├───────────────────────────────────────────────────────────┤
│                    Trust Layer Engine                     │
│  Safety classification · Explainability · Confidence ·   │
│  Audit logging · Confirmation tiers                      │
├───────────────────────────────────────────────────────────┤
│              AI Service Layer (Protocol)                  │
│  ┌──────────┐  ┌────────────┐  ┌───────────────────┐    │
│  │MLX Local │  │Claude API  │  │Claude Code Agent  │    │
│  └──────────┘  └────────────┘  └───────────────────┘    │
├───────────────────────────────────────────────────────────┤
│              Scan Engine (Abstraction)                    │
│  ┌────────────────────┐  ┌─────────────────────────┐    │
│  │  Mole Adapter      │  │  Native Scanner         │    │
│  │  (Phase 1)         │  │  (Phase 2+)             │    │
│  │  Subprocess + JSON │  │  FileManager + YAML     │    │
│  └────────────────────┘  └─────────────────────────┘    │
├──────────────┬──────────────┬─────────────────────────────┤
│  fclones     │  czkawka_cli │  brew / docker (detected)  │
│  (bundled)   │  (bundled)   │                            │
├──────────────┴──────────────┴─────────────────────────────┤
│                    MCP Server                             │
│  stdio + SSE · Trust Layer enforced · Audit logged       │
└───────────────────────────────────────────────────────────┘
```

### 8.3 Bundle Size Budget

Gargantua targets developers who hate bloat. Strict size constraints:

| Component | Size Budget | Notes |
|---|---|---|
| App binary (SwiftUI) | < 15 MB | Native Swift, no Electron |
| Bundled `mo` | ~10 MB | Single Go binary |
| Bundled `fclones` | ~5 MB | Single Rust binary |
| Bundled `czkawka_cli` | ~10 MB | Single Rust binary |
| MCP server binary | ~5 MB | Swift NIO |
| YAML rule files | < 1 MB | Text files, grows with community |
| **Total app bundle** | **< 50 MB** | **Competitive with AppCleaner (~5 MB), far lighter than CleanMyMac (~90 MB)** |
| MLX model (optional) | 1-3 GB | Post-install download, never bundled |
| LoRA adapter (optional) | ~50 MB | Post-install download |

**Phase 2+ (native scanner):** Removing bundled `mo` saves ~10 MB. Total drops to ~35 MB.

### 8.4 Resource Scheduling

- **Sequential pipeline** by default — never run fclones + czkawka + native scanner simultaneously
- **Idle-aware scanning** — optional "scan when idle" mode using `NSProcessInfo.thermalState` and CPU load checks
- **Priority queue** — user-initiated scans interrupt background scans
- **Progress consolidation** — all scan engines report progress through a unified `ScanProgress` observable

---

## 9. Permissions & Security

| Entitlement | Reason | Fallback if Denied |
|---|---|---|
| Full Disk Access | System caches, Library, Mail | Degrade to user-accessible paths; show limitation banner |
| Automation (Finder) | Move to Trash via Finder | Fall back to direct Trash API |
| Network (optional) | Claude API, update checks | AI Tier 2/3 disabled; everything else works |

**TCC & Subprocess Inheritance (Phase 1 Mole wrapper):**

When the app has Full Disk Access, child processes spawned via `Process` inherit the parent's TCC authorization. The `mo` binary won't trigger separate permission dialogs. However, this requires:
- The app's `Info.plist` correctly declares Full Disk Access usage
- Testing on a **clean macOS install** (not a dev machine with pre-authorized permissions) during QA
- The bundled `mo` binary is signed with the same team ID as the parent app
- If Finder automation is needed (for `mo analyze` Trash integration), the parent app must hold that entitlement

**Permission UX:** Onboarding flow explains each permission with a clear "what this unlocks" screen. No nagging — if denied, show what works without it. Each feature area shows a specific banner when limited by missing permissions (not a generic error).

**Security model:** No telemetry. Trash-first default. API keys in Keychain. AI never sees file contents, only metadata. MCP rate-limited and audit-logged. Claude Code agent scoped to read-only by default.

---

## 10. Release Phases

### Phase 1 — MVP (v0.1) — 6-8 weeks
**"Clean with confidence"**

- SwiftUI shell, sidebar, cleanup profiles, settings
- Trust Layer (safety classification, explanations, audit log)
- Deep Clean (Mole `mo clean` with Trust Layer mapping)
- Dev Artifact Purge (Mole `mo purge`)
- Disk Explorer (Mole `mo analyze`)
- Dashboard (health score, alerts, engine status)
- AI Tier 1 on-device (MLX, optional download)
- YAML scan rule files (initial set ported from Mole)

### Phase 1.5 — Native Scanner (parallel track)
**Port Mole's path knowledge into YAML rules; build native Swift scanner**

- Native `FileManager`-based scanner evaluating YAML rules
- Full Trust Layer metadata from rule definitions (not reverse-engineered)
- A/B comparison: run native scanner alongside Mole, verify parity
- Gradual cutover: native scanner for categories with good coverage, Mole fallback for rest

### Phase 2 — Intelligence (v0.2) — 4-6 weeks after v0.1
**"Find what you're missing"**

- Smart Uninstaller (native Swift, `NSWorkspace` + YAML remnant rules)
- Duplicate Finder (fclones)
- File Health (czkawka_cli — similar images, large files, empty files, broken symlinks)
- Developer Tools (Homebrew, Docker, installer cleanup)
- MCP Server (v1 — scan + analyze + explain tools)
- AI Tier 1 improvements (classification boost for duplicates)

### Phase 3 — AI Power (v0.3 → v1.0) — 4-6 weeks after v0.2
**"Your Mac, understood"**

- AI Tier 2 (Claude API — deep analysis, anomaly detection)
- AI Tier 3 (Claude Code agent — investigative, scripts, project archaeology)
- MCP Server (v2 — clean tool + full agent integration)
- Scheduled scans via launchd
- Menu bar widget
- Sparkle auto-updates
- Marketing site and distribution

---

## 11. Feature Parity vs. CleanMyMac

| CleanMyMac Feature | Covered By | Phase | Our Differentiator |
|---|---|---|---|
| System Junk | Mole → Native scanner | 1 | Trust Layer explains every item |
| Disk Analyzer | Mole → Native SwiftUI | 1-2 | — |
| System Monitor | Mole → Native | 1-2 | Actionable alerts, not just stats |
| Dev Cleanup | Mole → Native | 1 | **Developer-first; CleanMyMac barely covers this** |
| Uninstaller | Native Swift | 2 | `NSWorkspace` + Launch Services = richer metadata |
| Duplicates | fclones | 2 | AI-assisted resolution recommendations |
| Similar Photos | czkawka_cli | 2 | — |
| Large Files | czkawka_cli | 2 | — |
| **AI Explanations** | MLX / Claude | 1-3 | **No competitor has this** |
| **AI Cleanup Planning** | Claude API / Agent | 3 | **No competitor has this** |
| **Cleanup Profiles** | Custom | 1 | **CleanMyMac doesn't do this** |
| **MCP Server** | Custom | 2-3 | **No competitor has this** |
| **Community Rules** | YAML rule PRs | 1.5+ | **No competitor has this** |

---

## 12. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Mole wrapper is fragile in Phase 1 | Short-lived dependency; native scanner replaces it. Pin version. |
| YAML rule porting is labor-intensive | Start with highest-impact categories (dev tools, browsers). Community contributions accelerate coverage. |
| Native scanner misses edge cases Mole handles | A/B comparison during Phase 1.5; keep Mole as fallback. |
| AI hallucination overrides safety classification | AI is advisory-only (§2.5). YAML rules are authoritative. AI can never change a safety level. |
| Review bucket fatigue — too many 🟡 items | Profile-aware safety overrides in YAML rules. Developer profile auto-classifies stale artifacts as 🟢. |
| MLX model bloats RAM / app size | Model never bundled (< 50 MB app). Lazy load on explicit user action. Auto-unload after 60s idle. |
| Claude API costs surprise users | Show cost estimate before each call; spending cap in Settings. |
| MCP security — rogue agent deletes files | Trust Layer enforced; protected items blocked; rate limit; user notification; audit trail. |
| TCC permission dialogs for Mole subprocess | Parent app inherits FDA to children. Test on clean macOS install. Same team ID signing. |
| Binary bundling breaks notarization | Pre-validate in CI; test notarization before every release. |
| macOS permission changes | Graceful degradation per feature; monitor Apple dev docs. |

---

## 13. Success Metrics

- **Trust:** < 1% of users report accidental deletion
- **Developer wedge:** 60%+ of active users clean dev artifacts
- **AI adoption:** 30%+ enable Tier 1 AI within first week
- **MCP usage:** 10%+ of developer users connect via MCP within 3 months
- **GitHub traction:** 500+ stars within 3 months
- **Scan speed:** Deep Clean < 60 seconds
- **Retention:** 40%+ monthly active

---

## 14. Resolved Decisions

| Question | Decision | Rationale |
|---|---|---|
| AI safety model | Advisory-only. YAML rules are authoritative. | LLM hallucination risk is existential to the trust story. |
| Review bucket fatigue | Profile-aware safety overrides in YAML rules. | Without this, 80% of items land in 🟡 and nobody reviews them. |
| Model bundling | Never bundle. Optional post-install download. | < 50 MB app target. Developers hate bloat. |
| Model size | Target sub-3B (1B + LoRA preferred). | File path explanation is a narrow domain; 8B is overkill. |
| MCP transport (Phase 2) | stdio only. | Primary consumer is Claude Code. SSE added in Phase 3. |
| Community rules | Separate Git repo, MIT licensed. | Zero friction for contributors. Like gitignore templates. |

---

## 15. Branding: Gargantua

### Name Origin

Gargantua is the supermassive black hole in Christopher Nolan's *Interstellar* — a gravitational force that consumes everything around it. For a system cleaner, the metaphor is perfect: Gargantua devours your Mac's junk. The name fits the Inceptyon Labs portfolio (Tesseract, The Racket, Xenodex, TARS) and carries the right personality: powerful, inevitable, slightly dramatic.

### Trademark & Domain Status

| Asset | Status | Notes |
|---|---|---|
| Gargantua (Class 9 software) | No existing registrations found | Clear to file |
| gargantua.dev | Likely available | Primary domain — developer-focused TLD |
| gargantua.app | Likely available | App Store / consumer-facing TLD |
| getgargantua.com | Likely available | Marketing landing page fallback |
| GitHub org/repo | "Gargantua" user exists (inactive) | Use `gargantua-app` or `inceptyon/gargantua` |

**Action items:** Register domains immediately. File Class 9 trademark application after MVP launch (use in commerce required for TEAS Plus filing).

### CLI Companion Name

If Gargantua ever ships a standalone CLI tool alongside the GUI (or for the MCP server binary), the natural abbreviation is `garg`:

```bash
garg scan --profile developer
garg clean --safe-only
garg status --json
```

### Visual Identity Notes

- **Color palette:** Deep space blacks, accretion disk golds/oranges, gravitational lensing blues — consistent with the Interstellar visual language
- **App icon direction:** Stylized black hole / event horizon / gravitational lens. Minimal, geometric, works at 16x16 in the Dock.
- **Typography:** Mono or semi-mono for the developer audience. SF Mono or a custom display face for the wordmark.

---

## 16. Monetization Model

**The Docker model:** Core is free forever. Monetize the cloud layer.

| Tier | Price | What's Included |
|---|---|---|
| **Free (Open Source)** | $0 | Full app, all scanning, YAML rules, on-device AI (Tier 1), MCP server, community rule updates |
| **Pro** | $15-20/year | Built-in Claude API relay (no API key needed), scheduled background scans, advanced agent features (Tier 3), priority rule updates, email support |

**Why this works:**
- Free tier is genuinely complete and useful — not crippled
- Pro tier monetizes cloud infrastructure cost (API relay) and convenience (scheduled scans)
- Open source core builds trust and community contributions
- No feature gating that makes the free version feel broken
- Developer ICP who has their own API key gets 95% of value for free — Pro is for convenience

**Alternative:** Pure sponsorship / "buy me a coffee" model. Lower revenue ceiling but zero friction. Could start here and add Pro later if there's demand.

---

## 17. Open Questions

1. **LoRA training dataset** — how to efficiently curate (file_path, explanation, safety_rationale) tuples? Scrape Mole's source + Apple developer docs + community submissions?
2. **YAML rule versioning** — how to handle breaking changes to rule schema as the engine evolves? Semver on the rules repo?
3. **App Store** — ever worth pursuing, given the unsandboxed requirement? Or direct download + Homebrew Cask forever?
4. **Beta program** — invite-only dev beta via TestFlight, or public GitHub releases from day one?
5. **Community rules repo name** — `inceptyon/gargantua-rules` or `gargantua-app/rules`?
