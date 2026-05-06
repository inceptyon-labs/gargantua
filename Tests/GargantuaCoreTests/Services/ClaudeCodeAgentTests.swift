import Foundation
import os
import Testing
@testable import GargantuaCore

// swiftlint:disable line_length type_body_length
// JSONL test fixtures — see ClaudeCodeStreamJSONParserTests.swift for rationale.
// type_body_length is disabled because each test scenario is a self-contained
// fixture; splitting the suite would scatter shared FakeClaudeCodeProcessExecutor
// helpers without simplifying anything.

@Suite("Claude Code Agent Tier 3")
struct ClaudeCodeAgentTests {
    @Test("CLI resolver uses configured executable path")
    func cliResolverUsesConfiguredPath() throws {
        let executable = try makeExecutable(named: "claude")
        let configuration = ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path)
        let resolved = try ClaudeCodeCLIResolver(environment: [:]).resolve(configuration: configuration)

        #expect(resolved == executable)
    }

    @Test("CLI resolver falls back to PATH")
    func cliResolverFallsBackToPath() throws {
        let executable = try makeExecutable(named: "claude")
        let resolver = ClaudeCodeCLIResolver(environment: [
            "PATH": executable.deletingLastPathComponent().path,
        ])

        let resolved = try resolver.resolve(configuration: ClaudeCodeAgentConfiguration(isEnabled: true))

        #expect(resolved == executable)
    }

    @Test("Launch plan uses strict MCP config and includes the dry-run-propose clean tool by default")
    func launchPlanUsesStrictMCPConfigAndIncludesCleanForDryRunPropose() throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path, maxTurns: 7))
        let tempDirectory = try makeTemporaryDirectory()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(
                command: "/usr/local/bin/GargantuaMCP",
                args: ["--stdio"],
                env: ["GARGANTUA_TEST": "1"]
            ),
            processExecutor: FakeClaudeCodeProcessExecutor(),
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )

        let sessionID = UUID()
        let plan = try runner.makeLaunchPlan(
            prompt: "inspect",
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(plan.executableURL == executable)
        #expect(plan.arguments.contains("--strict-mcp-config"))
        #expect(plan.arguments.contains("--output-format"))
        #expect(plan.arguments.contains("stream-json"))
        #expect(plan.arguments.contains("--max-turns"))
        #expect(plan.arguments.contains("7"))
        // Interactive sessions: clean is allowed (agent uses dry_run: true to
        // propose a cleanup set; host gate routes it into the review modal).
        // No --disallowedTools argument — that's reserved for forced-read-only
        // scheduled-audit launches.
        #expect(!plan.arguments.contains("--disallowedTools"))
        #expect(plan.arguments.contains("--allowedTools"))
        let allowedToolsIndex = try #require(plan.arguments.firstIndex(of: "--allowedTools"))
        let allowedTools = plan.arguments[allowedToolsIndex + 1]
        #expect(allowedTools.contains("mcp__gargantua__scan"))
        #expect(allowedTools.contains("mcp__gargantua__analyze"))
        #expect(allowedTools.contains("mcp__gargantua__clean"))

        let configText = try String(contentsOf: plan.mcpConfigURL, encoding: .utf8)
        #expect(configText.contains(#""gargantua""#))
        #expect(configText.contains(#""type" : "stdio""#))
        #expect(configText.contains("GargantuaMCP"))
        #expect(configText.contains(#""GARGANTUA_TEST" : "1""#))
        #expect(plan.environment["GARGANTUA_AGENT_SESSION_ID"] == sessionID.uuidString)
    }

    @Test("Launch plan defaults workingDirectory to a fresh per-session scratch dir under tempDirectory")
    func launchPlanCreatesPerSessionScratchDirectory() throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path))
        let tempDirectory = try makeTemporaryDirectory()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(command: "/usr/local/bin/GargantuaMCP", args: ["--stdio"]),
            processExecutor: FakeClaudeCodeProcessExecutor(),
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )

        let sessionID = UUID()
        let plan = try runner.makeLaunchPlan(prompt: "go", sessionID: sessionID)

        let scratch = try #require(plan.workingDirectory)
        // Path shape: <tempDirectory>/sessions/<sessionID>/
        #expect(scratch.path.hasPrefix(tempDirectory.path))
        #expect(scratch.path.contains("/sessions/"))
        #expect(scratch.lastPathComponent == sessionID.uuidString)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "Per-session scratch must exist as a directory before launch")

        // Two runs in a row must use distinct scratch dirs so cross-session
        // residue can never end up in another agent's allowed-write surface.
        let second = try runner.makeLaunchPlan(prompt: "go", sessionID: UUID())
        #expect(second.workingDirectory?.path != scratch.path)
    }

    @Test("Explicit workingDirectory passed to makeLaunchPlan is honored verbatim")
    func launchPlanHonorsExplicitWorkingDirectory() throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path))
        let tempDirectory = try makeTemporaryDirectory()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(command: "/usr/local/bin/GargantuaMCP", args: ["--stdio"]),
            processExecutor: FakeClaudeCodeProcessExecutor(),
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )

        let explicit = URL(fileURLWithPath: "/var/empty")
        let plan = try runner.makeLaunchPlan(prompt: "go", sessionID: UUID(), workingDirectory: explicit)
        #expect(plan.workingDirectory == explicit)
    }

    @Test("Launch plan forwards selectedModel as --model when set, omits the flag when blank")
    func launchPlanForwardsSelectedModel() throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(
            isEnabled: true,
            cliPath: executable.path,
            selectedModel: "claude-haiku-4-5-20251001"
        ))
        let tempDirectory = try makeTemporaryDirectory()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            mcpServerLaunch: ClaudeCodeMCPServerLaunch(command: "/usr/local/bin/GargantuaMCP", args: ["--stdio"]),
            processExecutor: FakeClaudeCodeProcessExecutor(),
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )

        let plan = try runner.makeLaunchPlan(prompt: "go", sessionID: UUID())
        let modelIndex = try #require(plan.arguments.firstIndex(of: "--model"))
        #expect(plan.arguments[modelIndex + 1] == "claude-haiku-4-5-20251001")

        // Empty selectedModel must NOT inject --model (let the CLI pick its default).
        configStore.save(ClaudeCodeAgentConfiguration(
            isEnabled: true,
            cliPath: executable.path,
            selectedModel: ""
        ))
        let blankPlan = try runner.makeLaunchPlan(prompt: "go", sessionID: UUID())
        #expect(!blankPlan.arguments.contains("--model"))
    }

    @Test("Prompt builder pins MCP and safety-floor instructions")
    func promptBuilderPinsSafetyInstructions() {
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: "Find stale Docker and Xcode artifacts."
        )

        #expect(prompt.contains("Gargantua MCP server"))
        #expect(prompt.contains("Never delete"))
        #expect(prompt.contains("Protected items are not eligible"))
        #expect(prompt.contains("Find stale Docker and Xcode artifacts."))
        // The dry-run-propose handoff is the actionable edge of the prompt:
        // without it the agent emits prose, never calls clean, and the user
        // never sees a review modal. Pin both the tool name and the dry_run
        // requirement so accidental copy edits can't quietly regress this.
        #expect(prompt.contains("mcp__gargantua__clean"))
        #expect(prompt.contains("dry_run: true"))
        #expect(prompt.contains("item_ids"))
    }

    @Test("Prompt forbids non-dry-run clean calls so the host modal stays the only deletion path")
    func promptBuilderForbidsNonDryRunClean() {
        let prompt = ClaudeCodeAgentPromptBuilder.prompt(
            template: .investigateSpace,
            userContext: ""
        )
        #expect(prompt.contains("Never call `mcp__gargantua__clean` without `dry_run: true`"))
    }

    @Test("Configuration decodes older stored payloads with scheduled audits off")
    func configurationDecodesOlderPayloads() throws {
        let data = Data(#"{"isEnabled":true,"cliPath":"/bin/claude","maxTurns":3,"allowDestructiveMCPTools":true}"#.utf8)
        let configuration = try JSONDecoder().decode(ClaudeCodeAgentConfiguration.self, from: data)

        #expect(configuration.isEnabled)
        #expect(configuration.runAfterScheduledScans == false)
    }

    @Test("Scheduled audit prompt includes scan summary and forbids automatic cleanup")
    func scheduledAuditPromptIncludesSummary() {
        let summary = ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 200_000),
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 42_000
        )

        let prompt = ClaudeCodeAgentPromptBuilder.scheduledAuditPrompt(summary: summary)

        #expect(prompt.contains("Scheduled scan completed"))
        #expect(prompt.contains("Profile: light"))
        #expect(prompt.contains("Actionable items: 3"))
        #expect(prompt.contains("Do not clean anything automatically"))
    }

    @Test("Scheduled audit sessions stay read-only even when clean tool is globally allowed")
    func scheduledAuditForcesReadOnlyLaunch() async throws {
        let defaults = try makeDefaults()
        let configStore = ClaudeCodeAgentConfigurationStore(defaults: defaults)
        let executable = try makeExecutable(named: "claude")
        configStore.save(ClaudeCodeAgentConfiguration(
            isEnabled: true,
            cliPath: executable.path,
            allowDestructiveMCPTools: true,
            runAfterScheduledScans: true
        ))
        let fakeExecutor = FakeClaudeCodeProcessExecutor()
        let tempDirectory = try makeTemporaryDirectory()
        let runner = ClaudeCodeAgentSessionRunner(
            configurationStore: configStore,
            cliResolver: ClaudeCodeCLIResolver(environment: [:]),
            processExecutor: fakeExecutor,
            auditWriter: AuditWriter(logDirectory: tempDirectory.appendingPathComponent("audit")),
            tempDirectory: tempDirectory
        )
        let hook = ClaudeCodeScheduledAgentAuditHook(configurationStore: configStore, runner: runner)

        await hook.run(summary: ScheduledScanSummary(
            date: Date(timeIntervalSince1970: 200_000),
            profileID: "light",
            itemCount: 3,
            reclaimableBytes: 42_000
        ))

        let arguments = fakeExecutor.lastArguments
        let allowedToolsIndex = try #require(arguments.firstIndex(of: "--allowedTools"))
        let allowedTools = arguments[allowedToolsIndex + 1]
        #expect(!allowedTools.contains("mcp__gargantua__clean"))
        #expect(arguments.contains("--disallowedTools"))
        #expect(arguments.contains("mcp__gargantua__clean"))
    }

    @Test("Destructive action detector creates default-deny approval gate from structured tool_use payload")
    func destructiveActionDetectorCreatesGate() {
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let line = #"{"type":"tool_use","name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"],"confirm":true}}"#

        let gate = detector.detect(line, proposedItemIDs: ["safe-1"])

        #expect(gate?.sessionID == sessionID)
        #expect(gate?.status == .pending)
        #expect(gate?.rawTranscript == line)
        #expect(gate?.proposedItemIDs == ["safe-1"])
    }

    @Test("Detector ignores assistant text mentioning the clean tool — only structured tool_use payloads gate")
    func detectorIgnoresPromptEcho() {
        // The agent's prompt now instructs it to call mcp__gargantua__clean
        // with item_ids, so its assistant messages frequently echo both
        // tokens. Without this guard, every plan-narration message would
        // trip a duplicate gate. Only structured tool_use payloads (which
        // populate proposedItemIDs via the stream-json parser) should fire.
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let assistantNarration = #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll call mcp__gargantua__clean with item_ids: [\"safe-1\"] and dry_run: true."}]}}"#

        let gate = detector.detect(assistantNarration, proposedItemIDs: [])

        #expect(gate == nil)
    }

    @Test("Detector with structured proposedItemIDs stamps them on the gate and includes the count in the summary")
    func detectorAttachesProposedItemIDs() {
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let line = "free-form agent narration that doesn't substring-match"

        let gate = detector.detect(line, proposedItemIDs: ["chrome_cache-1", "npm_cache-2"])

        #expect(gate?.proposedItemIDs == ["chrome_cache-1", "npm_cache-2"])
        #expect(gate?.summary.contains("2 items") == true)
    }

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

    private func makeDefaults() throws -> UserDefaults {
        let suite = "gargantua-claude-code-agent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeExecutable(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-claude-code-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FakeClaudeCodeProcessExecutor: ClaudeCodeAgentProcessExecuting, @unchecked Sendable {
    private struct State {
        var didCancel = false
        var lastArguments: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let outputs: [ClaudeCodeProcessOutput]
    private let exitCode: Int32

    init(outputs: [ClaudeCodeProcessOutput] = [], exitCode: Int32 = 0) {
        self.outputs = outputs
        self.exitCode = exitCode
    }

    var didCancel: Bool {
        lock.withLock { $0.didCancel }
    }

    var lastArguments: [String] {
        lock.withLock { $0.lastArguments }
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        onOutput: @escaping @Sendable (ClaudeCodeProcessOutput) -> Void
    ) async throws -> Int32 {
        lock.withLock { $0.lastArguments = arguments }

        for output in outputs {
            onOutput(output)
        }
        return exitCode
    }

    func cancel() {
        lock.withLock { $0.didCancel = true }
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        values.append(element)
        lock.unlock()
    }

    func all() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
// swiftlint:enable line_length type_body_length
