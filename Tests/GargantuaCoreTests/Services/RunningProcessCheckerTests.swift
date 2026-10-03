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
