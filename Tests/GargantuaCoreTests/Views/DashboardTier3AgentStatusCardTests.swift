import Testing
@testable import GargantuaCore

@Suite("Dashboard Tier 3 agent status presentation")
struct DashboardTier3AgentStatusCardTests {
    @Test("disabled configuration presents off state")
    func disabledConfigurationPresentsOff() {
        let presentation = DashboardTier3AgentStatusPresentation.make(
            from: DashboardTier3AgentStatus(
                configuration: ClaudeCodeAgentConfiguration(isEnabled: false),
                cliAvailable: true,
                resolvedCLIPath: "/usr/local/bin/claude"
            )
        )

        #expect(presentation.title == "Off")
        #expect(presentation.tone == .muted)
        #expect(presentation.opensSettings)
    }

    @Test("enabled configuration without CLI needs attention")
    func enabledWithoutCLINeedsAttention() {
        let presentation = DashboardTier3AgentStatusPresentation.make(
            from: DashboardTier3AgentStatus(
                configuration: ClaudeCodeAgentConfiguration(isEnabled: true),
                cliAvailable: false,
                resolvedCLIPath: nil
            )
        )

        #expect(presentation.title == "Needs CLI")
        #expect(presentation.tone == .review)
        #expect(presentation.opensSettings)
    }

    @Test("enabled configuration with CLI presents ready agent action")
    func enabledWithCLIPresentsReady() {
        let presentation = DashboardTier3AgentStatusPresentation.make(
            from: DashboardTier3AgentStatus(
                configuration: ClaudeCodeAgentConfiguration(
                    isEnabled: true,
                    selectedModel: "claude-sonnet",
                    allowDestructiveMCPTools: false
                ),
                cliAvailable: true,
                resolvedCLIPath: "/usr/local/bin/claude"
            )
        )

        #expect(presentation.title == "Ready")
        #expect(presentation.tone == .safe)
        #expect(presentation.modelSummary == "claude-sonnet")
        #expect(presentation.modeSummary == "read-only tools")
        #expect(!presentation.opensSettings)
    }

    @Test("empty selected model falls back to CLI default copy")
    func emptySelectedModelUsesCLIDefault() {
        let presentation = DashboardTier3AgentStatusPresentation.make(
            from: DashboardTier3AgentStatus(
                configuration: ClaudeCodeAgentConfiguration(
                    isEnabled: true,
                    selectedModel: "",
                    allowDestructiveMCPTools: true
                ),
                cliAvailable: true,
                resolvedCLIPath: "/usr/local/bin/claude"
            )
        )

        #expect(presentation.modelSummary == "CLI default")
        #expect(presentation.modeSummary == "clean proposals")
    }
}
