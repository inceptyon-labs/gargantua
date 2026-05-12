import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentTests {
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
}
