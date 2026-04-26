import Foundation
import Testing
@testable import GargantuaCore

@Suite("FoundationClaudeCodeProcessExecutor")
struct ClaudeCodeAgentProcessExecutorTests {

    // MARK: - Helpers

    // Synchronized output collection — readabilityHandler fires on a GCD
    // thread that may outlive the `await start()` return, so plain `var`
    // is not safe here.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [ClaudeCodeProcessOutput] = []

        var onOutput: @Sendable (ClaudeCodeProcessOutput) -> Void {
            { [weak self] item in
                self?.lock.withLock { self?._items.append(item) }
            }
        }

        var stdout: String {
            lock.withLock {
                _items.compactMap { if case .stdout(let s) = $0 { return s } else { return nil } }.joined()
            }
        }

        var stderr: String {
            lock.withLock {
                _items.compactMap { if case .stderr(let s) = $0 { return s } else { return nil } }.joined()
            }
        }
    }

    // MARK: - Basic execution

    @Test("start captures stdout from a shell echo")
    func capturesStdout() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let sink = OutputSink()

        let code = try await executor.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'hello executor'"],
            environment: [:],
            workingDirectory: nil,
            onOutput: sink.onOutput
        )

        #expect(code == 0)
        #expect(sink.stdout.contains("hello executor"))
    }

    @Test("start captures stderr from a shell redirect")
    func capturesStderr() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let sink = OutputSink()

        let code = try await executor.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo error_msg 1>&2"],
            environment: [:],
            workingDirectory: nil,
            onOutput: sink.onOutput
        )

        #expect(code == 0)
        #expect(sink.stderr.contains("error_msg"))
    }

    @Test("start returns non-zero exit code from failing process")
    func nonZeroExitCode() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let code = try await executor.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 42"],
            environment: [:],
            workingDirectory: nil,
            onOutput: { _ in }
        )
        #expect(code == 42)
    }

    @Test("start merges custom environment variables into child environment")
    func mergesEnvironment() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let sink = OutputSink()

        _ = try await executor.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo \"val=$CUSTOM_VAR\""],
            environment: ["CUSTOM_VAR": "injected"],
            workingDirectory: nil,
            onOutput: sink.onOutput
        )

        #expect(sink.stdout.contains("injected"))
    }

    @Test("start respects working directory override")
    func respectsWorkingDirectory() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let sink = OutputSink()

        _ = try await executor.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pwd"],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            onOutput: sink.onOutput
        )

        // /tmp on macOS resolves to /private/tmp via symlink.
        #expect(sink.stdout.contains("tmp"))
    }

    // MARK: - Cancellation

    @Test("cancel terminates a long-running process")
    func cancelTerminatesProcess() async throws {
        let executor = FoundationClaudeCodeProcessExecutor()
        let sink = OutputSink()
        let startedSemaphore = DispatchSemaphore(value: 0)

        let task = Task {
            try await executor.start(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo started; sleep 30"],
                environment: [:],
                workingDirectory: nil,
                onOutput: { output in
                    sink.onOutput(output)
                    if case .stdout = output { startedSemaphore.signal() }
                }
            )
        }

        startedSemaphore.wait()
        executor.cancel()
        _ = await task.result
        #expect(sink.stdout.contains("started"))
    }

    @Test("cancel is a no-op when no process is running")
    func cancelNoop() {
        let executor = FoundationClaudeCodeProcessExecutor()
        executor.cancel()
    }

    // MARK: - Error handling

    @Test("start throws when executable path does not exist")
    func throwsForMissingExecutable() async {
        let executor = FoundationClaudeCodeProcessExecutor()
        await #expect(throws: (any Error).self) {
            _ = try await executor.start(
                executable: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: [],
                environment: [:],
                workingDirectory: nil,
                onOutput: { _ in }
            )
        }
    }
}
