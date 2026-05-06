import Foundation
import Testing
@testable import GargantuaCore

@Suite("CleanupEngine command-action routing")
struct CleanupEngineCommandActionTests {
    private final class StubExecutor: CommandActionExecuting, @unchecked Sendable {
        var executedRules: [String] = []
        var nextResultExitCode: Int32 = 0
        var shouldThrow: CommandActionExecutionError?
        let lock = NSLock()

        func preview(_ rule: CommandActionRule) throws -> CommandActionPreview {
            CommandActionPreview(
                rule: rule,
                effectiveSafety: .review,
                estimatedBytes: nil,
                toolVersion: "stub-1.0",
                dryRunOutput: nil
            )
        }

        func execute(
            _ rule: CommandActionRule,
            preview: CommandActionPreview,
            confirmationMethod: ConfirmationTier
        ) throws -> CommandActionExecutionResult {
            if let shouldThrow { throw shouldThrow }
            lock.lock()
            executedRules.append(rule.id)
            lock.unlock()
            return CommandActionExecutionResult(
                rule: rule,
                commandPreview: [rule.tool] + rule.arguments,
                output: ProcessOutput(stdout: "", stderr: "", exitCode: nextResultExitCode),
                estimatedBytesFreed: 0,
                toolVersion: "stub-1.0"
            )
        }
    }

    private func sampleRule() -> CommandActionRule {
        CommandActionRule(
            id: "sample",
            name: "Sample",
            tool: "pnpm",
            arguments: ["store", "prune"],
            safety: .safe,
            confidence: 90,
            explanation: "Sample command rule for engine routing.",
            category: "developer_tool_command",
            affectedRoots: ["~/Library/test"],
            source: SourceAttribution(name: "pnpm")
        )
    }

    private func commandScanResult(ruleID: String = "sample") -> ScanResult {
        ScanResult(
            id: "command-action:" + ruleID,
            name: "Sample",
            path: "pnpm store prune",
            size: 0,
            safety: .review,
            confidence: 90,
            explanation: "Sample command rule.",
            source: SourceAttribution(name: "pnpm"),
            category: "developer_tool_command",
            tags: ["command-action", "command-action:unknown-bytes"]
        )
    }

    @Test("Command-action items are routed through the executor and not the trash mover")
    @MainActor
    func routesViaExecutor() async {
        let stub = StubExecutor()
        let router = CommandActionCleanupRouter(rules: [sampleRule()], executor: stub)
        let engine = CleanupEngine(
            homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser,
            commandActionRunner: router
        )

        let result = await engine.clean([commandScanResult()], method: .trash)
        #expect(result.allSucceeded)
        #expect(stub.executedRules == ["sample"])
    }

    @Test("Executor failure surfaces as a per-item error without aborting the batch")
    @MainActor
    func executorFailureProducesItemError() async {
        let stub = StubExecutor()
        stub.shouldThrow = .commandFailed(ruleID: "sample", exitCode: 1, stderr: "boom")
        let router = CommandActionCleanupRouter(rules: [sampleRule()], executor: stub)
        let engine = CleanupEngine(
            homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser,
            commandActionRunner: router
        )
        let result = await engine.clean([commandScanResult()], method: .trash)
        #expect(!result.allSucceeded)
        let item = result.itemResults.first
        #expect(item?.error?.contains("boom") == true)
    }

    @Test("Unknown rule ID surfaces as a clear per-item error")
    @MainActor
    func unknownRuleProducesItemError() async {
        let router = CommandActionCleanupRouter(rules: [], executor: StubExecutor())
        let engine = CleanupEngine(
            homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser,
            commandActionRunner: router
        )
        let result = await engine.clean([commandScanResult(ruleID: "ghost")], method: .trash)
        #expect(!result.allSucceeded)
        #expect(result.itemResults.first?.error?.contains("ghost") == true)
    }
}
