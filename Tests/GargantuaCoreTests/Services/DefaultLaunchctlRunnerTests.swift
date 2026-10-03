import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultLaunchctlRunner")
struct DefaultLaunchctlRunnerTests {
    @Test("Output larger than a pipe buffer comes back whole instead of deadlocking")
    func largeOutputDoesNotDeadlock() {
        // /bin/sh stands in for launchctl: 200 KB on stdout overflows the
        // 64 KB pipe buffer, which hung the old wait-then-read order.
        let runner = DefaultLaunchctlRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

        let result = runner.run(["-c", "head -c 200000 /dev/zero | tr '\\\\0' a; echo done >&2"])

        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr == "done\n")
    }
}
