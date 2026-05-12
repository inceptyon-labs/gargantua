// swiftlint:disable line_length
// Test fixtures embed real Claude Code JSONL stream records inline as
// raw strings. Each record is one logical JSON line by spec; breaking
// them across source lines would corrupt the assertion data.

import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentSessionControllerTests {
    @Test("runner setup errors move the lifecycle to failed and append a system event")
    func setupErrorMovesLifecycleToFailed() async throws {
        let runner = try makeRunner(configuration: ClaudeCodeAgentConfiguration(isEnabled: false))
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "scan")
        let status = await waitForTerminalStatus(controller)

        #expect(status == .failed(ClaudeCodeAgentError.disabled.localizedDescription))
        #expect(controller.events.contains {
            $0.stream == .system && $0.message == ClaudeCodeAgentError.disabled.localizedDescription
        })
    }

    @Test("process executor errors move the lifecycle to failed and surface the error")
    func executorErrorMovesLifecycleToFailed() async throws {
        let runner = try makeRunner(
            executor: ControllerFakeProcessExecutor(error: ControllerExecutorFailure())
        )
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "scan")
        let status = await waitForTerminalStatus(controller)

        #expect(status == .failed("executor exploded"))
        #expect(controller.events.contains {
            $0.stream == .system && $0.message == "executor exploded"
        })
    }

    @Test("Fallback does not fire on a failed run — partial results shouldn't push a modal")
    func sessionEndFallbackSkipsOnFailure() async throws {
        let scanResultLine = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_scan_fb3","type":"tool_result","content":"summary"}]},"tool_use_result":{"content":"summary","structuredContent":{"items":[{"id":"chrome_cache-1","name":"Chrome","path":"/tmp/chrome-cache","size":"1.2 KB","safety":"safe","confidence":90,"explanation":"cache","source":"Chrome","category":"browser_cache"}],"summary":{"safe_count":1,"safe_size":"1.2 KB","review_count":0,"review_size":"0 bytes","protected_count":0},"total_reclaimable":"1.2 KB"}}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(
            outputs: [.stdout(scanResultLine + "\n")],
            exitCode: 7
        ))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "audit")
        _ = await waitForTerminalStatus(controller)

        if case .failed = controller.status {} else {
            Issue.record("expected status to be .failed; got \(controller.status)")
        }
        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.isEmpty)
    }

    @Test("non-zero process exits move the lifecycle to failed and keep detected approval gates")
    func nonzeroExitMovesLifecycleToFailed() async throws {
        // Wrapped assistant event so the structured parser raises a gate —
        // the substring fallback no longer exists.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_failure","name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"],"method":"trash","confirm":true,"dry_run":true}}]}}
        """#
        let runner = try makeRunner(
            executor: ControllerFakeProcessExecutor(
                outputs: [
                    .stdout(cleanLine + "\n")
                ],
                exitCode: 42
            )
        )
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "scan")
        let status = await waitForTerminalStatus(controller)

        #expect(status == .failed("Claude Code exited with status 42."))
        #expect(controller.approvalGates.count == 1)
        #expect(controller.approvalGates[0].status == .pending)
        #expect(controller.approvalGates[0].proposedItemIDs == ["safe-1"])
    }
}
// swiftlint:enable line_length
