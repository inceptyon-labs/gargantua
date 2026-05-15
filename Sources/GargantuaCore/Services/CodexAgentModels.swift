import Foundation

/// User-configurable settings that control the Codex agent integration.
/// Used by the file organizer's Codex backend (a one-shot `codex exec`
/// invocation) and surfaced in the Settings → AI tab. Mirrors the shape
/// of `ClaudeCodeAgentConfiguration` so the two integrations stay
/// consistent, minus the MCP / max-turns concerns that don't apply to
/// the one-shot exec flow.
public struct CodexAgentConfiguration: Codable, Sendable, Equatable {
    public static let defaultsKey = "codexAgentConfiguration"

    /// Default OpenAI model passed to `codex exec --model`. Empty string
    /// means "let the CLI pick its default" — kept distinct from a typed
    /// default so users opting out aren't pinned to a stale id.
    public static let defaultSelectedModel = ""

    /// Whether the Codex agent integration is enabled.
    public var isEnabled: Bool
    /// Configured filesystem path to the `codex` executable.
    public var cliPath: String
    /// Optional OpenAI model identifier. Empty string defers to CLI default.
    public var selectedModel: String

    public init(
        isEnabled: Bool = false,
        cliPath: String = "",
        selectedModel: String = Self.defaultSelectedModel
    ) {
        self.isEnabled = isEnabled
        self.cliPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case cliPath
        case selectedModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            cliPath: try c.decodeIfPresent(String.self, forKey: .cliPath) ?? "",
            selectedModel: try c.decodeIfPresent(String.self, forKey: .selectedModel) ?? Self.defaultSelectedModel
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(cliPath, forKey: .cliPath)
        try c.encode(selectedModel, forKey: .selectedModel)
    }

    /// Tilde-expanded CLI path, or `nil` when no path is configured.
    public var normalizedCLIPath: String? {
        let trimmed = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }
}

/// Thread-safe persistence wrapper for `CodexAgentConfiguration`.
public final class CodexAgentConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CodexAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: CodexAgentConfiguration.defaultsKey),
              let decoded = try? JSONDecoder().decode(CodexAgentConfiguration.self, from: data)
        else {
            return CodexAgentConfiguration()
        }
        return decoded
    }

    public func save(_ configuration: CodexAgentConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: CodexAgentConfiguration.defaultsKey)
    }
}

public enum CodexAgentError: Error, LocalizedError, Equatable {
    case disabled
    case cliNotFound
    case cliNotExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Enable Codex Agent in Settings before using the Codex organizer backend."
        case .cliNotFound:
            return "Codex CLI was not found. Install codex (`npm i -g @openai/codex`) or set the path explicitly."
        case .cliNotExecutable(let path):
            return "Codex CLI is not executable at \(path)."
        }
    }
}

/// Resolves the `codex` CLI executable from configuration or the user's `PATH`.
public struct CodexCLIResolver: @unchecked Sendable {
    public var environment: [String: String]
    public var fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    public func resolve(configuration: CodexAgentConfiguration) throws -> URL {
        if let configured = configuration.normalizedCLIPath {
            guard fileManager.fileExists(atPath: configured) else {
                throw CodexAgentError.cliNotFound
            }
            guard fileManager.isExecutableFile(atPath: configured) else {
                throw CodexAgentError.cliNotExecutable(configured)
            }
            return URL(fileURLWithPath: configured)
        }
        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("codex")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw CodexAgentError.cliNotFound
    }
}
