import Foundation

/// Supported developer tool cleanup surfaces.
public enum DeveloperTool: String, Codable, Sendable, CaseIterable, Identifiable {
    case homebrew
    case docker
    case xcode
    case pnpm
    case go
    case cargo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .docker: "Docker"
        case .xcode: "Xcode Simulator"
        case .pnpm: "pnpm"
        case .go: "Go"
        case .cargo: "Cargo"
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

    public var hasKnownReclaimableBytes: Bool {
        items.contains { $0.reclaimableBytes != nil }
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

/// Runs read-only developer tool previews. No destructive command is exposed.
public struct DeveloperToolPreviewAdapter: Sendable {
    private let resolver: DeveloperToolBinaryResolver
    private let runner: any ProcessRunner
    private let timeout: TimeInterval
    private let cargoHome: URL

    public init(
        resolver: DeveloperToolBinaryResolver = DeveloperToolBinaryResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        timeout: TimeInterval = 15,
        cargoHome: URL? = nil
    ) {
        self.resolver = resolver
        self.runner = runner
        self.timeout = timeout
        self.cargoHome = cargoHome ?? Self.defaultCargoHome()
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
        if tool == .cargo {
            return cargoPreview(executable: executable)
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
        let commandPreview = [executable.path] + arguments
        return DeveloperToolPreview(
            tool: tool,
            commandPreview: commandPreview,
            items: Self.previewItems(tool: tool, commandPreview: commandPreview, output: rawOutput),
            rawOutput: rawOutput
        )
    }

    private func dockerPreview(executable: URL) throws -> DeveloperToolPreview {
        let structuredArguments = Self.structuredPreviewArguments(for: .docker)
        let structuredOutput = try runDockerPreviewCommand(
            executable: executable,
            arguments: structuredArguments
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
        let output = try runDockerPreviewCommand(
            executable: executable,
            arguments: arguments
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

    private func runDockerPreviewCommand(
        executable: URL,
        arguments: [String]
    ) throws -> ProcessOutput {
        do {
            return try runner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
            )
        } catch {
            if let runnerError = error as? ProcessRunnerError,
               case .timedOut = runnerError {
                throw DeveloperToolPreviewError.daemonNotRunning(.docker)
            }
            throw error
        }
    }

    static func previewArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew:
            ["cleanup", "-n"]
        case .docker:
            ["system", "df"]
        case .xcode:
            ["simctl", "list", "-j", "devices", "unavailable"]
        case .pnpm:
            ["store", "path"]
        case .go:
            ["env", "-json", "GOCACHE", "GOMODCACHE"]
        case .cargo:
            ["--version"]
        }
    }

    static func structuredPreviewArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew, .xcode, .pnpm, .go, .cargo:
            previewArguments(for: tool)
        case .docker:
            ["system", "df", "--format", "json"]
        }
    }

    private func cargoPreview(executable: URL) -> DeveloperToolPreview {
        let arguments = Self.previewArguments(for: .cargo)
        let commandPreview = [executable.path] + arguments
        let items = Self.cargoCachePreviewItems(cargoHome: cargoHome, commandPreview: commandPreview)
        return DeveloperToolPreview(
            tool: .cargo,
            commandPreview: commandPreview,
            items: items,
            rawOutput: cargoHome.path
        )
    }

    static func defaultCargoHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CARGO_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return homeDirectory.appendingPathComponent(".cargo", isDirectory: true)
    }

    static func cargoCachePreviewItems(
        cargoHome: URL,
        commandPreview: [String]
    ) -> [DeveloperToolPreviewItem] {
        let registrySrc = cargoHome
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("src", isDirectory: true)
        let gitCheckouts = cargoHome
            .appendingPathComponent("git", isDirectory: true)
            .appendingPathComponent("checkouts", isDirectory: true)

        return [
            cargoCachePreviewItem(
                id: "cargo-registry-src",
                title: "Cargo extracted registry sources",
                url: registrySrc,
                commandPreview: commandPreview
            ),
            cargoCachePreviewItem(
                id: "cargo-git-checkouts",
                title: "Cargo git dependency checkouts",
                url: gitCheckouts,
                commandPreview: commandPreview
            ),
        ].compactMap(\.self)
    }

    private static func previewItems(
        tool: DeveloperTool,
        commandPreview: [String],
        output: String
    ) -> [DeveloperToolPreviewItem] {
        let parsed = parsePreview(tool: tool, commandPreview: commandPreview, output: output)
        switch tool {
        case .pnpm:
            return parsed.map { item in
                item.id == "pnpm-store" ? item.withReclaimableBytes(0) : item
            }
        case .go:
            return parsed.map { item in
                guard ["go-build-cache", "go-module-cache"].contains(item.id),
                      let path = item.detail else {
                    return item
                }
                let url = URL(fileURLWithPath: path)
                let bytes = directoryExists(at: url) ? directorySize(at: url) : 0
                return item.withReclaimableBytes(bytes)
            }
        default:
            return parsed
        }
    }

    private static func cargoCachePreviewItem(
        id: String,
        title: String,
        url: URL,
        commandPreview: [String]
    ) -> DeveloperToolPreviewItem? {
        guard directoryExists(at: url) else { return nil }
        return DeveloperToolPreviewItem(
            id: id,
            tool: .cargo,
            title: title,
            detail: url.path,
            reclaimableBytes: directorySize(at: url),
            commandPreview: commandPreview
        )
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        return enumerator.compactMap { item -> Int64? in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .totalFileAllocatedSizeKey,
                      .fileAllocatedSizeKey,
                  ]),
                  values.isRegularFile == true else {
                return nil
            }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            return Int64(bytes)
        }
        .reduce(Int64(0)) { acc, next in
            let (sum, overflow) = acc.addingReportingOverflow(next)
            return overflow ? .max : sum
        }
    }
}

private extension DeveloperToolPreviewItem {
    func withReclaimableBytes(_ bytes: Int64) -> DeveloperToolPreviewItem {
        DeveloperToolPreviewItem(
            id: id,
            tool: tool,
            title: title,
            detail: detail,
            reclaimableBytes: bytes,
            commandPreview: commandPreview
        )
    }
}
