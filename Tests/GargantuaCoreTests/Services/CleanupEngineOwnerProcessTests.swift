import Foundation
import Testing
@testable import GargantuaCore

@Suite("Clean-time owner process check")
struct CleanupEngineOwnerProcessTests {
    private func makeItem(path: String) -> ScanResult {
        ScanResult(
            id: "owned",
            name: "Owned",
            path: path,
            size: 1,
            safety: .safe,
            confidence: 95,
            explanation: "x",
            source: SourceAttribution(name: "Codex"),
            category: "test",
            ownerProcesses: ["codex"]
        )
    }

    private func makeTempFile() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("entry")
        try Data("x".utf8).write(to: file)
        return (dir, file)
    }

    @Test("An owner running at clean time skips the item even though the scan saw no block")
    @MainActor
    func runningOwnerSkipsItem() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CleanupEngine(homeDirectoryForTesting: dir, isAppRunning: { $0 == "codex" })

        let result = await engine.clean([makeItem(path: file.path)], method: .delete, authorization: .unchecked(.mcpClean))

        #expect(result.itemResults.first?.succeeded == false)
        #expect(result.itemResults.first?.error?.contains("is running") == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("With the owner not running the item is removed")
    @MainActor
    func stoppedOwnerAllowsRemoval() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CleanupEngine(homeDirectoryForTesting: dir, isAppRunning: { _ in false })

        let result = await engine.clean([makeItem(path: file.path)], method: .delete, authorization: .unchecked(.mcpClean))

        #expect(result.itemResults.first?.succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("The terminator reports failure while a command-line owner runs, success once it exits")
    @MainActor
    func terminatorSeesCommandLineOwner() async throws {
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
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let terminator = WorkspaceRunningApplicationTerminator()

        #expect(await terminator.terminateRunningApplications(bundleIdentifier: name, timeout: 1) == false)

        process.terminate()
        process.waitUntilExit()

        #expect(await terminator.terminateRunningApplications(bundleIdentifier: name, timeout: 1) == true)
    }
}
