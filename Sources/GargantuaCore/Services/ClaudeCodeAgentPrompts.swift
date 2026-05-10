import Foundation

/// Built-in agent prompt templates surfaced in the UI.
public enum ClaudeCodeAgentPromptTemplate: String, CaseIterable, Identifiable, Sendable {
    /// Investigate disk-space usage and propose safe cleanup.
    case investigateSpace
    /// Inspect a development directory for stale projects and artifacts.
    case projectArchaeology
    /// Generate a reviewable maintenance script.
    case customCleanupScript

    /// Stable identifier used by SwiftUI lists and pickers.
    public var id: String { rawValue }

    /// Short user-facing template name. Action-oriented so the label alone
    /// telegraphs what artifact comes back ("an audit", "a script", etc.).
    /// The raw enum values are kept stable so persisted selections don't
    /// silently flip when the labels change.
    public var title: String {
        switch self {
        case .investigateSpace: "Audit Disk Space"
        case .projectArchaeology: "Find Stale Dev Projects"
        case .customCleanupScript: "Generate Cleanup Script"
        }
    }

    /// SF Symbol used for the template icon.
    public var icon: String {
        switch self {
        case .investigateSpace: "magnifyingglass.circle"
        case .projectArchaeology: "folder.badge.questionmark"
        case .customCleanupScript: "terminal"
        }
    }

    /// One-line description shown directly under the picker so users know
    /// what the preset will actually do without having to expand the full
    /// prompt preview.
    public var summary: String {
        switch self {
        case .investigateSpace:
            "Reviews the whole Mac via the read-only MCP scan/analyze tools and returns an evidence-backed cleanup report. Nothing is deleted."
        case .projectArchaeology:
            "Looks at a development directory you specify, flagging stale repos, build artifacts, "
                + "and archive candidates. Produces a written report; no files are touched."
        case .customCleanupScript:
            "Produces a reviewable shell script with every command annotated. The script is shown for review only — the agent never runs it."
        }
    }

    /// Placeholder user context shown in the prompt input field.
    public var placeholder: String {
        switch self {
        case .investigateSpace:
            "Find the biggest safe cleanup opportunities on this Mac."
        case .projectArchaeology:
            "Inspect ~/Development/example-project and identify old repos or artifacts I can archive."
        case .customCleanupScript:
            "Generate a reviewable maintenance script for stale build artifacts."
        }
    }

    /// The "Goal:" sentence that gets stamped into the prompt builder. Made
    /// non-fileprivate so the trust-pass UI can render the same string the
    /// builder uses, and tests can pin them in lockstep.
    public var baseGoal: String {
        switch self {
        case .investigateSpace:
            "Investigate what is taking disk space and produce an evidence-backed cleanup report."
        case .projectArchaeology:
            "Perform project archaeology: identify stale repositories, generated artifacts, and low-risk archive candidates."
        case .customCleanupScript:
            "Generate a custom cleanup script proposal. Do not run it; produce the script and explain every command."
        }
    }
}

/// Builds the text prompts handed to the Claude Code agent process.
public enum ClaudeCodeAgentPromptBuilder {
    /// MCP tools the agent may invoke without an explicit user approval.
    /// `clean` is included because the agent uses it in **dry-run mode** to
    /// propose a cleanup set — that call short-circuits server-side before any
    /// deletion (`MCPCleanToolHandler` early-returns on `dry_run: true`) and
    /// raises a host-side gate that surfaces `ConfirmationModalView`. The
    /// actual deletion runs in the host through `CleanupEngine` after the user
    /// clicks Clean in that modal — same pipeline Deep Scan uses.
    public static let readOnlyToolAllowlist = [
        "mcp__gargantua__scan",
        "mcp__gargantua__analyze",
        "mcp__gargantua__status",
        "mcp__gargantua__explain",
        "mcp__gargantua__list_profiles",
        "mcp__gargantua__clean",
    ]

    /// Destructive MCP tool name. Kept as a named constant so the runner's
    /// scheduled-audit override can still force it into `--disallowedTools`
    /// when no user is present to review proposals (unattended runs must stay
    /// strictly read-only).
    public static let destructiveTool = "mcp__gargantua__clean"

    /// Builds an agent prompt for a template and trimmed user-supplied context.
    public static func prompt(
        template: ClaudeCodeAgentPromptTemplate,
        userContext: String
    ) -> String {
        let trimmedContext = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = trimmedContext.isEmpty ? template.placeholder : trimmedContext
        // swiftlint:disable line_length
        // Agent system prompt — line breaks would change the prompt's
        // meaning, so the heredoc lines stay as written.
        return """
        You are running inside Gargantua's Tier 3 Claude Code agent mode.

        Goal:
        \(template.baseGoal)

        User context:
        \(context)

        Tool plan (be turn-frugal — every tool call costs a turn and real money):
        - The default flow is exactly three turns: (1) one `mcp__gargantua__scan` call, (2) one prose summary turn that reasons over the scan output, (3) one `mcp__gargantua__clean` call with `dry_run: true` to propose the items. Aim for this; do not call extra tools by reflex.
        - `mcp__gargantua__scan` is the primary discovery tool. Its output already includes per-item `explanation`, `safety`, `confidence`, `size`, `category`, and `source` — you do NOT need to call `mcp__gargantua__explain` for items the scan returned. Only call `explain` if a specific item lacks the context you need to decide.
        - `mcp__gargantua__list_profiles`, `mcp__gargantua__status`, and `mcp__gargantua__analyze` are escape hatches, not default steps. Skip them unless the user's question can't be answered from a single scan.
        - One scan is usually enough. Do not run additional scans with different profiles unless the user's question explicitly asks you to compare profiles or the first scan returned nothing useful.
        - Scan results are capped: the wire payload returns at most the top 100 items by size, and the per-item `explanation` is trimmed to ~240 characters. The `summary` field reflects the FULL counts so you can tell when items were trimmed — if you need detail on a specific large item that came back trimmed, call `mcp__gargantua__explain` with its `item_id`. Do not retry the same scan hoping for more items.

        Safety rules:
        - Use only the Gargantua MCP server named "gargantua" for cleanup discovery and cleanup proposals.
        - Never delete, move, overwrite, chmod, chown, or edit files directly through shell commands.
        - Never lower or reinterpret Gargantua safety classifications. Protected items are not eligible for cleanup.
        - Prefer Trash over permanent delete.

        Output rules — IMPORTANT, READ CAREFULLY:
        - Your output is NOT a written report. The user does not want a markdown summary. Gargantua wires the agent's `mcp__gargantua__clean` tool call directly into the same review modal Deep Scan uses, with checkboxes and a Clean button — that modal IS the deliverable. Without the clean call, the run produced nothing actionable for the user.
        - You MUST end every run that returned scan items with a single call to `mcp__gargantua__clean` carrying `dry_run: true`, `confirm: true`, and `item_ids` listing every safe/review ID from the scan. This call does not delete anything — it is a propose-only handoff into the review modal, and the user is the one who clicks Clean. Do not "decide" not to call clean because some items "feel risky" — propose them; the modal's per-item review is exactly the place to triage that.
        - The only acceptable run that ends without a clean call is one where the scan returned ZERO items in safety='safe' or safety='review' tiers. Any other shape MUST end with the clean call. "I'd rather give a written summary" is not a valid reason to skip it.
        - Always pass `dry_run: true`. The MCP clean tool will short-circuit and return a plan; the host will run the actual deletion through its own pipeline only after the user confirms in the modal. Never call `mcp__gargantua__clean` without `dry_run: true`.
        - Use only `item_ids` returned by a prior `mcp__gargantua__scan` call. Do not invent IDs or pass app-bundle paths. If a recommendation isn't covered by a scan ID (e.g. an installed app), describe it briefly in prose and direct the user to Smart Uninstaller — do NOT include it in the clean tool call.
        - Keep prose minimal — one or two sentences naming the categories you're proposing. The modal is the report. Do not create files. Do not use shell output redirection (>, >>, tee, /dev/stdout to file) — Claude Code's sandbox blocks these and the redirected data is lost.
        """
        // swiftlint:enable line_length
    }

    /// Builds a post-scheduled-scan audit prompt using the supplied scan summary.
    /// Scheduled audits run unattended, so the runner forces `clean` into
    /// `--disallowedTools` for these sessions and the prompt must stay
    /// prose-only.
    public static func scheduledAuditPrompt(summary: ScheduledScanSummary) -> String {
        // swiftlint:disable line_length
        // Agent system prompt — see comment in defaultPrompt(template:userContext:).
        let context = """
        Scheduled scan completed at \(summary.date.formatted(date: .abbreviated, time: .shortened)).
        Profile: \(summary.profileID)
        Actionable items: \(summary.itemCount)
        Reclaimable bytes: \(summary.reclaimableBytes)
        Produce a maintenance audit report. Do not clean anything automatically.
        """
        return """
        You are running inside Gargantua's Tier 3 Claude Code agent mode (scheduled-audit hook).

        Goal:
        \(ClaudeCodeAgentPromptTemplate.investigateSpace.baseGoal)

        User context:
        \(context)

        Safety rules:
        - Use only the Gargantua MCP server named "gargantua" for cleanup discovery.
        - Use only read-only MCP tools: list_profiles, status, analyze, scan, and explain.
        - The MCP clean tool is disabled for scheduled audits. Do not attempt to call it.
        - Never delete, move, overwrite, chmod, chown, or edit files directly through shell commands.
        - Never lower or reinterpret Gargantua safety classifications. Protected items are not eligible for cleanup.
        - Prefer Trash over permanent delete.

        Output rules:
        - Your deliverable is the conversation. Do not create files as your output.
        - Do not use shell output redirection (>, >>, tee, /dev/stdout to file) — Claude Code's sandbox blocks these and the redirected data is lost. Hold scan results in memory and report findings inline as text.
        - Return a concise transcript-ready maintenance audit report with evidence, proposed actions, and any skipped risky items.
        """
        // swiftlint:enable line_length
    }
}
