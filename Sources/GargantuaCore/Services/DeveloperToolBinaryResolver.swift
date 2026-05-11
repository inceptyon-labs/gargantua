import Foundation

/// Locates supported developer-tool binaries without requiring a login shell PATH.
public struct DeveloperToolBinaryResolver: Sendable {
    public static let homebrewEnvVarName = "GARGANTUA_BREW_BIN"
    public static let dockerEnvVarName = "GARGANTUA_DOCKER_BIN"
    public static let xcrunEnvVarName = "GARGANTUA_XCRUN_BIN"
    public static let pnpmEnvVarName = "GARGANTUA_PNPM_BIN"
    public static let goEnvVarName = "GARGANTUA_GO_BIN"
    public static let cargoEnvVarName = "GARGANTUA_CARGO_BIN"

    static let homebrewCandidatePaths: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/usr/bin/brew",
    ]

    static let dockerCandidatePaths: [String] = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/usr/bin/docker",
    ]

    static let xcrunCandidatePaths: [String] = [
        "/usr/bin/xcrun",
    ]

    static let pnpmCandidatePaths: [String] = [
        "/opt/homebrew/bin/pnpm",
        "/usr/local/bin/pnpm",
        "~/Library/pnpm/pnpm",
        "~/.local/share/pnpm/pnpm",
        "~/.local/bin/pnpm",
        "~/.asdf/shims/pnpm",
        "~/.volta/bin/pnpm",
        "~/.local/share/mise/shims/pnpm",
    ]

    static let goCandidatePaths: [String] = [
        "/opt/homebrew/bin/go",
        "/usr/local/bin/go",
        "/usr/local/go/bin/go",
    ]

    static let cargoCandidatePaths: [String] = [
        "/opt/homebrew/bin/cargo",
        "/usr/local/bin/cargo",
        "~/.cargo/bin/cargo",
        "~/.asdf/shims/cargo",
        "~/.local/share/mise/shims/cargo",
    ]

    private let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
    }

    public func resolve(_ tool: DeveloperTool) -> URL? {
        let envVar = Self.envVarName(for: tool)
        if let override = environment[envVar], !override.isEmpty {
            return executableURL(at: override)
        }

        return Self.candidatePaths(for: tool)
            .lazy
            .compactMap { executableURL(at: $0) }
            .first
    }

    public func availability(
        for tool: DeveloperTool,
        runner: any ProcessRunner = DefaultProcessRunner()
    ) -> DeveloperToolAvailability {
        guard let executable = resolve(tool) else {
            return DeveloperToolAvailability(
                tool: tool,
                isInstalled: false,
                executable: nil,
                error: "\(tool.displayName) executable not found."
            )
        }

        let version = try? runner.run(
            executable: executable,
            arguments: Self.versionArguments(for: tool),
            timeout: 5,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )

        return DeveloperToolAvailability(
            tool: tool,
            isInstalled: true,
            executable: executable,
            version: version.flatMap { Self.parseVersion(tool: tool, output: $0) }
        )
    }

    private func executableURL(at path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
    }

    private static func envVarName(for tool: DeveloperTool) -> String {
        switch tool {
        case .homebrew: homebrewEnvVarName
        case .docker: dockerEnvVarName
        case .xcode: xcrunEnvVarName
        case .pnpm: pnpmEnvVarName
        case .go: goEnvVarName
        case .cargo: cargoEnvVarName
        }
    }

    private static func candidatePaths(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew: homebrewCandidatePaths
        case .docker: dockerCandidatePaths
        case .xcode: xcrunCandidatePaths
        case .pnpm: pnpmCandidatePaths + nodeManagedPnpmCandidatePaths()
        case .go: goCandidatePaths
        case .cargo: cargoCandidatePaths
        }
    }

    static func nodeManagedPnpmCandidatePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let fm = FileManager.default
        let nvmRoot = homeDirectory
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? fm.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return versions
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/pnpm").path }
    }

    private static func versionArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew: ["--version"]
        case .docker: ["--version"]
        case .xcode: ["xcodebuild", "-version"]
        case .pnpm: ["--version"]
        case .go: ["version"]
        case .cargo: ["--version"]
        }
    }

    private static func parseVersion(tool: DeveloperTool, output: ProcessOutput) -> String? {
        guard output.exitCode == 0 else { return nil }
        let text = [output.stdout, output.stderr]
            .joined(separator: "\n")
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
