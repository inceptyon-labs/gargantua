import Foundation
import Testing
@testable import GargantuaCore

@Suite("ClaudeCodeAgentSessionController")
@MainActor
struct ClaudeCodeAgentSessionControllerTests {

    @Test("Initial state is idle with empty events, gates, and no active session")
    func initialState() {
        let controller = ClaudeCodeAgentSessionController()
        #expect(controller.status == .idle)
        #expect(controller.events.isEmpty)
        #expect(controller.approvalGates.isEmpty)
        #expect(controller.activeSessionID == nil)
    }

    @Test("cancel() while idle is a no-op — status remains idle")
    func cancelWhileIdleIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        controller.cancel()
        #expect(controller.status == .idle)
        #expect(controller.activeSessionID == nil)
    }

    @Test("approve() with no matching gate is a no-op — gate list stays empty")
    func approveOnEmptyGatesIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        let stranger = ClaudeCodeAgentApprovalGate(
            sessionID: UUID(),
            summary: "stranger gate",
            rawTranscript: ""
        )
        controller.approve(stranger)
        #expect(controller.approvalGates.isEmpty)
    }

    @Test("deny() with no matching gate is a no-op — gate list stays empty")
    func denyOnEmptyGatesIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        let stranger = ClaudeCodeAgentApprovalGate(
            sessionID: UUID(),
            summary: "stranger gate",
            rawTranscript: ""
        )
        controller.deny(stranger)
        #expect(controller.approvalGates.isEmpty)
    }

    @Test("ClaudeCodeAgentSessionStatus.isRunning is true only for .running")
    func sessionStatusIsRunningSemantics() {
        #expect(ClaudeCodeAgentSessionStatus.idle.isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.running.isRunning == true)
        #expect(ClaudeCodeAgentSessionStatus.completed.isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.failed("err").isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.cancelled.isRunning == false)
    }

    @Test("ClaudeCodeAgentSessionStatus.label is human-readable for each case")
    func sessionStatusLabels() {
        #expect(ClaudeCodeAgentSessionStatus.idle.label == "Ready")
        #expect(ClaudeCodeAgentSessionStatus.running.label == "Running")
        #expect(ClaudeCodeAgentSessionStatus.completed.label == "Completed")
        #expect(ClaudeCodeAgentSessionStatus.failed("x").label == "Failed")
        #expect(ClaudeCodeAgentSessionStatus.cancelled.label == "Cancelled")
    }

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

    @Test("approve() on a substring-fallback gate (no proposed IDs) falls back to status flip — no modal is presented")
    func approveWithoutProposedIDsFallsBackToStatusFlip() async throws {
        // Substring-only line — the parser doesn't extract item_ids, so the
        // detector raises a gate with proposedItemIDs == [].
        let substringLine = #"{"name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"]}}"#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(substringLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        #expect(gate.proposedItemIDs == [])

        controller.approve(gate)

        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.first?.status == .approved)
    }

    @Test("approve() with proposedItemIDs but empty scan cache falls back to status flip — no items to hydrate")
    func approveWithProposedIDsButEmptyCacheFallsBack() async throws {
        // Stream-json clean call without a preceding scan tool_result.
        // Detector parses item_ids onto the gate; controller's host cache
        // is empty so lookupAll resolves nothing.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_empty","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-1"],"method":"trash","confirm":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(cleanLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        #expect(gate.proposedItemIDs == ["chrome_cache-1"])

        controller.approve(gate)

        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.first?.status == .approved)
    }

    @Test("stream-json scan tool_result populates the host cache; approve() then hydrates matching IDs into pendingApproval")
    func approveHydratesItemsAfterScanStreamEvent() async throws {
        // Two stream-json lines: first a scan tool_result the controller
        // mirrors into its cache, then a clean tool_use whose item_ids
        // overlap. After session ends, approve(_:) on the captured gate
        // should hydrate items[0] from the cache.
        let scanResultLine = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_scan_xaad","type":"tool_result","content":"summary text"}]},"tool_use_result":{"content":"summary text","structuredContent":{"items":[{"id":"chrome_cache-1","name":"Chrome","path":"/tmp/chrome-cache","size":"1.2 KB","safety":"safe","confidence":90,"explanation":"cache","source":"Chrome","category":"browser_cache"},{"id":"npm_cache-2","name":"npm","path":"/tmp/npm-cache","size":"500 bytes","safety":"safe","confidence":85,"explanation":"npm cache","source":"npm","category":"dev_artifacts"}],"summary":{"safe_count":2,"safe_size":"1.7 KB","review_count":0,"review_size":"0 bytes","protected_count":0},"total_reclaimable":"1.7 KB"}}}
        """#
        let cleanCallLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_xaad","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-1","unknown-99"],"method":"trash","confirm":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(scanResultLine + "\n"),
            .stdout(cleanCallLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        #expect(gate.proposedItemIDs == ["chrome_cache-1", "unknown-99"])

        controller.approve(gate)

        let pending = try #require(controller.pendingApproval)
        #expect(pending.gateID == gate.id)
        #expect(pending.items.count == 1)
        #expect(pending.items.first?.id == "chrome_cache-1")
        #expect(pending.unresolvedItemIDs == ["unknown-99"])
        // Gate stays pending until the user confirms in the modal.
        #expect(controller.approvalGates.first?.status == .pending)

        // Verify cancel path tears it back down without touching the gate.
        controller.cancelPendingApproval()
        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.first?.status == .pending)
    }

    @Test("non-zero process exits move the lifecycle to failed and keep detected approval gates")
    func nonzeroExitMovesLifecycleToFailed() async throws {
        let runner = try makeRunner(
            executor: ControllerFakeProcessExecutor(
                outputs: [
                    .stdout(#"{"name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"]}}"# + "\n")
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
    }

    private func waitForTerminalStatus(
        _ controller: ClaudeCodeAgentSessionController,
        timeout: TimeInterval = 2
    ) async -> ClaudeCodeAgentSessionStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.status.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return controller.status
    }

    private func makeRunner(
        configuration: ClaudeCodeAgentConfiguration? = nil,
        executor: ControllerFakeProcessExecutor = ControllerFakeProcessExecutor()
    ) throws -> ClaudeCodeAgentSessionRunner {
        let defaults = try makeDefaults()
        let store = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        store.save(configuration ?? ClaudeCodeAgentConfiguration(
            isEnabled: true,
            cliPath: executable.path
        ))
        let tempDirectory = try makeTemporaryDirectory()
        return ClaudeCodeAgentSessionRunner(
            configurationStore: store,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            processExecutor: executor,
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "gargantua-agent-session-controller-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeExecutable(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-agent-session-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct ControllerExecutorFailure: Error, LocalizedError {
    var errorDescription: String? { "executor exploded" }
}

private final class ControllerFakeProcessExecutor: ClaudeCodeAgentProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let outputs: [ClaudeCodeProcessOutput]
    private let exitCode: Int32
    private let error: Error?
    private var didCancelStorage = false

    init(
        outputs: [ClaudeCodeProcessOutput] = [],
        exitCode: Int32 = 0,
        error: Error? = nil
    ) {
        self.outputs = outputs
        self.exitCode = exitCode
        self.error = error
    }

    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancelStorage
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        onOutput: @escaping @Sendable (ClaudeCodeProcessOutput) -> Void
    ) async throws -> Int32 {
        if let error {
            throw error
        }
        for output in outputs {
            onOutput(output)
        }
        return exitCode
    }

    func cancel() {
        lock.lock()
        didCancelStorage = true
        lock.unlock()
    }
}
