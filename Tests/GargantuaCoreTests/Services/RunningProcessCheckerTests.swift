import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultRunningProcessChecker")
struct RunningProcessCheckerTests {
    @Test("detects a command-line process by executable name, case-insensitively")
    func detectsCommandLineProcess() throws {
        let probe = try ProbeProcess()
        let checker = DefaultRunningProcessChecker()

        #expect(checker.isRunning(identifier: probe.name))
        #expect(checker.isRunning(identifier: probe.name.uppercased()))

        probe.stop()
        #expect(!checker.isRunning(identifier: probe.name))
    }

    @Test("a dotted identifier matching no app is not running")
    func dottedIdentifierNotRunning() {
        #expect(!DefaultRunningProcessChecker().isRunning(identifier: "com.example.not-running-\(UUID())"))
    }
}

@Suite("ProcessTable.executablePaths")
struct ProcessTableExecutablePathsTests {
    @Test("returns the probe's path while it runs and nothing after it stops")
    func findsProbePath() throws {
        let probe = try ProbeProcess()

        let paths = ProcessTable.executablePaths(named: probe.name.uppercased())
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/" + probe.name) == true)

        probe.stop()
        #expect(ProcessTable.executablePaths(named: probe.name).isEmpty)
    }
}
