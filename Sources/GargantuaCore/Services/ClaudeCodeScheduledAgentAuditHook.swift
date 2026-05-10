import Foundation
import OSLog

private let scheduledHookLogger = Logger(subsystem: "com.gargantua.core", category: "ClaudeCodeAgentRunner")

/// Hook that can run follow-up agent work after scheduled scans.
public protocol ScheduledScanAgentAuditHook: Sendable {
    func run(summary: ScheduledScanSummary) async
}

/// Scheduled scan audit hook that performs no work.
public struct NoopScheduledScanAgentAuditHook: ScheduledScanAgentAuditHook {
    /// Creates a no-op scheduled scan audit hook.
    public init() {}
    /// Ignores the scheduled scan summary.
    public func run(summary: ScheduledScanSummary) async {}
}

/// Runs a read-only Claude Code audit after scheduled scans when enabled.
public struct ClaudeCodeScheduledAgentAuditHook: ScheduledScanAgentAuditHook {
    private let configurationStore: ClaudeCodeAgentConfigurationStore
    private let runner: ClaudeCodeAgentSessionRunner

    /// Creates an audit hook with optional runner injection.
    public init(
        configurationStore: ClaudeCodeAgentConfigurationStore = ClaudeCodeAgentConfigurationStore(),
        runner: ClaudeCodeAgentSessionRunner? = nil
    ) {
        self.configurationStore = configurationStore
        self.runner = runner ?? ClaudeCodeAgentSessionRunner(configurationStore: configurationStore)
    }

    /// Runs the scheduled-scan prompt when the Claude Code integration allows it.
    public func run(summary: ScheduledScanSummary) async {
        let configuration = configurationStore.load()
        guard configuration.isEnabled, configuration.runAfterScheduledScans else { return }

        let prompt = ClaudeCodeAgentPromptBuilder.scheduledAuditPrompt(summary: summary)
        do {
            _ = try await runner.run(
                prompt: prompt,
                allowDestructiveMCPToolsOverride: false,
                onEvent: { _ in },
                onGate: { _ in }
            )
        } catch {
            scheduledHookLogger.warning("Scheduled Claude Code audit hook failed: \(error.localizedDescription)")
        }
    }
}
