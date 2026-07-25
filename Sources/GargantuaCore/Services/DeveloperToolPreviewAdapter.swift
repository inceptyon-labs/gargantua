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
        let base = DeveloperToolPreview(
            tool: tool,
            commandPreview: commandPreview,
            items: Self.previewItems(tool: tool, commandPreview: commandPreview, output: rawOutput),
            rawOutput: rawOutput
        )
        guard tool == .homebrew else { return base }
        return DeveloperToolPreview(
            tool: base.tool,
            commandPreview: base.commandPreview,
            items: base.items,
            rawOutput: base.rawOutput,
            error: base.error,
            homebrewAutoremove: homebrewAutoremovePreview(executable: executable)
        )
    }

    func homebrewAutoremovePreview(executable: URL) -> HomebrewAutoremovePreview? {
        guard let dry = try? runner.run(
            executable: executable, arguments: ["autoremove", "-n"],
            timeout: timeout, maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        ), dry.exitCode == 0 else { return nil }

        let output = dry.stdout.isEmpty ? dry.stderr : dry.stdout
        let names = Self.parseHomebrewAutoremoveFormulae(output)
        guard !names.isEmpty else { return HomebrewAutoremovePreview(formulae: []) }

        guard let cellar = try? runner.run(
            executable: executable, arguments: ["--cellar"],
            timeout: timeout, maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        ), cellar.exitCode == 0 else { return nil }
        let rootPath = cellar.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rootPath.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: rootPath)
        let command = [executable.path, "autoremove"]

        let formulae = names.map { name -> DeveloperToolPreviewItem in
            let dir = root.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            let bytes: Int64? = (Self.isSafeCacheRoot(at: dir) && Self.directoryExists(at: dir))
                ? Self.directorySize(at: dir) : nil
            return DeveloperToolPreviewItem(
                id: "homebrew-autoremove-\(name)",
                tool: .homebrew,
                title: name,
                detail: dir.path,
                reclaimableBytes: bytes,
                commandPreview: command
            )
        }
        return HomebrewAutoremovePreview(formulae: formulae)
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
        case .npm:
            ["config", "get", "cache"]
        case .yarn:
            ["cache", "dir"]
        case .go:
            ["env", "-json", "GOCACHE", "GOMODCACHE"]
        case .cargo:
            ["--version"]
        }
    }

    static func structuredPreviewArguments(for tool: DeveloperTool) -> [String] {
        switch tool {
        case .homebrew, .xcode, .pnpm, .npm, .yarn, .go, .cargo:
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
            // Deliberately unsized. `pnpm store prune` removes only packages no
            // installed project references, so the store's total is not the
            // reclaimable total — measuring it the way npm/yarn are measured
            // below would promise gigabytes a prune will not free. Leave the
            // estimate unknown so the row renders "—" rather than a number in
            // either wrong direction.
            return parsed
        case .go, .npm, .yarn:
            let sizedIDs: Set<String> = ["go-build-cache", "go-module-cache", "npm-cache", "yarn-cache"]
            return parsed.map { item in
                guard sizedIDs.contains(item.id), let path = item.detail else {
                    return item
                }
                let url = URL(fileURLWithPath: path)
                // A misconfigured tool could report a cache at a filesystem
                // root (`/`, `$HOME`, a volume mount). Refuse to recursively
                // size those — leave the estimate unknown rather than walking
                // the whole disk or silently reporting a bogus partial total.
                guard isSafeCacheRoot(at: url), directoryExists(at: url) else {
                    return item
                }
                return item.withReclaimableBytes(directorySize(at: url))
            }
        default:
            return parsed
        }
    }

    /// Guards recursive sizing against a cache path resolving to a filesystem
    /// root or a home/volume top level. Requires at least three path
    /// components (e.g. `/Users/<me>/.npm`) and rejects the home directory
    /// itself, so a misconfigured tool can't trigger a whole-disk walk.
    static func isSafeCacheRoot(at url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let components = standardized.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3 else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return standardized.path != home
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
