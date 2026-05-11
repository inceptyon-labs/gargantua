import Foundation

extension NativeScanAdapter {
    struct RuleEvaluation: Sendable {
        var results: [ScanResult]
        var warnings: [String]
    }

    /// Per-scan evaluation context. Threaded through `evaluate` so it can be
    /// passed in a single argument instead of six positional parameters; the
    /// constituent fields are read-only for the duration of one rule pass.
    struct EvaluationContext: Sendable {
        let classifier: SafetyClassifier
        let profile: CleanupProfile
        let expander: PathExpander
        let scanRoots: [URL]
        let processChecker: any RunningProcessChecking
        let availableEcosystems: Set<RuleEcosystem>
    }

    static func evaluate(
        rule: ScanRule,
        context: EvaluationContext,
        onSizing: @Sendable (String) -> Void = { _ in }
    ) -> RuleEvaluation {
        if NativeRuleGuardEvaluator.shouldSkipRule(rule: rule, processChecker: context.processChecker) {
            return RuleEvaluation(results: [], warnings: [])
        }

        let fileManager = FileManager.default
        var out: [ScanResult] = []
        var warnings: [String] = []
        var counter = 0

        for pattern in rule.paths {
            let isGlob = pattern.contains("*")
            let resolvedPaths: [String]

            if isGlob {
                // Skip `**/<leaf>` patterns whose ecosystem has no signal anywhere in the
                // scan roots — the walk would just hit the depth cap and emit a noisy
                // "0 partial results" warning. Patterns with concrete prefixes or that
                // map to no specific ecosystem still run unchanged.
                if let required = RulePatternEcosystem.required(for: pattern),
                   !context.availableEcosystems.contains(required) {
                    continue
                }

                let expansion = context.expander.expand(pattern: pattern, roots: context.scanRoots)
                resolvedPaths = expansion.paths
                // Only warn for global resource caps (entries / time). Depth cap is
                // branch-local after pruning — it just means some unrelated sub-tree
                // bottomed out; the user isn't missing actionable matches.
                if expansion.hitCap, !resolvedPaths.isEmpty,
                   let reason = expansion.capReason, reason != "depth" {
                    warnings.append(
                        "Stopped scanning \(rule.name): \(reason) reached. \(resolvedPaths.count) partial results."
                    )
                }
            } else {
                let expanded = expandTilde(pattern)
                resolvedPaths = fileManager.fileExists(atPath: expanded) ? [expanded] : []
            }

            for path in resolvedPaths {
                // A rule with a `pattern:` field selects individual files inside the resolved
                // directory (e.g. `~/Downloads` + `*.dmg`). A literal path with `exclude`
                // patterns enumerates immediate children and skips the excluded ones.
                // Everything else treats the resolved path itself as one result.
                let needsChildEnumeration = rule.pattern != nil || (!isGlob && !rule.exclude.isEmpty)

                if needsChildEnumeration {
                    enumerateChildren(
                        at: path,
                        rule: rule,
                        classifier: context.classifier,
                        profile: context.profile,
                        counter: &counter,
                        fileManager: fileManager,
                        onSizing: onSizing,
                        into: &out
                    )
                } else {
                    if !rule.exclude.isEmpty,
                       isExcluded(child: URL(fileURLWithPath: path), excludes: rule.exclude) {
                        continue
                    }
                    onSizing(path)
                    if let result = makeResult(
                        rule: rule,
                        path: path,
                        counter: &counter,
                        classifier: context.classifier,
                        profile: context.profile
                    ) {
                        out.append(result)
                    }
                }
            }
        }

        return RuleEvaluation(results: out, warnings: warnings)
    }

    // swiftlint:disable:next function_parameter_count
    private static func enumerateChildren(
        at path: String,
        rule: ScanRule,
        classifier: SafetyClassifier,
        profile: CleanupProfile,
        counter: inout Int,
        fileManager: FileManager,
        onSizing: @Sendable (String) -> Void,
        into out: inout [ScanResult]
    ) {
        let url = URL(fileURLWithPath: path)
        let children = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            if let filePattern = rule.pattern,
               !fnmatch(pattern: filePattern, name: child.lastPathComponent) {
                continue
            }
            if !rule.exclude.isEmpty, isExcluded(child: child, excludes: rule.exclude) { continue }
            onSizing(child.path)
            if let result = makeResult(
                rule: rule,
                path: child.path,
                counter: &counter,
                classifier: classifier,
                profile: profile
            ) {
                out.append(result)
            }
        }
    }

    private static func makeResult(
        rule: ScanRule,
        path: String,
        counter: inout Int,
        classifier: SafetyClassifier,
        profile: CleanupProfile
    ) -> ScanResult? {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        let lastAccessed = values?.contentAccessDate ?? values?.contentModificationDate
        let modifiedAt = values?.contentModificationDate

        guard NativeRuleGuardEvaluator.matchesRuleFilters(
            rule: rule,
            lastAccessed: lastAccessed,
            modifiedAt: modifiedAt
        ),
            !NativeRuleGuardEvaluator.isGuardedCandidate(rule: rule, candidatePath: path) else {
            return nil
        }

        let size: Int64
        if isDirectory {
            size = DirectorySizeScanner.directorySize(at: path).totalSize
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard size > 0 else { return nil }
        if let minSize = rule.minSize, size < minSize { return nil }

        let displayName = Self.displayName(forRule: rule, path: path)

        let base = ScanResult(
            id: "\(rule.id)-\(counter)",
            name: displayName,
            path: path,
            size: size,
            safety: rule.safety,
            confidence: rule.confidence,
            explanation: rule.explanation,
            source: rule.source,
            lastAccessed: lastAccessed,
            category: rule.category,
            tags: rule.tags,
            regenerates: rule.regenerates,
            regenerateCommand: rule.regenerateCommand
        )
        counter += 1

        let classified = classifier.classify(result: base, rule: rule, profile: profile)
        return ScanResult(
            id: base.id,
            name: base.name,
            path: base.path,
            size: base.size,
            safety: classified.safety,
            confidence: classified.confidence,
            explanation: classified.explanation,
            source: base.source,
            lastAccessed: base.lastAccessed,
            category: base.category,
            tags: base.tags,
            regenerates: base.regenerates,
            regenerateCommand: base.regenerateCommand
        )
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    /// Pick a human-readable display name for a result.
    ///
    /// - If `path` matches one of the rule's declared paths verbatim, use the rule
    ///   name alone (e.g. "User Library Caches").
    /// - If `path` is a child of a declared path (enumerated via `exclude` filtering),
    ///   append the child's own name (e.g. "User Library Caches — com.apple.Safari").
    /// - For glob-expanded paths where the matched segment is a common repeated name
    ///   like `node_modules`, append the parent directory's name instead so each
    ///   match is distinguishable (e.g. "Node Modules — my-project").
    private static func displayName(forRule rule: ScanRule, path: String) -> String {
        if rule.paths.contains(where: { expandTilde($0) == path }) {
            return rule.name
        }
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent

        // Repeated leaf names (node_modules, target, DerivedData, .venv, etc.) tell the
        // user nothing on their own — disambiguate with the parent directory name.
        let repeatedLeafNames: Set<String> = [
            "node_modules", "target", "DerivedData", "build", "dist",
            ".venv", "venv", ".gradle", "vendor", ".next", ".nuxt",
        ]
        if repeatedLeafNames.contains(last), !parent.isEmpty {
            return "\(rule.name) — \(parent)"
        }
        return "\(rule.name) — \(last)"
    }

    private static func isExcluded(child: URL, excludes: [String]) -> Bool {
        let name = child.lastPathComponent
        let fullPath = child.path
        for pattern in excludes {
            // Patterns come in forms like "*/Google", "Google", "*cache*".
            // Strip a leading "*/" since we apply against child names.
            var p = pattern
            if p.hasPrefix("*/") { p.removeFirst(2) }
            if fnmatch(pattern: p, name: name) || fnmatch(pattern: pattern, name: fullPath) {
                return true
            }
        }
        return false
    }

    /// Minimal fnmatch — supports `*` only. Good enough for cleanup rule excludes.
    private static func fnmatch(pattern: String, name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = name.startIndex
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i == 0 && !pattern.hasPrefix("*") {
                guard name.hasPrefix(part) else { return false }
                cursor = name.index(cursor, offsetBy: part.count)
            } else if i == parts.count - 1 && !pattern.hasSuffix("*") {
                return name[cursor...].hasSuffix(part)
            } else {
                guard let range = name.range(of: part, range: cursor ..< name.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}
