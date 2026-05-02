import Foundation
import Testing
@testable import GargantuaCore

/// Trust-pass invariants. The agent UI promises users it shows the *exact*
/// text being sent to Claude — these tests pin that the strings the UI
/// renders are drawn from the same builder the runner uses, and that the
/// preset metadata stays in sync with the actual goal sentence.
@Suite("Agent prompt trust pass")
struct AgentPromptPreviewTests {

    @Test("Every preset's baseGoal appears verbatim in the rendered prompt")
    func everyPresetGoalAppearsInPrompt() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let prompt = ClaudeCodeAgentPromptBuilder.prompt(
                template: template,
                userContext: "stub user context"
            )
            #expect(
                prompt.contains(template.baseGoal),
                "Preset \(template.title) baseGoal must appear in the rendered prompt verbatim — otherwise the UI's 'Run details' preview would be lying about what gets sent."
            )
        }
    }

    @Test("User-typed context appears verbatim in the rendered prompt")
    func userContextAppearsInPrompt() {
        let unique = "Gargantua trust marker \(UUID().uuidString)"
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: unique
        )
        #expect(prompt.contains(unique))
    }

    @Test("Empty user context falls back to the placeholder so the preview is never blank")
    func emptyUserContextUsesPlaceholder() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let prompt = ClaudeCodeAgentPromptBuilder.prompt(template: template, userContext: "")
            #expect(
                prompt.contains(template.placeholder),
                "Empty context should be replaced by placeholder for \(template.title) so users see a real example"
            )
        }
    }

    @Test("Whitespace-only user context falls back to the placeholder")
    func whitespaceUserContextUsesPlaceholder() {
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: "   \n\t  "
        )
        #expect(prompt.contains(ClaudeCodeAgentPromptTemplate.investigateSpace.placeholder))
    }

    @Test("Title, summary, and placeholder are populated for every preset")
    func presetMetadataPresent() {
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            #expect(!template.title.isEmpty, "Preset \(template.rawValue) is missing a title")
            #expect(!template.summary.isEmpty, "Preset \(template.rawValue) is missing a summary")
            #expect(!template.placeholder.isEmpty, "Preset \(template.rawValue) is missing a placeholder")
            #expect(!template.baseGoal.isEmpty, "Preset \(template.rawValue) is missing a baseGoal")
        }
    }

    @Test("Tool allowlist surfaced to the UI matches what the runner forwards as --allowedTools")
    func toolAllowlistIsTheOneTheRunnerUses() {
        // The agent view's "Run details" disclosure renders this list. The
        // runner stitches the same constant into the --allowedTools flag in
        // makeLaunchPlan — keeping them as a single source-of-truth array
        // means the trust preview can't drift from reality.
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__scan"))
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__analyze"))
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__explain"))
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__list_profiles"))
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__status"))
        // `clean` is now part of the always-on allowlist for interactive
        // sessions: the agent uses dry-run-propose to hand items to the host
        // review modal. The destructiveTool constant remains so the
        // scheduled-audit override can still force it into --disallowedTools.
        #expect(ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.contains("mcp__gargantua__clean"))
        #expect(ClaudeCodeAgentPromptBuilder.destructiveTool == "mcp__gargantua__clean")
    }

    @Test("Renamed action-oriented titles are stable so the segmented picker doesn't regress")
    func renamedTitles() {
        // Pin the user-facing labels because they're shipped UI copy. The
        // raw enum values stay (investigateSpace/projectArchaeology/
        // customCleanupScript) so persisted picker state is unaffected.
        #expect(ClaudeCodeAgentPromptTemplate.investigateSpace.title == "Audit Disk Space")
        #expect(ClaudeCodeAgentPromptTemplate.projectArchaeology.title == "Find Stale Dev Projects")
        #expect(ClaudeCodeAgentPromptTemplate.customCleanupScript.title == "Generate Cleanup Script")
    }

    @Test("Prompt forbids shell output redirection so Claude doesn't hit the Bash sandbox")
    func promptForbidsShellRedirection() {
        // Claude Code's Bash sandbox blocks all write redirects regardless of
        // path. Without this rule, Claude reaches for `... > scan.tsv` to
        // organize MCP scan output and the run breaks mid-execution.
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let prompt = ClaudeCodeAgentPromptBuilder.prompt(template: template, userContext: "x")
            #expect(prompt.contains("Do not use shell output redirection"))
        }
    }

    @Test("Prompt instructs the agent to end with a dry-run mcp__gargantua__clean call so the run is actionable")
    func promptRequiresDryRunCleanHandoff() {
        // The agent's deliverable is a structured handoff to Deep Scan's
        // review modal, not a free-form report. The host's gate detector
        // raises the modal only when the agent calls `mcp__gargantua__clean`
        // — without this instruction the agent emits prose and the user
        // never sees an actionable cleanup.
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let prompt = ClaudeCodeAgentPromptBuilder.prompt(template: template, userContext: "x")
            #expect(prompt.contains("mcp__gargantua__clean"))
            #expect(prompt.contains("dry_run: true"))
            #expect(prompt.contains("item_ids"))
        }
    }

    @Test("Prompt directs a turn-frugal flow so the agent doesn't burn through max_turns calling every tool")
    func promptDrivesTurnFrugalFlow() {
        // Regression: prior phrasing read as an ordered checklist
        // ('Start with read-only MCP tools: list_profiles, status, analyze,
        // scan, and explain') and the agent dutifully called each one before
        // doing real work — runs hit the 12-turn ceiling without ever
        // proposing items. The new prompt names the default 3-turn flow
        // (scan → reason → dry-run clean) and tags the other tools as
        // escape hatches, plus tells the agent the scan output already
        // includes per-item explanations.
        for template in ClaudeCodeAgentPromptTemplate.allCases {
            let prompt = ClaudeCodeAgentPromptBuilder.prompt(template: template, userContext: "x")
            #expect(prompt.contains("turn-frugal"))
            #expect(prompt.contains("escape hatches"))
            #expect(prompt.contains("you do NOT need to call `mcp__gargantua__explain`"))
        }
    }
}
