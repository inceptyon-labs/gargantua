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
    case npmCacheClean
    case yarnCacheClean
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
        case .npmCacheClean:
            .npm
        case .yarnCacheClean:
            .yarn
        case .goCleanCache, .goCleanModcache:
            .go
        case .cargoPurgeExtractedCaches:
            .cargo
        }
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

        let estimatedBytes = operation.estimatedReclaimableBytes(in: preview) ?? 0
        let commandPreview = operation.commandPreview(executable: executable)
        let entryID = UUID()

        // Intent record before the tool runs. `brew cleanup` and the docker
        // prunes delete on their own schedule and give us no progress signal;
        // if we die while one is mid-flight the disk has already changed and
        // nothing else on the system would say so.
        try auditRecorder.write(AuditEntry(
            id: entryID,
            tool: "developer-tools",
            command: operation.commandName,
            files: [],
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            status: .attempted
        ))

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

        try auditRecorder.write(AuditEntry(
            id: entryID,
            tool: "developer-tools",
            command: operation.commandName,
            files: [],
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: estimatedBytes,
            status: .completed
        ))

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
        let commandPreview = operation.commandPreview(executable: executable)
        let entryID = UUID()

        // The intent record names the candidate targets, not the removed ones:
        // it is written before the first removeItem, so "what we were about to
        // delete" is all that is known — and all that survives a crash partway
        // through the loop.
        try auditRecorder.write(AuditEntry(
            id: entryID,
            tool: "developer-tools",
            command: operation.commandName,
            files: targets.map { AuditFile(path: $0.path, size: $0.bytes) },
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            status: .attempted
        ))

        var removedFiles: [AuditFile] = []

        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            // TOCTOU guard: skip any target whose parent chain now resolves
            // through a symlink, so a swapped path can't redirect removeItem
            // onto an unselected file. Preview items carry no scan-time
            // ancestry recording, so any symlink ancestor is rejected.
            guard SymlinkSwapGuard.isUnchanged(target.url, scanTimeResolvedParent: nil) else { continue }
            try FileManager.default.removeItem(at: target.url)
            removedFiles.append(AuditFile(path: target.path, size: target.bytes))
        }

        try auditRecorder.write(AuditEntry(
            id: entryID,
            tool: "developer-tools",
            command: operation.commandName,
            files: removedFiles,
            safetyLevel: operation.safety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: estimatedBytes,
            status: .completed
        ))

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
