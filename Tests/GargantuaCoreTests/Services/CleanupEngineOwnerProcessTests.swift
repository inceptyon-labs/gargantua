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
        let probe = try ProbeProcess()
        let terminator = WorkspaceRunningApplicationTerminator()

        #expect(await terminator.terminateRunningApplications(bundleIdentifier: probe.name, timeout: 1) == false, "\(probe.diagnosis)")

        probe.stop()

        #expect(await terminator.terminateRunningApplications(bundleIdentifier: probe.name, timeout: 1) == true)
    }

    @Test("The production engine skips an item while a command-line owner runs, removes it after")
    @MainActor
    func productionEngineSeesCommandLineOwner() async throws {
        let probe = try ProbeProcess()
        defer { probe.stop() }
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        var item = makeItem(path: file.path)
        item.ownerProcesses = [probe.name]

        let skipped = await CleanupEngine().clean([item], method: .delete, authorization: .unchecked(.mcpClean))
        #expect(skipped.itemResults.first?.succeeded == false, "\(probe.diagnosis)")
        #expect(FileManager.default.fileExists(atPath: file.path), "\(probe.diagnosis)")

        probe.stop()

        let removed = await CleanupEngine().clean([item], method: .delete, authorization: .unchecked(.mcpClean))
        #expect(removed.itemResults.first?.succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
