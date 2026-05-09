import Foundation

/// Supported developer tool cleanup surfaces.
public enum DeveloperTool: String, Codable, Sendable, CaseIterable, Identifiable {
    case homebrew
    case docker

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .docker: "Docker"
        }
    }
}

/// Runtime install/availability state for an external developer tool.
public struct DeveloperToolAvailability: Equatable, Sendable {
    public let tool: DeveloperTool
    public let isInstalled: Bool
    public let executable: URL?
    public let version: String?
    public let error: String?

    public init(
        tool: DeveloperTool,
        isInstalled: Bool,
        executable: URL?,
        version: String? = nil,
        error: String? = nil
    ) {
        self.tool = tool
        self.isInstalled = isInstalled
        self.executable = executable
        self.version = version
        self.error = error
    }
}

/// A read-only preview row returned by a developer tool.
public struct DeveloperToolPreviewItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let tool: DeveloperTool
    public let title: String
    public let detail: String?
    public let reclaimableBytes: Int64?
    public let commandPreview: [String]

    public init(
        id: String,
        tool: DeveloperTool,
        title: String,
        detail: String? = nil,
        reclaimableBytes: Int64? = nil,
        commandPreview: [String]
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.detail = detail
        self.reclaimableBytes = reclaimableBytes
        self.commandPreview = commandPreview
    }
}

/// Read-only preview for a developer tool cleanup/introspection command.
public struct DeveloperToolPreview: Equatable, Sendable {
    public let tool: DeveloperTool
    public let commandPreview: [String]
    public let items: [DeveloperToolPreviewItem]
    public let rawOutput: String
    public let error: String?

    public init(
        tool: DeveloperTool,
        commandPreview: [String],
        items: [DeveloperToolPreviewItem],
        rawOutput: String,
        error: String? = nil
    ) {
        self.tool = tool
        self.commandPreview = commandPreview
        self.items = items
        self.rawOutput = rawOutput
        self.error = error
    }

    /// Sum of per-item reclaimable bytes. Saturates at `Int64.max` on
    /// overflow rather than trapping; the number is only ever surfaced as
    /// a display string, so a capped "a lot" is preferable to a crash.
    public var reclaimableBytes: Int64 {
        items.compactMap(\.reclaimableBytes).reduce(Int64(0)) { acc, next in
            let (sum, overflow) = acc.addingReportingOverflow(next)
            return overflow ? .max : sum
        }
    }
}

public enum DeveloperToolPreviewError: Error, Equatable, LocalizedError {
    case notInstalled(DeveloperTool)
    case commandFailed(tool: DeveloperTool, exitCode: Int32, stderr: String)
    /// Tool is installed but its background daemon isn't running. Currently
    /// only Docker emits this — the CLI is on disk but the engine is down.
    case daemonNotRunning(DeveloperTool)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            "\(tool.displayName) is not installed."
        case .commandFailed(let tool, let exitCode, let stderr):
            "\(tool.displayName) preview failed with exit \(exitCode): \(stderr)"
        case .daemonNotRunning(let tool):
            "\(tool.displayName) daemon is not running."
        }
    }

    /// Stderr-pattern check used by the preview adapter to distinguish
    /// "daemon down" (recoverable: just start the engine) from a true command
    /// failure (e.g. permission denied). Pattern is the canonical Docker CLI
    /// error and has been stable across versions.
    public static func isDockerDaemonNotRunning(stderr: String) -> Bool {
        let needles = [
            "Cannot connect to the Docker daemon",
            "Is the docker daemon running",
        ]
        return needles.contains { stderr.contains($0) }
    }
}

/// Locates Homebrew and Docker binaries without requiring a login shell PATH.
public struct DeveloperToolBinaryResolver: Sendable {
    public static let homebrewEnvVarName = "GARGANTUA_BREW_BIN"
    public static let dockerEnvVarName = "GARGANTUA_DOCKER_BIN"

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
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func envVarName(for tool: DeveloperTool) -> String {
        switch tool {
        case .homebrew: homebrewEnvVarName
        case .docker: dockerEnvVarName
        }
    }

    private static func candidatePaths(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew: homebrewCandidatePaths
        case .docker: dockerCandidatePaths
        }
    }

    private static func versionArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew: ["--version"]
        case .docker: ["--version"]
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

/// Runs read-only developer tool previews. No destructive command is exposed.
public struct DeveloperToolPreviewAdapter: Sendable {
    private let resolver: DeveloperToolBinaryResolver
    private let runner: any ProcessRunner
    private let timeout: TimeInterval

    public init(
        resolver: DeveloperToolBinaryResolver = DeveloperToolBinaryResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        timeout: TimeInterval = 15
    ) {
        self.resolver = resolver
        self.runner = runner
        self.timeout = timeout
    }

    public func availability() -> [DeveloperToolAvailability] {
        DeveloperTool.allCases.map { resolver.availability(for: $0, runner: runner) }
    }

    public func availability(for tool: DeveloperTool) -> DeveloperToolAvailability {
        resolver.availability(for: tool, runner: runner)
    }

    public func preview(_ tool: DeveloperTool) throws -> DeveloperToolPreview {
        guard let executable = resolver.resolve(tool) else {
            throw DeveloperToolPreviewError.notInstalled(tool)
        }

        if tool == .docker {
            return try dockerPreview(executable: executable)
        }

        let arguments = Self.previewArguments(for: tool)
        let output = try runner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )
        guard output.exitCode == 0 else {
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if tool == .docker, DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw DeveloperToolPreviewError.commandFailed(
                tool: tool,
                exitCode: output.exitCode,
                stderr: stderr
            )
        }

        let rawOutput = output.stdout.isEmpty ? output.stderr : output.stdout
        return DeveloperToolPreview(
            tool: tool,
            commandPreview: [executable.path] + arguments,
            items: Self.parsePreview(tool: tool, commandPreview: [executable.path] + arguments, output: rawOutput),
            rawOutput: rawOutput
        )
    }

    private func dockerPreview(executable: URL) throws -> DeveloperToolPreview {
        let structuredArguments = Self.structuredPreviewArguments(for: .docker)
        let structuredOutput = try runner.run(
            executable: executable,
            arguments: structuredArguments,
            timeout: timeout,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )

        if structuredOutput.exitCode == 0 {
            let rawOutput = structuredOutput.stdout.isEmpty ? structuredOutput.stderr : structuredOutput.stdout
            let commandPreview = [executable.path] + structuredArguments
            let items = Self.parseDockerSystemDFJSON(output: rawOutput, commandPreview: commandPreview)
            if !items.isEmpty {
                return DeveloperToolPreview(
                    tool: .docker,
                    commandPreview: commandPreview,
                    items: items,
                    rawOutput: rawOutput
                )
            }
        } else {
            let stderr = structuredOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
        }

        return try legacyDockerPreview(executable: executable)
    }

    private func legacyDockerPreview(executable: URL) throws -> DeveloperToolPreview {
        let arguments = Self.previewArguments(for: .docker)
        let output = try runner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )
        guard output.exitCode == 0 else {
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: stderr) {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw DeveloperToolPreviewError.commandFailed(
                tool: .docker,
                exitCode: output.exitCode,
                stderr: stderr
            )
        }

        let rawOutput = output.stdout.isEmpty ? output.stderr : output.stdout
        let commandPreview = [executable.path] + arguments
        return DeveloperToolPreview(
            tool: .docker,
            commandPreview: commandPreview,
            items: Self.parsePreview(tool: .docker, commandPreview: commandPreview, output: rawOutput),
            rawOutput: rawOutput
        )
    }

    static func previewArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew:
            ["cleanup", "-n"]
        case .docker:
            ["system", "df"]
        }
    }

    static func structuredPreviewArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew:
            previewArguments(for: tool)
        case .docker:
            ["system", "df", "--format", "json"]
        }
    }
}
