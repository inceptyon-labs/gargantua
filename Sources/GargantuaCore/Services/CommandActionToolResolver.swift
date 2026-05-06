import Foundation

/// Resolves the executable path for a `CommandActionRule`'s `tool` field.
///
/// Where `DeveloperToolBinaryResolver` is keyed by a closed `DeveloperTool`
/// enum (a fixed set of tools the app knows about ahead of time), command
/// rules are YAML-driven and may name any tool. This resolver looks the
/// tool name up in a registry of candidate paths, with an environment-
/// variable override per tool for tests and developer setups.
///
/// Override format: `GARGANTUA_TOOL_<UPPERCASE_NAME>=<absolute path>`
/// (e.g., `GARGANTUA_TOOL_PNPM=/opt/custom/pnpm`).
public struct CommandActionToolResolver: Sendable {
    /// Bundled candidate paths keyed by tool name. Tools not in this map are
    /// resolvable only via the environment override — that keeps the schema
    /// open without silently picking up arbitrary binaries from `$PATH`.
    public static let defaultCandidates: [String: [String]] = [
        // xcrun ships with macOS Command Line Tools. /usr/bin/xcrun is the
        // canonical front-end; on dev machines without CLT installed the
        // resolver simply reports the tool as missing.
        "xcrun": ["/usr/bin/xcrun"],
        // pnpm ships under Homebrew or Corepack; we accept the standard
        // locations and defer user-specific installs (XDG, asdf, etc.) to
        // the env-var override.
        "pnpm": [
            "/opt/homebrew/bin/pnpm",
            "/usr/local/bin/pnpm",
        ],
        "go": [
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/local/go/bin/go",
        ],
        // Re-publish brew/docker so command rules can reach them via the
        // same resolver, even though `DeveloperToolBinaryResolver` already
        // covers them for the in-app developer tools panel.
        "brew": [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/usr/bin/brew",
        ],
        "docker": [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/usr/bin/docker",
        ],
    ]

    private let candidates: [String: [String]]
    private let environment: [String: String]

    public init(
        candidates: [String: [String]] = CommandActionToolResolver.defaultCandidates,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.candidates = candidates
        self.environment = environment
    }

    public static func envVarName(for tool: String) -> String {
        // Restrict to alphanumerics so a malformed tool name can't reach
        // through to invent unexpected env-var names. Anything else gets
        // dropped from the suffix.
        let cleaned = tool.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "GARGANTUA_TOOL_\(cleaned)"
    }

    public func resolve(tool: String) -> URL? {
        let envVar = Self.envVarName(for: tool)
        if let override = environment[envVar], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        guard let paths = candidates[tool] else { return nil }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Best-effort version capture for audit purposes. Runs `<tool> --version`
    /// (or a tool-specific equivalent) with a short timeout. Failure is
    /// non-fatal — the audit entry simply records `nil`.
    public func captureVersion(
        tool: String,
        executable: URL,
        runner: any ProcessRunner
    ) -> String? {
        let arguments = Self.versionArguments(for: tool)
        guard let output = try? runner.run(
            executable: executable,
            arguments: arguments,
            timeout: 5,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        ), output.exitCode == 0 else {
            return nil
        }
        let combined = output.stdout.isEmpty ? output.stderr : output.stdout
        return combined
            .split(separator: "\n")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func versionArguments(for tool: String) -> [String] {
        switch tool {
        case "xcrun":
            // `xcrun --version` returns the developer-tools front-end version,
            // which is sufficient identity for replay purposes.
            return ["--version"]
        case "go":
            return ["version"]
        default:
            return ["--version"]
        }
    }
}
