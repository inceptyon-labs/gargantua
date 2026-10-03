import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultRunningProcessChecker")
struct RunningProcessCheckerTests {
    @Test("detects a command-line process by executable name, case-insensitively")
    func detectsCommandLineProcess() throws {
        let suffix = String(UUID().uuidString.lowercased().filter { $0.isHexDigit }.prefix(8))
        let name = "gargantua-probe-\(suffix)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: dir)
        }
        try process.run()

        let checker = DefaultRunningProcessChecker()
        let deadline = Date().addingTimeInterval(5)
        while !checker.isRunning(identifier: name), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(checker.isRunning(identifier: name))
        #expect(checker.isRunning(identifier: name.uppercased()))

        process.terminate()
        process.waitUntilExit()
        #expect(!checker.isRunning(identifier: name))
    }

    @Test("a dotted identifier matching no app is not running")
    func dottedIdentifierNotRunning() {
        #expect(!DefaultRunningProcessChecker().isRunning(identifier: "com.example.not-running-\(UUID())"))
    }
}
