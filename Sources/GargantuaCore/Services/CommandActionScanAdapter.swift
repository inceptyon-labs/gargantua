import Foundation

/// Bridges `CommandActionRule`s into the existing `ScanAdapter` pipeline so
/// the same scan view, cleanup confirmation flow, and MCP `scan`/`clean`
/// surfaces can describe them without bespoke plumbing.
///
/// Each loaded command rule that resolves a tool on disk produces a single
/// synthetic `ScanResult` with:
/// - `id` = `commandActionResultIDPrefix` + the rule id (used by
///   `CleanupEngine` to route the cleanup through `CommandActionExecutor`
///   instead of `TrashMover`)
/// - `path` = the command display string, e.g.
///   `"xcrun simctl delete unavailable"` — meaningful in the UI even though
///   it isn't a filesystem path
/// - `safety` = the effective safety from `CommandActionExecutor.preview`
///   (the YAML floor downgraded to `.review` when no dry-run estimate is
///   available)
/// - `size` = the dry-run-estimated bytes, or `0` when no estimate is
///   available; the UI shows "unknown" rather than "0 B" via the
///   `commandActionUnknownBytesTag` discriminator
/// - `tags` always contain `commandActionTag` so consumers that need to
///   special-case command items have an explicit signal
public struct CommandActionScanAdapter: ScanAdapter {
    /// Stable ID prefix that marks a `ScanResult` as backed by a command rule.
    /// Used by `CleanupEngine.cleanSingle(...)` to route through
    /// `CommandActionExecutor`.
    public static let resultIDPrefix = "command-action:"
    public static let tag = "command-action"
    /// Tag stamped on results whose dry-run produced no bytes estimate; the
    /// UI substitutes "unknown size" rather than rendering "0 B".
    public static let unknownBytesTag = "command-action:unknown-bytes"

    private let rules: [CommandActionRule]
    private let executor: any CommandActionExecuting
    private let resolver: CommandActionToolResolver
    private let categories: Set<String>?

    /// - Parameters:
    ///   - rules: Loaded command rules. The adapter filters them against
    ///     the active profile's `categories` set so a profile that doesn't
    ///     include `developer_tool_command` won't surface them.
    ///   - executor: Preview source for each rule. Tests inject a fake.
    ///   - resolver: Used to skip rules whose tool isn't installed without
    ///     bothering the executor (which would throw `toolNotInstalled`).
    ///   - categories: Profile category filter. `nil` means "include all".
    ///     An empty set (explicit) means "include none" — useful for the
    ///     pure-path scan flows that don't want command rules to leak in.
    public init(
        rules: [CommandActionRule],
        executor: any CommandActionExecuting = CommandActionExecutor(),
        resolver: CommandActionToolResolver = CommandActionToolResolver(),
        categories: Set<String>? = nil
    ) {
        self.rules = rules
        self.executor = executor
        self.resolver = resolver
        self.categories = categories
    }

    /// Convenience initializer that loads the bundled command rules via
    /// `CommandActionRuleDirectoryResolver`. Returns an adapter with an
    /// empty rule list (so `scan()` returns `[]`) when the resource bundle
    /// can't be located, rather than throwing — a missing snapshot should
    /// degrade silently so the rest of the scan pipeline still runs.
    public static func loadDefaults(
        executor: any CommandActionExecuting = CommandActionExecutor(),
        resolver: CommandActionToolResolver = CommandActionToolResolver(),
        categories: Set<String>? = nil
    ) -> CommandActionScanAdapter {
        guard let dir = CommandActionRuleDirectoryResolver.resolve(),
              let result = try? CommandActionRuleLoader().loadRules(from: dir) else {
            return CommandActionScanAdapter(
                rules: [],
                executor: executor,
                resolver: resolver,
                categories: categories
            )
        }
        return CommandActionScanAdapter(
            rules: result.rules,
            executor: executor,
            resolver: resolver,
            categories: categories
        )
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        var results: [ScanResult] = []
        for rule in rules {
            // Profile gate: skip rules whose category isn't in the active
            // profile's category set. `nil` means "no filter" (used by MCP
            // scans that haven't applied profile category gating yet).
            if let categories, !categories.contains(rule.category) { continue }
            // Tool-presence gate: skip if the tool isn't installed. Surfacing
            // a "tool not installed" row would be noise in the scan UI.
            guard resolver.resolve(tool: rule.tool) != nil else { continue }

            let preview: CommandActionPreview
            do {
                preview = try executor.preview(rule)
            } catch {
                // A failed preview means the tool was reachable a moment ago
                // but the dry-run blew up. Don't surface the rule; let the
                // user re-scan once the underlying issue is resolved. The
                // error stays in stderr via the executor's contract.
                continue
            }

            results.append(makeScanResult(rule: rule, preview: preview))
        }
        return results
    }

    private func makeScanResult(
        rule: CommandActionRule,
        preview: CommandActionPreview
    ) -> ScanResult {
        var tags = rule.tags
        tags.append(Self.tag)
        if preview.estimatedBytes == nil {
            tags.append(Self.unknownBytesTag)
        }

        return ScanResult(
            id: Self.resultIDPrefix + rule.id,
            name: rule.name,
            path: rule.commandDisplay,
            size: preview.estimatedBytes ?? 0,
            safety: preview.effectiveSafety,
            confidence: rule.confidence,
            explanation: rule.userFacingExplanation,
            source: rule.source,
            lastAccessed: nil,
            category: rule.category,
            tags: tags,
            regenerates: rule.regenerates,
            regenerateCommand: rule.regenerateCommand
        )
    }
}

private extension CommandActionRule {
    var userFacingExplanation: String {
        guard let consequence, !consequence.isEmpty else { return explanation }
        return "\(explanation) Consequence: \(consequence)"
    }
}

extension ScanResult {
    /// Whether this scan result is a `CommandActionRule` synthesized by
    /// `CommandActionScanAdapter`. Consumers that need to special-case
    /// command items should rely on this rather than reaching for the ID
    /// prefix directly.
    public var isCommandAction: Bool {
        id.hasPrefix(CommandActionScanAdapter.resultIDPrefix)
    }

    /// The underlying `CommandActionRule.id`, recovered by stripping the
    /// scan-result ID prefix. Returns `nil` for non-command items.
    public var commandActionRuleID: String? {
        guard isCommandAction else { return nil }
        return String(id.dropFirst(CommandActionScanAdapter.resultIDPrefix.count))
    }
}
