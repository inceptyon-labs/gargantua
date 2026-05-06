import Foundation

/// A bytes-reclaimable estimator for a single command-action rule's
/// dry-run output. Returns nil when the tool's dry-run output cannot be
/// translated into a byte estimate — the executor then downgrades the
/// effective safety to `.review` per the Trust Layer requirement.
public typealias CommandActionBytesEstimator = @Sendable (
    _ rule: CommandActionRule,
    _ dryRunOutput: ProcessOutput
) -> Int64?

/// Read-only preview of a command-action rule, capturing the bytes the
/// command is expected to reclaim (when a dry-run estimator is available)
/// and the effective safety classification after Trust Layer downgrades.
public struct CommandActionPreview: Equatable, Sendable {
    public let rule: CommandActionRule
    /// Effective safety after applying the "no dry-run estimate ⇒ review"
    /// rule. `effectiveSafety` is what the cleanup confirmation flow uses;
    /// `rule.safety` is the YAML-declared floor.
    public let effectiveSafety: SafetyLevel
    public let estimatedBytes: Int64?
    public let toolVersion: String?
    public let dryRunOutput: ProcessOutput?

    public init(
        rule: CommandActionRule,
        effectiveSafety: SafetyLevel,
        estimatedBytes: Int64?,
        toolVersion: String?,
        dryRunOutput: ProcessOutput?
    ) {
        self.rule = rule
        self.effectiveSafety = effectiveSafety
        self.estimatedBytes = estimatedBytes
        self.toolVersion = toolVersion
        self.dryRunOutput = dryRunOutput
    }
}

public struct CommandActionExecutionResult: Equatable, Sendable {
    public let rule: CommandActionRule
    public let commandPreview: [String]
    public let output: ProcessOutput
    public let estimatedBytesFreed: Int64
    public let toolVersion: String?

    public init(
        rule: CommandActionRule,
        commandPreview: [String],
        output: ProcessOutput,
        estimatedBytesFreed: Int64,
        toolVersion: String?
    ) {
        self.rule = rule
        self.commandPreview = commandPreview
        self.output = output
        self.estimatedBytesFreed = estimatedBytesFreed
        self.toolVersion = toolVersion
    }
}

public enum CommandActionExecutionError: Error, Equatable, LocalizedError {
    case toolNotInstalled(tool: String)
    case commandFailed(ruleID: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotInstalled(let tool):
            "Tool \"\(tool)\" is not installed."
        case .commandFailed(let ruleID, let exitCode, let stderr):
            "Command rule \"\(ruleID)\" failed with exit \(exitCode): \(stderr)"
        }
    }
}

/// Protocol the executor implements so call sites can stub a fake.
public protocol CommandActionExecuting: Sendable {
    func preview(_ rule: CommandActionRule) throws -> CommandActionPreview
    func execute(
        _ rule: CommandActionRule,
        preview: CommandActionPreview,
        confirmationMethod: ConfirmationTier
    ) throws -> CommandActionExecutionResult
}

/// Default executor for `CommandActionRule`s. Resolves the tool's binary,
/// runs the (optional) dry-run command, runs the destructive command, and
/// writes a `kind: command` audit entry capturing the full evidence model.
///
/// Bytes-reclaimable estimation is delegated to a registry of per-rule
/// estimators (`bytesEstimators`). When a rule has no estimator or its
/// estimator returns nil, the preview's `effectiveSafety` is downgraded to
/// `.review` even if YAML declared `safe`. This implements the Trust Layer
/// rule "no dry-run means review, not safe."
public struct CommandActionExecutor: CommandActionExecuting {
    private let resolver: CommandActionToolResolver
    private let runner: any ProcessRunner
    private let auditRecorder: any DeveloperToolAuditRecording
    private let bytesEstimators: [String: CommandActionBytesEstimator]

    public init(
        resolver: CommandActionToolResolver = CommandActionToolResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        auditRecorder: any DeveloperToolAuditRecording = AuditWriter(),
        bytesEstimators: [String: CommandActionBytesEstimator] = [:]
    ) {
        self.resolver = resolver
        self.runner = runner
        self.auditRecorder = auditRecorder
        self.bytesEstimators = bytesEstimators
    }

    public func preview(_ rule: CommandActionRule) throws -> CommandActionPreview {
        guard let executable = resolver.resolve(tool: rule.tool) else {
            throw CommandActionExecutionError.toolNotInstalled(tool: rule.tool)
        }

        let toolVersion = resolver.captureVersion(tool: rule.tool, executable: executable, runner: runner)

        guard let dryRunArgs = rule.dryRunArguments else {
            // No dry-run path declared — bytes estimate unavailable, safety
            // downgrades to review per the Trust Layer rule.
            return CommandActionPreview(
                rule: rule,
                effectiveSafety: downgrade(rule.safety),
                estimatedBytes: nil,
                toolVersion: toolVersion,
                dryRunOutput: nil
            )
        }

        let output = try runner.run(
            executable: executable,
            arguments: dryRunArgs,
            timeout: rule.preconditions.timeoutSeconds,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )
        // Tools differ in how they signal "nothing to do" via dry-run exit
        // codes (some return non-zero when there's nothing pruneable). We
        // treat the dry-run as best-effort: any non-zero exit means we
        // couldn't get a byte estimate, so downgrade to review and surface
        // raw output for diagnostics.
        guard output.exitCode == 0 else {
            return CommandActionPreview(
                rule: rule,
                effectiveSafety: downgrade(rule.safety),
                estimatedBytes: nil,
                toolVersion: toolVersion,
                dryRunOutput: output
            )
        }

        let estimator = bytesEstimators[rule.id]
        let estimatedBytes = estimator?(rule, output)
        return CommandActionPreview(
            rule: rule,
            effectiveSafety: estimatedBytes == nil ? downgrade(rule.safety) : rule.safety,
            estimatedBytes: estimatedBytes,
            toolVersion: toolVersion,
            dryRunOutput: output
        )
    }

    public func execute(
        _ rule: CommandActionRule,
        preview: CommandActionPreview,
        confirmationMethod: ConfirmationTier
    ) throws -> CommandActionExecutionResult {
        guard let executable = resolver.resolve(tool: rule.tool) else {
            throw CommandActionExecutionError.toolNotInstalled(tool: rule.tool)
        }

        let output = try runner.run(
            executable: executable,
            arguments: rule.arguments,
            timeout: rule.preconditions.timeoutSeconds,
            maxCapturedBytes: DefaultProcessRunner.defaultMaxCapturedBytes
        )
        guard output.exitCode == 0 else {
            throw CommandActionExecutionError.commandFailed(
                ruleID: rule.id,
                exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let estimatedBytes = preview.estimatedBytes ?? 0
        let commandPreview = [executable.path] + rule.arguments
        let entry = AuditEntry(
            tool: "command-action",
            command: rule.commandDisplay,
            files: [],
            safetyLevel: preview.effectiveSafety,
            confirmationMethod: confirmationMethod,
            cleanupMethod: .toolNative,
            bytesFreed: estimatedBytes,
            kind: .command,
            commandToolVersion: preview.toolVersion,
            commandExitCode: output.exitCode,
            commandArguments: rule.arguments
        )
        try auditRecorder.write(entry)

        return CommandActionExecutionResult(
            rule: rule,
            commandPreview: commandPreview,
            output: output,
            estimatedBytesFreed: estimatedBytes,
            toolVersion: preview.toolVersion
        )
    }

    /// Trust Layer downgrade: `safe` rules without a dry-run estimate become
    /// `review`, ensuring the user is asked to confirm via the summary
    /// dialog. `review` and `protected` (which the parser disallows for
    /// command rules anyway) pass through unchanged.
    private func downgrade(_ safety: SafetyLevel) -> SafetyLevel {
        safety == .safe ? .review : safety
    }
}
