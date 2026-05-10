import Foundation

/// Fixed set of tool-native cleanup operations Gargantua is allowed to run.
public enum DeveloperToolCleanupOperation: String, CaseIterable, Codable, Sendable, Identifiable {
    case homebrewCleanup
    case homebrewPruneAll
    case homebrewAutoremove
    case dockerImagePrune
    case dockerContainerPrune
    case dockerVolumePrune
    case dockerBuilderPrune
    case dockerSystemPrune
    case xcodeDeleteUnavailableSimulators
    case pnpmStorePrune
    case goCleanCache
    case goCleanModcache
    case cargoPurgeExtractedCaches

    public var id: String { rawValue }

    public var tool: DeveloperTool {
        switch self {
        case .homebrewCleanup, .homebrewPruneAll, .homebrewAutoremove:
            .homebrew
        case .dockerImagePrune, .dockerContainerPrune, .dockerVolumePrune, .dockerBuilderPrune, .dockerSystemPrune:
            .docker
        case .xcodeDeleteUnavailableSimulators:
            .xcode
        case .pnpmStorePrune:
            .pnpm
        case .goCleanCache, .goCleanModcache:
            .go
        case .cargoPurgeExtractedCaches:
            .cargo
        }
    }

    public var label: String {
        switch self {
        case .homebrewCleanup: "Cleanup old versions"
        case .homebrewPruneAll: "Aggressive cache cleanup"
        case .homebrewAutoremove: "Autoremove unused dependencies"
        case .dockerImagePrune: "Prune dangling images"
        case .dockerContainerPrune: "Prune stopped containers"
        case .dockerVolumePrune: "Prune unused volumes"
        case .dockerBuilderPrune: "Prune build cache"
        case .dockerSystemPrune: "System prune"
        case .xcodeDeleteUnavailableSimulators: "Delete unavailable simulators"
        case .pnpmStorePrune: "Prune unreferenced store packages"
        case .goCleanCache: "Clean build cache"
        case .goCleanModcache: "Clean module download cache"
        case .cargoPurgeExtractedCaches: "Purge extracted Cargo caches"
        }
    }

    public var detail: String {
        switch self {
        case .homebrewCleanup:
            "Runs Homebrew's dependency-aware cleanup for old formula versions."
        case .homebrewPruneAll:
            "Runs Homebrew cleanup with all cached downloads eligible."
        case .homebrewAutoremove:
            "Removes Homebrew dependencies no installed formula needs."
        case .dockerImagePrune:
            "Removes dangling Docker images."
        case .dockerContainerPrune:
            "Removes stopped Docker containers."
        case .dockerVolumePrune:
            "Removes Docker volumes not used by a container."
        case .dockerBuilderPrune:
            "Removes Docker builder cache."
        case .dockerSystemPrune:
            "Runs Docker's composite prune for unused images, containers, networks, and build cache."
        case .xcodeDeleteUnavailableSimulators:
            "Runs simctl's cleanup for simulator devices whose runtimes are no longer installed."
        case .pnpmStorePrune:
            "Asks pnpm to remove packages no current project store reference needs."
        case .goCleanCache:
            "Removes compiled package artifacts from Go's shared build cache."
        case .goCleanModcache:
            "Removes Go's shared downloaded module cache."
        case .cargoPurgeExtractedCaches:
            "Removes Cargo's extracted registry sources and git dependency checkouts from Cargo home."
        }
    }

    public var riskDetail: String? {
        switch self {
        case .dockerVolumePrune:
            "Docker volumes can hold databases, uploads, and project state that cannot be rebuilt from images."
        case .dockerSystemPrune:
            "This broad Docker prune can remove stopped-container state, untagged images, networks, and build cache; expect rebuilds or re-pulls."
        case .homebrewPruneAll:
            "This removes all cached Homebrew downloads, including files you may want offline."
        case .goCleanModcache:
            "Future Go builds may need network access to re-download modules, and offline projects can fail until dependencies are fetched again."
        case .cargoPurgeExtractedCaches:
            "Cargo will recreate these extracted sources on demand. Rebuilds may pause to unpack crates or re-check out git dependencies."
        default:
            nil
        }
    }

    public var estimateUnavailableDetail: String {
        "This command does not report an exact reclaim estimate; Gargantua records 0 bytes in the audit entry when the tool cannot provide one."
    }

    public var confirmationExplanation: String {
        [detail, riskDetail].compactMap(\.self).joined(separator: " ")
    }

    public var safety: SafetyLevel {
        switch self {
        case .homebrewPruneAll, .dockerVolumePrune, .dockerSystemPrune:
            .protected_
        default:
            .review
        }
    }

    public var arguments: [String] {
        switch self {
        case .homebrewCleanup:
            ["cleanup"]
        case .homebrewPruneAll:
            ["cleanup", "--prune=all"]
        case .homebrewAutoremove:
            ["autoremove"]
        case .dockerImagePrune:
            ["image", "prune", "--force"]
        case .dockerContainerPrune:
            ["container", "prune", "--force"]
        case .dockerVolumePrune:
            ["volume", "prune", "--force"]
        case .dockerBuilderPrune:
            ["builder", "prune", "--force"]
        case .dockerSystemPrune:
            ["system", "prune", "--force"]
        case .xcodeDeleteUnavailableSimulators:
            ["simctl", "delete", "unavailable"]
        case .pnpmStorePrune:
            ["store", "prune"]
        case .goCleanCache:
            ["clean", "-cache"]
        case .goCleanModcache:
            ["clean", "-modcache"]
        case .cargoPurgeExtractedCaches:
            ["cache", "purge-extracted"]
        }
    }

    public func commandPreview(executable: URL) -> [String] {
        [executable.path] + arguments
    }

    public var commandName: String {
        ([commandDisplayName] + arguments).joined(separator: " ")
    }

    private var commandDisplayName: String {
        switch tool {
        case .homebrew: "brew"
        case .docker: "docker"
        case .xcode: "xcrun"
        case .pnpm: "pnpm"
        case .go: "go"
        case .cargo: "cargo"
        }
    }

    public func isApplicable(to preview: DeveloperToolPreview) -> Bool {
        guard preview.tool == tool else { return false }
        switch self {
        case .homebrewCleanup:
            return preview.reclaimableBytes > 0 || !preview.items.isEmpty
        case .homebrewPruneAll, .homebrewAutoremove:
            return true
        case .dockerImagePrune, .dockerContainerPrune, .dockerVolumePrune, .dockerBuilderPrune, .dockerSystemPrune:
            return (estimatedReclaimableBytes(in: preview) ?? 0) > 0
        case .xcodeDeleteUnavailableSimulators:
            return !preview.items.isEmpty
        case .pnpmStorePrune:
            return preview.items.contains { $0.id == "pnpm-store" }
        case .goCleanCache:
            return preview.items.contains { $0.id == "go-build-cache" }
        case .goCleanModcache:
            return preview.items.contains { $0.id == "go-module-cache" }
        case .cargoPurgeExtractedCaches:
            return preview.items.contains { Self.cargoPurgeTargetIDs.contains($0.id) }
        }
    }

    public func estimatedReclaimableBytes(in preview: DeveloperToolPreview) -> Int64? {
        guard preview.tool == tool else { return nil }
        switch self {
        case .homebrewCleanup, .homebrewPruneAll:
            return preview.reclaimableBytes
        case .homebrewAutoremove:
            return nil
        case .dockerImagePrune:
            return dockerBytes(in: preview, titles: ["Images"])
        case .dockerContainerPrune:
            return dockerBytes(in: preview, titles: ["Containers"])
        case .dockerVolumePrune:
            return dockerBytes(in: preview, titles: ["Volumes", "Local Volumes"])
        case .dockerBuilderPrune:
            return dockerBytes(in: preview, titles: ["Build Cache"])
        case .dockerSystemPrune:
            return sumSaturating([
                dockerBytes(in: preview, titles: ["Images"]) ?? 0,
                dockerBytes(in: preview, titles: ["Containers"]) ?? 0,
                dockerBytes(in: preview, titles: ["Build Cache"]) ?? 0,
            ])
        case .xcodeDeleteUnavailableSimulators:
            return previewKnownBytes(preview)
        case .pnpmStorePrune:
            return previewBytes(in: preview, itemID: "pnpm-store")
        case .goCleanCache:
            return previewBytes(in: preview, itemID: "go-build-cache")
        case .goCleanModcache:
            return previewBytes(in: preview, itemID: "go-module-cache")
        case .cargoPurgeExtractedCaches:
            return previewKnownBytes(preview)
        }
    }

    static let cargoPurgeTargetIDs: Set<String> = [
        "cargo-registry-src",
        "cargo-git-checkouts",
    ]

    private func dockerBytes(in preview: DeveloperToolPreview, titles: Set<String>) -> Int64? {
        preview.items.first { titles.contains($0.title) }?.reclaimableBytes
    }

    private func previewBytes(in preview: DeveloperToolPreview, itemID: String) -> Int64? {
        guard let item = preview.items.first(where: { $0.id == itemID }) else { return nil }
        return item.reclaimableBytes ?? 0
    }

    private func sumSaturating(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { acc, value in
            let (sum, overflow) = acc.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    private func previewKnownBytes(_ preview: DeveloperToolPreview) -> Int64? {
        let values = preview.items.compactMap(\.reclaimableBytes)
        guard !values.isEmpty else { return nil }
        return sumSaturating(values)
    }
}

public struct DeveloperToolExecutionResult: Equatable, Sendable {
    public let operation: DeveloperToolCleanupOperation
    public let commandPreview: [String]
    public let output: ProcessOutput
    public let estimatedBytesFreed: Int64

    public init(
        operation: DeveloperToolCleanupOperation,
        commandPreview: [String],
        output: ProcessOutput,
        estimatedBytesFreed: Int64
    ) {
        self.operation = operation
        self.commandPreview = commandPreview
        self.output = output
        self.estimatedBytesFreed = estimatedBytesFreed
    }
}

public enum DeveloperToolExecutionError: Error, Equatable, LocalizedError {
    case notInstalled(DeveloperTool)
    case commandFailed(operation: DeveloperToolCleanupOperation, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            "\(tool.displayName) is not installed."
        case .commandFailed(let operation, let exitCode, let stderr):
            "\(operation.label) failed with exit \(exitCode): \(stderr)"
        }
    }
}

public protocol DeveloperToolAuditRecording: Sendable {
    func write(_ entry: AuditEntry) throws
}

extension AuditWriter: DeveloperToolAuditRecording {}

public struct DeveloperToolExecutionAdapter: Sendable {
    private let resolver: DeveloperToolBinaryResolver
    private let runner: any ProcessRunner
    private let auditRecorder: any DeveloperToolAuditRecording
    private let timeout: TimeInterval

    public init(
        resolver: DeveloperToolBinaryResolver = DeveloperToolBinaryResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        auditRecorder: any DeveloperToolAuditRecording = AuditWriter(),
        timeout: TimeInterval = 60
    ) {
        self.resolver = resolver
        self.runner = runner
        self.auditRecorder = auditRecorder
        self.timeout = timeout
    }

    public func execute(
        _ operation: DeveloperToolCleanupOperation,
        preview: DeveloperToolPreview,
        confirmationMethod: ConfirmationTier
    ) throws -> DeveloperToolExecutionResult {
        guard let executable = resolver.resolve(operation.tool) else {
            throw DeveloperToolExecutionError.notInstalled(operation.tool)
        }
        if operation == .cargoPurgeExtractedCaches {
            return try executeCargoCachePurge(
                operation,
                preview: preview,
                executable: executable,
                confirmationMethod: confirmationMethod
            )
        }

        let output = try runner.run(
            executable: executable,
            arguments: operation.arguments,
            timeout: timeout,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )
        guard output.exitCode == 0 else {
            throw DeveloperToolExecutionError.commandFailed(
                operation: operation,
                exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let estimatedBytes = operation.estimatedReclaimableBytes(in: preview) ?? 0
        let commandPreview = operation.commandPreview(executable: executable)
        let entry = AuditEntry(
            tool: "developer-tools",
            command: operation.commandName,
            files: [],
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: estimatedBytes
        )
        try auditRecorder.write(entry)

        return DeveloperToolExecutionResult(
            operation: operation,
            commandPreview: commandPreview,
            output: output,
            estimatedBytesFreed: estimatedBytes
        )
    }

    private func executeCargoCachePurge(
        _ operation: DeveloperToolCleanupOperation,
        preview: DeveloperToolPreview,
        executable: URL,
        confirmationMethod: ConfirmationTier
    ) throws -> DeveloperToolExecutionResult {
        let targets = preview.items.compactMap(Self.cargoPurgeTarget)
        let estimatedBytes = operation.estimatedReclaimableBytes(in: preview) ?? 0
        var removedFiles: [AuditFile] = []

        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target.url)
            removedFiles.append(AuditFile(path: target.path, size: target.bytes))
        }

        let commandPreview = operation.commandPreview(executable: executable)
        let entry = AuditEntry(
            tool: "developer-tools",
            command: operation.commandName,
            files: removedFiles,
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: estimatedBytes
        )
        try auditRecorder.write(entry)

        let stdout = removedFiles.isEmpty
            ? "No Cargo extracted caches found.\n"
            : removedFiles.map { "Removed \($0.path)" }.joined(separator: "\n") + "\n"
        return DeveloperToolExecutionResult(
            operation: operation,
            commandPreview: commandPreview,
            output: ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
            estimatedBytesFreed: estimatedBytes
        )
    }

    private struct CargoPurgeTarget {
        let url: URL
        let path: String
        let bytes: Int64
    }

    private static func cargoPurgeTarget(item: DeveloperToolPreviewItem) -> CargoPurgeTarget? {
        guard DeveloperToolCleanupOperation.cargoPurgeTargetIDs.contains(item.id),
              let detail = item.detail,
              detail.hasPrefix("/") else {
            return nil
        }

        let url = URL(fileURLWithPath: detail).standardizedFileURL
        guard url.path.hasSuffix("/registry/src") || url.path.hasSuffix("/git/checkouts") else {
            return nil
        }
        return CargoPurgeTarget(url: url, path: url.path, bytes: item.reclaimableBytes ?? 0)
    }
}
