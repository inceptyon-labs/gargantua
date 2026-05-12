// swiftlint:disable line_length
import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentTests {
    @Test("Runner attaches parsed item IDs to the gate when stream-json carries a clean tool_use")
    func runnerAttachesParsedItemIDsFromStreamJSON() async throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path))
        let tempDirectory = try makeTemporaryDirectory()
        let auditDirectory = tempDirectory.appendingPathComponent("audit")
        let auditWriter = AuditWriter(logDirectory: auditDirectory)
        // Stream-json `assistant` event wrapping a clean tool_use so the
        // structured parser path is exercised end-to-end.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_runner","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-3","npm_cache-9"],"method":"trash","confirm":true}}]}}
        """#
        let fakeExecutor = FakeClaudeCodeProcessExecutor(outputs: [
            .stdout(cleanLine + "\n"),
        ])
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(command: "swift", args: ["run", "GargantuaMCP"]),
            processExecutor: fakeExecutor,
            auditWriter: auditWriter,
            tempDirectory: tempDirectory
        )
        let gates = LockedArray<ClaudeCodeAgentApprovalGate>()

        _ = try await runner.run(
            prompt: "audit",
            onEvent: { _ in },
            onGate: { gates.append($0) }
        )

        let collected = gates.all()
        #expect(collected.count == 1)
        #expect(collected.first?.proposedItemIDs == ["chrome_cache-3", "npm_cache-9"])
    }

    @Test("Runner streams transcript, detects clean gates, and writes audit entries")
    func runnerStreamsAndAudits() async throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path))
        let tempDirectory = try makeTemporaryDirectory()
        let auditDirectory = tempDirectory.appendingPathComponent("audit")
        let auditWriter = AuditWriter(logDirectory: auditDirectory)
        // Wrapped assistant event so the structured parser extracts the
        // item_ids into proposedItemIDs — that is the only path that raises
        // a gate now that the substring fallback has been removed.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_runner_audit","name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"],"method":"trash","confirm":true,"dry_run":true}}]}}
        """#
        let fakeExecutor = FakeClaudeCodeProcessExecutor(outputs: [
            .stdout("hello\n"),
            .stdout(cleanLine + "\n"),
            .stderr("warning\n"),
        ])
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(command: "swift", args: ["run", "GargantuaMCP"]),
            processExecutor: fakeExecutor,
            auditWriter: auditWriter,
            tempDirectory: tempDirectory
        )
        let events = LockedArray<ClaudeCodeAgentTranscriptEvent>()
        let gates = LockedArray<ClaudeCodeAgentApprovalGate>()

        let result = try await runner.run(
            prompt: "inspect",
            onEvent: { events.append($0) },
            onGate: { gates.append($0) }
        )

        #expect(result.exitCode == 0)
        #expect(events.all().contains { $0.stream == .stdout && $0.message.contains("hello") })
        #expect(events.all().contains { $0.stream == .stderr && $0.message.contains("warning") })
        #expect(gates.all().count == 1)
        #expect(result.approvalGates.count == 1)
        #expect(gates.all().first?.proposedItemIDs == ["safe-1"])

        let commands = try auditWriter.readEntries().map(\.command)
        #expect(commands.contains("agent_start"))
        #expect(commands.contains("agent_gate_detected"))
        #expect(commands.contains("agent_complete"))
    }

    @Test("Runner cancellation forwards to process executor")
    func runnerCancellationForwardsToExecutor() throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true))
        let fakeExecutor = FakeClaudeCodeProcessExecutor()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            processExecutor: fakeExecutor,
            auditWriter: AuditWriter(logDirectory: try makeTemporaryDirectory())
        )

        runner.cancel()

        #expect(fakeExecutor.didCancel)
    }
}
// swiftlint:enable line_length
