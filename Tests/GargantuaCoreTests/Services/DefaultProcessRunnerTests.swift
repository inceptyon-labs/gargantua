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
        // Shell spawns a backgrounded `sleep` that inherits the pipe fd and
        // keeps it open well past the parent exit. With the bounded drain,
        // `run` must return promptly after the parent exits rather than waiting
        // on the inherited fd. The descendant sleep is long enough that a
        // blocking read would obviously hang past the assertion budget.
        let start = Date()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'parent' && (sleep 30 &) && exit 0"]
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("parent"))
        // Bounded drain defaults to 1s when no timeout is set; allow a generous
        // margin for CI scheduling jitter while still catching a real hang.
        #expect(elapsed < 5.0, "expected bounded drain, elapsed \(elapsed)s")
    }

    @Test("Timeout with SIGTERM and SIGKILL escalation")
    func timeoutWithSignalEscalation() throws {
        let runner = DefaultProcessRunner()
        // Process ignores SIGTERM and must be cleaned up by the SIGKILL
        // escalation path. A hard wall-clock budget catches a regression
        // where escalation fails and run() hangs forever.
        let start = Date()
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
        let elapsed = Date().timeIntervalSince(start)
        // timeout (0.5) + SIGKILL grace (0.5) + drain grace (≤1.0) + slack.
        #expect(elapsed < 5.0, "escalation path exceeded budget: \(elapsed)s")
    }

    @Test("Timeout cleans up descendant that ignores SIGTERM after leader exits")
    func timeoutCleansDescendantAfterLeaderExits() throws {
        let runner = DefaultProcessRunner()
        // Shell exits immediately after spawning a SIGTERM-trapping background
        // process that inherits the pipe fd. Without process-group escalation,
        // the leader's exit wouldn't help and the descendant would hold the
        // pipe, hanging the drain. With the fix, the timeout fires, SIGKILL
        // cleans up the group, and run() returns within budget.
        let start = Date()
        do {
            _ = try runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "(trap '' TERM; sleep 60) & echo 'parent'; exit 0",
                ],
                timeout: 1.0
            )
        } catch ProcessRunnerError.timedOut {
            // Either timing out or returning normally is acceptable; the
            // invariant we care about is that run() returns in bounded time.
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0, "run() did not return in bounded time: \(elapsed)s")
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
