import Foundation

/// Runs read-only developer tool previews. No destructive command is exposed.
public struct DeveloperToolPreviewAdapter: Sendable {
    let resolver: DeveloperToolBinaryResolver
    let runner: any ProcessRunner
    let timeout: TimeInterval
    let cargoHome: URL

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

    static func previewItems(
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

    static func directoryExists(at url: URL) -> Bool {
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
