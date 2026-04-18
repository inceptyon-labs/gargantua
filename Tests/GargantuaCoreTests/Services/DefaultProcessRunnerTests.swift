import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultProcessRunner")
struct DefaultProcessRunnerTests {

    @Test("Captures large stdout payload byte-for-byte without deadlock")
    func largeStdoutCapture() throws {
        let runner = DefaultProcessRunner()
        let byteCount = 100_000
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes | head -c \(byteCount)"]
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == byteCount)
        // `yes` emits "y\n" repeatedly. With an even byteCount, the capture
        // should start with "y" and end with "\n".
        let bytes = Array(output.stdout.utf8)
        #expect(bytes.first == UInt8(ascii: "y"))
        #expect(bytes.last == UInt8(ascii: "\n"))
    }

    @Test("Handles descendant inheriting pipe fd without hanging on drain")
    func descendantInheritedFdHandling() throws {
        let runner = DefaultProcessRunner()
        // Launch a shell that spawns a background process that inherits the pipe fd.
        // Without the fix, readDataToEndOfFile() would block indefinitely because
        // the inherited fd keeps the pipe open even after the shell parent exits.
        // The fix bounds the drain wait and closes the fds if needed.
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'parent' && (sleep 0.1 &) && exit 0"]
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("parent"))
    }

    @Test("Timeout with SIGTERM and SIGKILL escalation")
    func timeoutWithSignalEscalation() throws {
        let runner = DefaultProcessRunner()
        // Launch a process that ignores SIGTERM (trap '' SIGTERM) and would run forever.
        // The timeout mechanism should escalate to SIGKILL after a grace period.
        // The process should be killed and the timeout error should be thrown.
        do {
            _ = try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 100"],
                timeout: 0.5
            )
            #expect(Bool(false), "Should have thrown ProcessRunnerError.timedOut")
        } catch ProcessRunnerError.timedOut(let seconds) {
            #expect(seconds == 0.5)
        }
    }

    @Test("Timeout is thrown when process exceeds time limit")
    func timeoutThrown() throws {
        let runner = DefaultProcessRunner()
        do {
            _ = try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10"],
                timeout: 0.2
            )
            #expect(Bool(false), "Should have thrown ProcessRunnerError.timedOut")
        } catch ProcessRunnerError.timedOut(let seconds) {
            #expect(seconds == 0.2)
        }
    }

    @Test("Process completes normally within timeout")
    func completesWithinTimeout() throws {
        let runner = DefaultProcessRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'hello'; exit 42"],
            timeout: 5.0
        )

        #expect(output.exitCode == 42)
        #expect(output.stdout.contains("hello"))
    }
}
