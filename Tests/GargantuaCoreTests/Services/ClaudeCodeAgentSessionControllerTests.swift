import Foundation
import Testing
@testable import GargantuaCore

@Suite("ClaudeCodeAgentSessionController")
@MainActor
struct ClaudeCodeAgentSessionControllerTests {
    func waitForTerminalStatus(
        _ controller: ClaudeCodeAgentSessionController,
        timeout: TimeInterval = 2
    ) async -> ClaudeCodeAgentSessionStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.status.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return controller.status
    }

    func makeRunner(
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

    func makeDefaults() throws -> UserDefaults {
        let suite = "gargantua-agent-session-controller-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func makeExecutable(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-agent-session-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ControllerExecutorFailure: Error, LocalizedError {
    var errorDescription: String? { "executor exploded" }
}

final class ControllerFakeProcessExecutor: ClaudeCodeAgentProcessExecuting, @unchecked Sendable {
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
