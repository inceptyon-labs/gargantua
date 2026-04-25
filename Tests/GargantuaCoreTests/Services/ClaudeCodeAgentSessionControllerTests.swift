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
