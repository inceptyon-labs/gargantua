import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultProcessRunner integration")
struct DefaultProcessRunnerIntegrationTests {

    @Test("/bin/sleep with short timeout throws timedOut")
    func sleepTimesOut() throws {
        let runner = DefaultProcessRunner()
        do {
            _ = try runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.2
            )
            #expect(Bool(false), "Expected ProcessRunnerError.timedOut")
        } catch ProcessRunnerError.timedOut(let seconds) {
            #expect(seconds == 0.2)
        }
    }

    @Test("/bin/echo with no timeout captures stdout exactly")
    func echoCapturesStdout() throws {
        let runner = DefaultProcessRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout == "hello\n")
    }

    @Test("/bin/sh -c 'exit 7' surfaces exit code")
    func exitCodePropagates() throws {
        let runner = DefaultProcessRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"]
        )

        #expect(output.exitCode == 7)
    }

    @Test("Large stdout payload drains without deadlock")
    func largePayloadFullyCaptured() throws {
        let runner = DefaultProcessRunner()
        let byteCount = 100_000
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes | head -c \(byteCount)"]
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == byteCount)
    }

    @Test("Cancelling the calling task kills a child the runner is waiting on")
    func cancellationKillsChild() async throws {
        let runner = DefaultProcessRunner()
        let task = Task {
            try await ProcessCancellation.run {
                try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: nil)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        // Timed from the cancel, not the test's start: CI runners can take
        // several seconds to get a parallel test run going.
        let cancelled = Date()
        task.cancel()

        let output = try await task.value

        #expect(output.exitCode == SIGKILL)
        #expect(Date().timeIntervalSince(cancelled) < 20)
    }
}
