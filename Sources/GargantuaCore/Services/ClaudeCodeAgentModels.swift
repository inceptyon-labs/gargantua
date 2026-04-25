import Foundation

public struct ClaudeCodeAgentConfiguration: Codable, Sendable, Equatable {
    public static let defaultsKey = "claudeCodeAgentConfiguration"
    public static let defaultMaxTurns = 5

    public var isEnabled: Bool
    public var cliPath: String
    public var maxTurns: Int
    public var allowDestructiveMCPTools: Bool
    public var runAfterScheduledScans: Bool

    public init(
        isEnabled: Bool = false,
        cliPath: String = "",
        maxTurns: Int = Self.defaultMaxTurns,
        allowDestructiveMCPTools: Bool = false,
        runAfterScheduledScans: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.cliPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTurns = min(max(maxTurns, 1), 20)
        self.allowDestructiveMCPTools = allowDestructiveMCPTools
        self.runAfterScheduledScans = runAfterScheduledScans
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case cliPath
        case maxTurns
        case allowDestructiveMCPTools
        case runAfterScheduledScans
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            cliPath: try c.decodeIfPresent(String.self, forKey: .cliPath) ?? "",
            maxTurns: try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? Self.defaultMaxTurns,
            allowDestructiveMCPTools: try c.decodeIfPresent(Bool.self, forKey: .allowDestructiveMCPTools) ?? false,
            runAfterScheduledScans: try c.decodeIfPresent(Bool.self, forKey: .runAfterScheduledScans) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(cliPath, forKey: .cliPath)
        try c.encode(maxTurns, forKey: .maxTurns)
        try c.encode(allowDestructiveMCPTools, forKey: .allowDestructiveMCPTools)
        try c.encode(runAfterScheduledScans, forKey: .runAfterScheduledScans)
    }

    public var normalizedCLIPath: String? {
        let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }
}

public final class ClaudeCodeAgentConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ClaudeCodeAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: ClaudeCodeAgentConfiguration.defaultsKey),
              let decoded = try? JSONDecoder().decode(ClaudeCodeAgentConfiguration.self, from: data)
        else {
            return ClaudeCodeAgentConfiguration()
        }
        return decoded
    }

    public func save(_ configuration: ClaudeCodeAgentConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: ClaudeCodeAgentConfiguration.defaultsKey)
    }
}

public enum ClaudeCodeAgentError: Error, LocalizedError, Equatable {
    case disabled
    case cliNotFound
    case cliNotExecutable(String)
    case mcpConfigWriteFailed(String)
    case processFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Enable Claude Code Agent in Settings before starting an agent session."
        case .cliNotFound:
            "Claude Code CLI was not found. Install Claude Code or set the path to the claude executable."
        case .cliNotExecutable(let path):
            "Claude Code CLI is not executable at \(path)."
        case .mcpConfigWriteFailed(let message):
            "Could not write Claude Code MCP configuration: \(message)"
        case .processFailed(let exitCode):
            "Claude Code exited with status \(exitCode)."
        }
    }
}

public struct ClaudeCodeCLIResolver: @unchecked Sendable {
    public var environment: [String: String]
    public var fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public func resolve(configuration: ClaudeCodeAgentConfiguration) throws -> URL {
        if let configured = configuration.normalizedCLIPath {
            guard fileManager.fileExists(atPath: configured) else {
                throw ClaudeCodeAgentError.cliNotFound
            }
            guard fileManager.isExecutableFile(atPath: configured) else {
                throw ClaudeCodeAgentError.cliNotExecutable(configured)
            }
            return URL(fileURLWithPath: configured)
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("claude")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw ClaudeCodeAgentError.cliNotFound
    }
}

public enum ClaudeCodeAgentPromptTemplate: String, CaseIterable, Identifiable, Sendable {
    case investigateSpace
    case projectArchaeology
    case customCleanupScript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .investigateSpace: "Investigate Space"
        case .projectArchaeology: "Project Archaeology"
        case .customCleanupScript: "Custom Script"
        }
    }

    public var icon: String {
        switch self {
        case .investigateSpace: "magnifyingglass.circle"
        case .projectArchaeology: "folder.badge.questionmark"
        case .customCleanupScript: "terminal"
        }
    }

    public var placeholder: String {
        switch self {
        case .investigateSpace:
            "Find the biggest safe cleanup opportunities on this Mac."
        case .projectArchaeology:
            "Inspect ~/Development/example-project and identify old repos or artifacts I can archive."
        case .customCleanupScript:
            "Generate a reviewable maintenance script for stale build artifacts."
        }
    }

    fileprivate var baseGoal: String {
        switch self {
        case .investigateSpace:
            "Investigate what is taking disk space and produce an evidence-backed cleanup report."
        case .projectArchaeology:
            "Perform project archaeology: identify stale repositories, generated artifacts, and low-risk archive candidates."
        case .customCleanupScript:
            "Generate a custom cleanup script proposal. Do not run it; produce the script and explain every command."
        }
    }
}

public enum ClaudeCodeAgentPromptBuilder {
    public static let readOnlyToolAllowlist = [
        "mcp__gargantua__scan",
        "mcp__gargantua__analyze",
        "mcp__gargantua__status",
        "mcp__gargantua__explain",
        "mcp__gargantua__list_profiles",
    ]

    public static let destructiveTool = "mcp__gargantua__clean"

    public static func prompt(
        template: ClaudeCodeAgentPromptTemplate,
        userContext: String
    ) -> String {
        let trimmedContext = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = trimmedContext.isEmpty ? template.placeholder : trimmedContext
        return """
        You are running inside Gargantua's Tier 3 Claude Code agent mode.

        Goal:
        \(template.baseGoal)

        User context:
        \(context)

        Safety rules:
        - Use only the Gargantua MCP server named "gargantua" for cleanup discovery and cleanup execution.
        - Start with read-only MCP tools: list_profiles, status, analyze, scan, and explain.
        - Never delete, move, overwrite, chmod, chown, or edit files directly through shell commands.
        - Never lower or reinterpret Gargantua safety classifications. Protected items are not eligible for cleanup.
        - Destructive cleanup must go through the MCP clean tool with explicit item IDs from a prior scan.
        - Treat destructive steps as default deny unless the Gargantua UI records user approval.
        - Prefer Trash over permanent delete.
        - Return a concise transcript-ready report with evidence, proposed actions, and any skipped risky items.
        """
    }

    public static func scheduledAuditPrompt(summary: ScheduledScanSummary) -> String {
        prompt(
            template: .investigateSpace,
            userContext: """
            Scheduled scan completed at \(summary.date.formatted(date: .abbreviated, time: .shortened)).
            Profile: \(summary.profileID)
            Actionable items: \(summary.itemCount)
            Reclaimable bytes: \(summary.reclaimableBytes)
            Produce a maintenance audit report. Do not clean anything automatically.
            """
        )
    }
}

public struct ClaudeCodeMCPServerLaunch: Sendable, Equatable {
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(command: String, args: [String], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

public enum ClaudeCodeMCPConfigBuilder {
    public static let serverName = "gargantua"

    public static func defaultServerLaunch(fileManager: FileManager = .default) -> ClaudeCodeMCPServerLaunch {
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledMCP = executableDirectory.appendingPathComponent("GargantuaMCP")
            if fileManager.isExecutableFile(atPath: bundledMCP.path) {
                return ClaudeCodeMCPServerLaunch(command: bundledMCP.path, args: ["--stdio"])
            }
        }

        return ClaudeCodeMCPServerLaunch(
            command: "swift",
            args: ["run", "GargantuaMCP", "--", "--stdio"]
        )
    }

    public static func configurationData(server: ClaudeCodeMCPServerLaunch) throws -> Data {
        let config = ClaudeCodeMCPConfig(mcpServers: [
            serverName: ClaudeCodeMCPServerConfig(
                type: "stdio",
                command: server.command,
                args: server.args,
                env: server.env
            ),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    public static func writeConfiguration(
        server: ClaudeCodeMCPServerLaunch,
        sessionID: UUID,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("gargantua-claude-code-\(sessionID.uuidString).mcp.json")
            try configurationData(server: server).write(to: url, options: .atomic)
            return url
        } catch {
            throw ClaudeCodeAgentError.mcpConfigWriteFailed(error.localizedDescription)
        }
    }
}

private struct ClaudeCodeMCPConfig: Codable {
    let mcpServers: [String: ClaudeCodeMCPServerConfig]
}

private struct ClaudeCodeMCPServerConfig: Codable {
    let type: String
    let command: String
    let args: [String]
    let env: [String: String]
}
