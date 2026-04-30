import Foundation

/// User-configurable settings that control the Claude Code agent integration.
public struct ClaudeCodeAgentConfiguration: Codable, Sendable, Equatable {
    /// UserDefaults key used for the encoded configuration.
    public static let defaultsKey = "claudeCodeAgentConfiguration"
    /// Default conversation-turn budget for an agent session. Picked from
    /// the typical scan→analyze→explain→report loop length; 5 was too tight
    /// and had users hitting `error_max_turns` after spending real money.
    public static let defaultMaxTurns = 15

    /// Default model identifier. Sonnet rather than Opus — Opus 4.7 cost
    /// $0.45/run for what was meant to be a scan loop. Users can override
    /// in Settings; the catalog ships a baked-in fallback list and refreshes
    /// from `/v1/models` whenever an API key is configured.
    public static let defaultSelectedModel = "claude-sonnet-4-6"

    /// Whether the Claude Code agent integration is enabled.
    public var isEnabled: Bool
    /// Configured filesystem path to the `claude` executable.
    public var cliPath: String
    /// Maximum number of conversation turns per agent session.
    public var maxTurns: Int
    /// Anthropic model identifier passed to `claude --model`. Empty string
    /// means "let the CLI pick its default" — kept distinct from the typed
    /// default so users can opt out without us picking a stale ID.
    public var selectedModel: String
    /// Whether the agent may invoke the destructive MCP `clean` tool.
    public var allowDestructiveMCPTools: Bool
    /// Whether an audit agent runs after each scheduled scan.
    public var runAfterScheduledScans: Bool

    /// Creates an agent configuration, clamping `maxTurns` to `[1, 20]`.
    public init(
        isEnabled: Bool = false,
        cliPath: String = "",
        maxTurns: Int = Self.defaultMaxTurns,
        selectedModel: String = Self.defaultSelectedModel,
        allowDestructiveMCPTools: Bool = false,
        runAfterScheduledScans: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.cliPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTurns = min(max(maxTurns, 1), 20)
        self.selectedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowDestructiveMCPTools = allowDestructiveMCPTools
        self.runAfterScheduledScans = runAfterScheduledScans
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case cliPath
        case maxTurns
        case selectedModel
        case allowDestructiveMCPTools
        case runAfterScheduledScans
    }

    /// Decodes a configuration with backwards-compatible defaults for missing fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            cliPath: try c.decodeIfPresent(String.self, forKey: .cliPath) ?? "",
            maxTurns: try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? Self.defaultMaxTurns,
            selectedModel: try c.decodeIfPresent(String.self, forKey: .selectedModel) ?? Self.defaultSelectedModel,
            allowDestructiveMCPTools: try c.decodeIfPresent(Bool.self, forKey: .allowDestructiveMCPTools) ?? false,
            runAfterScheduledScans: try c.decodeIfPresent(Bool.self, forKey: .runAfterScheduledScans) ?? false
        )
    }

    /// Encodes the configuration into a keyed container.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(cliPath, forKey: .cliPath)
        try c.encode(maxTurns, forKey: .maxTurns)
        try c.encode(selectedModel, forKey: .selectedModel)
        try c.encode(allowDestructiveMCPTools, forKey: .allowDestructiveMCPTools)
        try c.encode(runAfterScheduledScans, forKey: .runAfterScheduledScans)
    }

    /// Tilde-expanded CLI path, or `nil` when no path is configured.
    public var normalizedCLIPath: String? {
        let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }
}

/// Thread-safe persistence wrapper for `ClaudeCodeAgentConfiguration`.
public final class ClaudeCodeAgentConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Creates a store backed by the supplied user defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads the saved configuration, or returns defaults when none is available.
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

    /// Saves the supplied configuration when it can be encoded.
    public func save(_ configuration: ClaudeCodeAgentConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: ClaudeCodeAgentConfiguration.defaultsKey)
    }
}

/// Errors surfaced by Claude Code agent setup and execution.
public enum ClaudeCodeAgentError: Error, LocalizedError, Equatable {
    /// The agent integration is disabled in settings.
    case disabled
    /// The `claude` CLI could not be located on the system.
    case cliNotFound
    /// The configured CLI path exists but is not executable.
    case cliNotExecutable(String)
    /// Writing the per-session MCP configuration file failed.
    case mcpConfigWriteFailed(String)
    /// The agent process exited with a non-zero status.
    case processFailed(Int32)

    /// Localized user-facing error description.
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

/// Resolves the `claude` CLI executable from configuration or the user's `PATH`.
public struct ClaudeCodeCLIResolver: @unchecked Sendable {
    /// Process environment used for `PATH` lookup.
    public var environment: [String: String]
    /// File manager used for existence and executability checks.
    public var fileManager: FileManager

    /// Creates a resolver using the supplied environment and file manager.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    /// Returns a URL for the `claude` executable, preferring the configured path.
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

/// Built-in agent prompt templates surfaced in the UI.
public enum ClaudeCodeAgentPromptTemplate: String, CaseIterable, Identifiable, Sendable {
    /// Investigate disk-space usage and propose safe cleanup.
    case investigateSpace
    /// Inspect a development directory for stale projects and artifacts.
    case projectArchaeology
    /// Generate a reviewable maintenance script.
    case customCleanupScript

    /// Stable identifier used by SwiftUI lists and pickers.
    public var id: String { rawValue }

    /// Short user-facing template name. Action-oriented so the label alone
    /// telegraphs what artifact comes back ("an audit", "a script", etc.).
    /// The raw enum values are kept stable so persisted selections don't
    /// silently flip when the labels change.
    public var title: String {
        switch self {
        case .investigateSpace: "Audit Disk Space"
        case .projectArchaeology: "Find Stale Dev Projects"
        case .customCleanupScript: "Generate Cleanup Script"
        }
    }

    /// SF Symbol used for the template icon.
    public var icon: String {
        switch self {
        case .investigateSpace: "magnifyingglass.circle"
        case .projectArchaeology: "folder.badge.questionmark"
        case .customCleanupScript: "terminal"
        }
    }

    /// One-line description shown directly under the picker so users know
    /// what the preset will actually do without having to expand the full
    /// prompt preview.
    public var summary: String {
        switch self {
        case .investigateSpace:
            "Reviews the whole Mac via the read-only MCP scan/analyze tools and returns an evidence-backed cleanup report. Nothing is deleted."
        case .projectArchaeology:
            "Looks at a development directory you specify, flagging stale repos, build artifacts, and archive candidates. Produces a written report; no files are touched."
        case .customCleanupScript:
            "Produces a reviewable shell script with every command annotated. The script is shown for review only — the agent never runs it."
        }
    }

    /// Placeholder user context shown in the prompt input field.
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

    /// The "Goal:" sentence that gets stamped into the prompt builder. Made
    /// non-fileprivate so the trust-pass UI can render the same string the
    /// builder uses, and tests can pin them in lockstep.
    public var baseGoal: String {
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

/// Builds the text prompts handed to the Claude Code agent process.
public enum ClaudeCodeAgentPromptBuilder {
    /// MCP tools the agent may invoke without an explicit user approval.
    public static let readOnlyToolAllowlist = [
        "mcp__gargantua__scan",
        "mcp__gargantua__analyze",
        "mcp__gargantua__status",
        "mcp__gargantua__explain",
        "mcp__gargantua__list_profiles",
    ]

    /// Destructive MCP tool name gated behind explicit user approval.
    public static let destructiveTool = "mcp__gargantua__clean"

    /// Builds an agent prompt for a template and trimmed user-supplied context.
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

    /// Builds a post-scheduled-scan audit prompt using the supplied scan summary.
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

/// Launch arguments for the MCP server child process spawned by the agent.
public struct ClaudeCodeMCPServerLaunch: Sendable, Equatable {
    /// Executable path or command name to run.
    public let command: String
    /// Arguments passed to the executable.
    public let args: [String]
    /// Extra environment variables merged into the child process environment.
    public let env: [String: String]

    /// Creates a launch descriptor for the MCP server child process.
    public init(command: String, args: [String], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

/// Builds the per-session MCP configuration JSON consumed by Claude Code.
public enum ClaudeCodeMCPConfigBuilder {
    /// MCP server name used in the generated configuration.
    public static let serverName = "gargantua"

    /// Returns the preferred MCP server launch, falling back to `swift run` in dev.
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

    /// Encodes the MCP configuration JSON for the supplied server launch.
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

    /// Writes the per-session MCP configuration file and returns its URL.
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
