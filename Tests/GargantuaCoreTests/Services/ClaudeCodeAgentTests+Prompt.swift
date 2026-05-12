import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentTests {
    @Test("Prompt builder pins MCP and safety-floor instructions")
    func promptBuilderPinsSafetyInstructions() {
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: "Find stale Docker and Xcode artifacts."
        )

        #expect(prompt.contains("Gargantua MCP server"))
        #expect(prompt.contains("Never delete"))
        #expect(prompt.contains("Protected items are not eligible"))
        #expect(prompt.contains("Find stale Docker and Xcode artifacts."))
        // The dry-run-propose handoff is the actionable edge of the prompt:
        // without it the agent emits prose, never calls clean, and the user
        // never sees a review modal. Pin both the tool name and the dry_run
        // requirement so accidental copy edits can't quietly regress this.
        #expect(prompt.contains("mcp__gargantua__clean"))
        #expect(prompt.contains("dry_run: true"))
        #expect(prompt.contains("item_ids"))
    }

    @Test("Prompt forbids non-dry-run clean calls so the host modal stays the only deletion path")
    func promptBuilderForbidsNonDryRunClean() {
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: ""
        )
        #expect(prompt.contains("Never call `mcp__gargantua__clean` without `dry_run: true`"))
    }

    @Test("Scheduled audit prompt includes scan summary and forbids automatic cleanup")
    func scheduledAuditPromptIncludesSummary() {
        let summary = ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 200_000),
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 42_000
        )

        let prompt = ClaudeCodeAgentPromptBuilder.scheduledAuditPrompt(summary: summary)

        #expect(prompt.contains("Scheduled scan completed"))
        #expect(prompt.contains("Profile: light"))
        #expect(prompt.contains("Actionable items: 3"))
        #expect(prompt.contains("Do not clean anything automatically"))
    }
}
