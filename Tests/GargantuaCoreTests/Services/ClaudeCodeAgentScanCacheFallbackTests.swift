import Foundation
import Testing
@testable import GargantuaCore

@Suite("ClaudeCodeAgentSessionController scan cache fallback — wire round-trip")
@MainActor
struct ClaudeCodeAgentScanCacheFallbackTests {
    @Test("scanResult(from:) carries a recorded scan_time_resolved_parent through to ScanResult")
    func recordedParentRoundTrips() {
        let item = MCPScanItem(
            id: "chrome_cache_001",
            name: "Chrome Browser Cache",
            path: "/Volumes/Ext/dev/node_modules",
            size: "10.5 GB",
            safety: "safe",
            confidence: 99,
            explanation: "Browser cache files. Regenerated automatically.",
            source: "Google Chrome",
            category: "dev_artifacts",
            // Distinct from `path`'s literal parent (`/Volumes/Ext/dev`) — a
            // symlinked ancestor resolves elsewhere. Asserting this exact value
            // proves the wire value is carried through, not re-derived from
            // `path` at rehydration time.
            scanTimeResolvedParent: "/mnt/real/dev"
        )
        let result = ClaudeCodeAgentSessionController.scanResult(from: item)
        #expect(result?.scanTimeResolvedParent == "/mnt/real/dev")
    }

    @Test("scanResult(from:) carries rule tags through so the removability check still sees `privileged`")
    func tagsRoundTrip() throws {
        let item = MCPScanItem(
            id: "macos_installer_payloads-1",
            name: "Install macOS Tahoe.app",
            path: "/Applications/Install macOS Tahoe.app",
            size: "12 GB",
            safety: "review",
            confidence: 90,
            explanation: "installer",
            source: "rules",
            category: "system_cache",
            tags: ["privileged"]
        )
        let result = try #require(ClaudeCodeAgentSessionController.scanResult(from: item))
        #expect(result.tags == ["privileged"])
        #expect(RemovabilityReconciler().removability(for: result).isRemovable == false)
    }

    @Test("scanResult(from:) leaves scan_time_resolved_parent nil when the wire item didn't carry one")
    func nilParentStaysNil() {
        let item = MCPScanItem(
            id: "chrome_cache_001",
            name: "Chrome Browser Cache",
            path: "/Volumes/Ext/dev/node_modules",
            size: "10.5 GB",
            safety: "safe",
            confidence: 99,
            explanation: "Browser cache files. Regenerated automatically.",
            source: "Google Chrome",
            category: "dev_artifacts",
            scanTimeResolvedParent: nil
        )
        let result = ClaudeCodeAgentSessionController.scanResult(from: item)
        #expect(result?.scanTimeResolvedParent == nil)
    }

    @Test("owner processes and blocked app survive makeOutput, JSON and scanResult(from:), and still skip the clean")
    func ownersRoundTripAndSkipClean() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("logs.sqlite")
        try Data("x".utf8).write(to: file)
        let blocked = BlockedApp(bundleID: "com.openai.codex", name: "Codex")
        let original = ScanResult(
            id: "codex_logs", name: "Codex logs", path: file.path, size: 1, safety: .safe,
            confidence: 90, explanation: "x", source: SourceAttribution(name: "Codex"),
            category: "ai_history", blockedByApp: blocked, ownerProcesses: ["codex"]
        )

        let output = MCPScanToolHandler.makeOutput(from: [original])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MCPScanOutput.self, from: encoder.encode(output))
        let wireItem = try #require(decoded.items.first)
        let rebuilt = try #require(ClaudeCodeAgentSessionController.scanResult(from: wireItem))

        #expect(rebuilt.ownerProcesses == ["codex"])
        #expect(rebuilt.blockedByApp == blocked)

        let engine = CleanupEngine(homeDirectoryForTesting: dir, isAppRunning: { $0 == "codex" })
        let result = await engine.clean([rebuilt], method: .delete, authorization: .unchecked(.mcpClean))
        #expect(result.itemResults.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a payload without owner keys still decodes")
    func oldPayloadDecodes() throws {
        let json = """
        {"id":"a","name":"n","path":"/tmp/a","size":"1 KB","safety":"safe","confidence":90,\
        "explanation":"e","source":"s","category":"c"}
        """
        let item = try JSONDecoder().decode(MCPScanItem.self, from: Data(json.utf8))
        #expect(item.ownerProcesses == nil)
        #expect(item.blockedByApp == nil)
    }
}
