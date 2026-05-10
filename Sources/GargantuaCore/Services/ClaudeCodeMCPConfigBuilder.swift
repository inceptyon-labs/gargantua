import Foundation

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
