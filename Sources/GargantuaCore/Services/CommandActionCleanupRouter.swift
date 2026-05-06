import Foundation

/// Bridge between `CleanupEngine` and `CommandActionExecutor`. When the
/// engine is asked to clean a `ScanResult` whose ID was stamped by
/// `CommandActionScanAdapter`, it delegates to this router instead of
/// trashing or deleting the (synthetic) path.
///
/// Resolution flow:
/// 1. Recover the rule ID by stripping the `command-action:` ID prefix.
/// 2. Look up the rule in the in-memory rule index loaded at construction.
/// 3. Run `executor.preview` to (re-)capture tool version / dry-run output.
/// 4. Run `executor.execute`. The executor writes the `kind: command`
///    audit entry; the router only translates the result back into a
///    `CleanupItemResult` so it folds into the engine's batch output.
public struct CommandActionCleanupRouter: Sendable {
    /// Disabled router that fails closed on any command-action item.
    /// Used by tests that don't exercise the command-action path so they
    /// don't have to materialize a real rule index.
    public static let disabled = CommandActionCleanupRouter(
        ruleIndex: [:],
        executor: DisabledExecutor()
    )

    private let ruleIndex: [String: CommandActionRule]
    private let executor: any CommandActionExecuting

    public init(
        rules: [CommandActionRule],
        executor: any CommandActionExecuting = CommandActionExecutor()
    ) {
        self.ruleIndex = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        self.executor = executor
    }

    public init(
        ruleIndex: [String: CommandActionRule],
        executor: any CommandActionExecuting
    ) {
        self.ruleIndex = ruleIndex
        self.executor = executor
    }

    /// Production factory. Loads the bundled command rules via the resource
    /// resolver and uses the default executor (which writes through to
    /// `AuditWriter` and runs real subprocesses).
    public static func production() -> CommandActionCleanupRouter {
        guard let dir = CommandActionRuleDirectoryResolver.resolve(),
              let result = try? CommandActionRuleLoader().loadRules(from: dir) else {
            return .disabled
        }
        return CommandActionCleanupRouter(rules: result.rules)
    }

    /// Run the command rule referenced by `item.id`. Returns a synthetic
    /// `CleanupItemResult` matching the engine's batch shape: `.succeeded`
    /// folds into the success count and per-item `bytesFreed`; `.error`
    /// surfaces the failure reason.
    public func run(item: ScanResult, confirmationMethod: ConfirmationTier) -> CleanupItemResult {
        guard let ruleID = item.commandActionRuleID else {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Internal: scan item is not tagged as a command-action rule."
            )
        }
        guard let rule = ruleIndex[ruleID] else {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Command rule \"\(ruleID)\" not found in the bundled snapshot."
            )
        }

        do {
            let preview = try executor.preview(rule)
            _ = try executor.execute(
                rule,
                preview: preview,
                confirmationMethod: confirmationMethod
            )
            return CleanupItemResult(item: item, succeeded: true)
        } catch let error as CommandActionExecutionError {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: error.errorDescription ?? String(describing: error)
            )
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }
}

private struct DisabledExecutor: CommandActionExecuting {
    func preview(_ rule: CommandActionRule) throws -> CommandActionPreview {
        throw CommandActionExecutionError.toolNotInstalled(tool: rule.tool)
    }

    func execute(
        _ rule: CommandActionRule,
        preview: CommandActionPreview,
        confirmationMethod: ConfirmationTier
    ) throws -> CommandActionExecutionResult {
        throw CommandActionExecutionError.toolNotInstalled(tool: rule.tool)
    }
}
