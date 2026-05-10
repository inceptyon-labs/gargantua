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
