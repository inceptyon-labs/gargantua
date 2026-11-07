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
        // pnpm often lives under Node-version managers, so cover the common
        // shims here and append discovered nvm installs at runtime.
        "pnpm": [
            "/opt/homebrew/bin/pnpm",
            "/usr/local/bin/pnpm",
            "~/Library/pnpm/pnpm",
            "~/.local/share/pnpm/pnpm",
            "~/.local/bin/pnpm",
            "~/.asdf/shims/pnpm",
            "~/.volta/bin/pnpm",
            "~/.local/share/mise/shims/pnpm",
        ],
        "npm": [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "~/.local/bin/npm",
            "~/.asdf/shims/npm",
            "~/.volta/bin/npm",
            "~/.local/share/mise/shims/npm",
        ],
        "yarn": [
            "/opt/homebrew/bin/yarn",
            "/usr/local/bin/yarn",
            "~/.yarn/bin/yarn",
            "~/.local/bin/yarn",
            "~/.asdf/shims/yarn",
            "~/.volta/bin/yarn",
            "~/.local/share/mise/shims/yarn",
        ],
        "go": [
            "/opt/homebrew/bin/go",
            "/usr/local/bin/go",
            "/usr/local/go/bin/go",
        ],
        "cargo": [
            "/opt/homebrew/bin/cargo",
            "/usr/local/bin/cargo",
            "~/.cargo/bin/cargo",
            "~/.asdf/shims/cargo",
            "~/.local/share/mise/shims/cargo",
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
        // tmutil can also delete backups and change destinations, so
        // `validateArguments` pins it to the local-snapshot verbs.
        "tmutil": ["/usr/bin/tmutil"],
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

    /// Sub-tools `xcrun` is permitted to front. `xcrun` is a general-purpose
    /// launcher — `xcrun --run <path>` and `xcrun <abs-path>` will exec an
    /// arbitrary binary — so an allowlisted `xcrun` in `defaultCandidates` is
    /// only safe if its first argument is pinned to a known sub-tool. The one
    /// bundled rule that uses it (`simctl_delete_unavailable`) runs
    /// `xcrun simctl delete unavailable`, so `simctl` is the sole entry.
    public static let xcrunAllowedSubcommands: Set<String> = ["simctl"]

    /// Verbs a command rule may pass to `tmutil`: listing and deleting local
    /// snapshots only, never backups on the Time Machine disk.
    public static let tmutilAllowedVerbs: Set<String> = ["listlocalsnapshots", "deletelocalsnapshots"]

    /// Rejected when a command rule tries to turn an allowlisted general
    /// launcher into arbitrary execution.
    public enum ArgumentPolicyError: Error, Equatable, LocalizedError {
        case disallowedInvocation(tool: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .disallowedInvocation(let tool, let reason):
                "Command rule invocation of \"\(tool)\" is not permitted: \(reason)"
            }
        }
    }

    /// Constrains the arguments a rule may pass to launcher-class tools before
    /// they run. Currently `xcrun` and `tmutil` are constrained; every other
    /// tool is a no-op. Applies to both the dry-run and destructive argument
    /// vectors — a tampered dry-run is just as dangerous as a tampered
    /// destructive run.
    ///
    /// Not called for the resolver's own internal `--version` capture, which
    /// uses fixed, non-rule-controlled arguments.
    public static func validateArguments(tool: String, arguments: [String]) throws {
        if tool == "tmutil" {
            guard let verb = arguments.first, tmutilAllowedVerbs.contains(verb) else {
                let allowed = tmutilAllowedVerbs.sorted().joined(separator: ", ")
                throw ArgumentPolicyError.disallowedInvocation(
                    tool: tool,
                    reason: "verb `\(arguments.first ?? "")` is not allowlisted; expected one of \(allowed)"
                )
            }
            return
        }
        guard tool == "xcrun" else { return }
        guard let sub = arguments.first else {
            throw ArgumentPolicyError.disallowedInvocation(
                tool: tool,
                reason: "no sub-tool given; expected one of \(xcrunAllowedSubcommands.sorted().joined(separator: ", "))"
            )
        }
        // Reject the launcher flags outright so the error is specific, even
        // though the allowlist check below would also catch them.
        let lowered = sub.lowercased()
        if lowered == "--run" || lowered == "-r" || lowered.hasPrefix("--run=") {
            throw ArgumentPolicyError.disallowedInvocation(
                tool: tool,
                reason: "`\(sub)` runs an arbitrary binary"
            )
        }
        // A path (absolute or relative) as the first argument is executed
        // directly by xcrun — never a legitimate sub-tool name.
        if sub.contains("/") {
            throw ArgumentPolicyError.disallowedInvocation(
                tool: tool,
                reason: "sub-tool must be a bare name, not a path (`\(sub)`)"
            )
        }
        guard xcrunAllowedSubcommands.contains(sub) else {
            throw ArgumentPolicyError.disallowedInvocation(
                tool: tool,
                reason: "sub-tool `\(sub)` is not allowlisted"
            )
        }
    }

    public static func envVarName(for tool: String) -> String {
        // Restrict to alphanumerics so a malformed tool name can't reach
        // through to invent unexpected env-var names. Anything else gets
        // dropped from the suffix.
        let cleaned = tool.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "GARGANTUA_TOOL_\(cleaned)"
    }

    public func resolve(tool: String) -> URL? {
        // `GARGANTUA_TOOL_<NAME>` overrides let a caller point the resolver at
        // any absolute binary. That is a developer/test convenience, not a
        // release capability — in a signed release build it would be an
        // arbitrary-exec foothold, so it is DEBUG-only. Mirrors the
        // `GARGANTUA_RULES_DIR` / `GARGANTUA_COMMAND_RULES_DIR` treatment.
        #if DEBUG
            let envVar = Self.envVarName(for: tool)
            if let override = environment[envVar], !override.isEmpty {
                let expanded = (override as NSString).expandingTildeInPath
                if FileManager.default.isExecutableFile(atPath: expanded) {
                    return URL(fileURLWithPath: expanded)
                }
            }
        #endif

        guard var paths = candidates[tool] else { return nil }
        if ["pnpm", "npm", "yarn"].contains(tool) {
            paths += DeveloperToolBinaryResolver.nodeManagedCandidatePaths(binary: tool)
        }
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
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
        case "go", "tmutil":
            return ["version"]
        default:
            return ["--version"]
        }
    }
}
