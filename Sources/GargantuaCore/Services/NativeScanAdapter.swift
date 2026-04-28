import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "NativeScanAdapter")

/// Abstraction over running-process detection for rule guards.
public protocol RunningProcessChecking: Sendable {
    func isRunning(identifier: String) -> Bool
}

/// Production process checker backed by AppKit's running application list.
public struct DefaultRunningProcessChecker: RunningProcessChecking {
    public init() {}

    public func isRunning(identifier: String) -> Bool {
        let needle = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        return NSWorkspace.shared.runningApplications.contains { app in
            let bundleID = app.bundleIdentifier?.lowercased()
            let localizedName = app.localizedName?.lowercased()
            let executableName = app.executableURL?
                .deletingPathExtension()
                .lastPathComponent
                .lowercased()

            return bundleID == needle
                || localizedName == needle
                || executableName == needle
        }
    }
}

/// Native filesystem scanner driven by YAML rules.
///
/// Walks the paths declared in `ScanRule` files, measures sizes, applies
/// profile-aware safety overrides via `SafetyClassifier`, and emits `ScanResult`
/// values.
///
/// This is the Phase 1.5 replacement for the `mo clean` subprocess — the YAML
/// rules were hand-ported from Mole's domain knowledge and are now the
/// authoritative source of truth for what is scannable and how it is classified.
public struct NativeScanAdapter: ScanAdapter {
    private let rules: [ScanRule]
    private let profile: CleanupProfile
    private let classifier: SafetyClassifier
    private let scanRoots: [URL]
    private let expander: PathExpander
    private let processChecker: any RunningProcessChecking
    private let applicabilityChecker: any RuleApplicabilityChecking

    public init(
        rules: [ScanRule],
        profile: CleanupProfile = .light,
        classifier: SafetyClassifier = SafetyClassifier(),
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander(),
        processChecker: any RunningProcessChecking = DefaultRunningProcessChecker(),
        applicabilityChecker: any RuleApplicabilityChecking = DefaultRuleApplicabilityChecker()
    ) {
        self.rules = rules
        self.profile = profile
        self.classifier = classifier
        self.scanRoots = scanRoots
        self.expander = expander
        self.processChecker = processChecker
        self.applicabilityChecker = applicabilityChecker
    }

    /// Build a scanner against the YAML rules shipped with the app.
    ///
    /// Locates the `cleanup_rules` directory via `RuleDirectoryResolver`, loads
    /// every YAML file under it with `RuleLoader`, and returns a configured adapter.
    /// Rule-file parse errors are reported via the returned load result but do not
    /// abort — successfully-parsed rules are still used.
    ///
    /// - Parameters:
    ///   - profile: The cleanup profile whose `categories` gate which rules run.
    ///   - scanRoots: Optional override for the roots that glob patterns expand against.
    ///     `nil` uses `PathExpander.defaultScanRoots()`.
    public static func loadDefaults(
        profile: CleanupProfile,
        scanRoots: [URL]? = nil
    ) throws -> NativeScanAdapter {
        guard let dir = RuleDirectoryResolver.resolve() else {
            throw ScanAdapterError.rulesDirectoryNotFound
        }
        let load = try RuleLoader().loadRules(from: dir)
        for err in load.errors {
            logger.warning("Rule parse error: \(err.localizedDescription, privacy: .public)")
        }
        return NativeScanAdapter(
            rules: load.rules,
            profile: profile,
            scanRoots: scanRoots ?? PathExpander.defaultScanRoots()
        )
    }

    /// Run the scan against the configured rules and profile.
    ///
    /// - Parameter progress: Optional observer driven per-rule for UI feedback.
    /// - Returns: Scan results with final (classified) safety levels.
    public func scan(progress: ScanProgress? = nil) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    /// Run the scan and emit per-path events to an EventHorizon-style observer.
    ///
    /// Each child the size walker visits emits a `.checked` event; each result
    /// that survives deduplication emits a `.match` event with byte count;
    /// per-rule warnings emit a `.failed` event.
    public func scan(
        progress: ScanProgress? = nil,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        await progress?.start()

        let applicable = rules.filter { rule in
            profile.categories.isEmpty || profile.categories.contains(rule.category)
        }

        // Probe scan roots once for present ecosystems so rule evaluation can drop
        // `**/<leaf>` patterns whose ecosystem isn't represented anywhere — keeps the
        // UI from emitting "depth reached. 0 partial results." warnings for every
        // rule the user has no projects of (Angular, .NET, Zig, Terraform, etc.).
        let availableEcosystems = applicabilityChecker.availableEcosystems(in: scanRoots)
        let ecosystemList = availableEcosystems.map(\.rawValue).sorted().joined(separator: ",")
        logger.info(
            "NativeScanAdapter: \(applicable.count) rules match profile \(profile.id, privacy: .public); ecosystems present: \(ecosystemList, privacy: .public)"
        )

        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        var reclaimableBytes: Int64 = 0
        let total = max(applicable.count, 1)

        // Fire-and-forget sizing updates so the UI ticks per child path during a
        // rule whose `directorySize` walk would otherwise sit silent for seconds.
        // The same callback also feeds path-level events to the EventHorizon
        // console when an observer is attached.
        let observerRef = observer
        let onSizing: @Sendable (String) -> Void = { path in
            Task { @MainActor [weak progress] in
                progress?.noteSizing(path: path)
            }
            observerRef?.didEmit(ScanProgressEvent(path: path, outcome: .checked))
        }

        for (idx, rule) in applicable.enumerated() {
            await progress?.update(
                fractionCompleted: Double(idx) / Double(total),
                currentCategory: rule.category,
                itemsFound: results.count,
                reclaimableBytes: reclaimableBytes
            )

            let expander = expander
            let roots = scanRoots
            let processChecker = processChecker
            let ecosystems = availableEcosystems
            let evaluation = await Task.detached {
                Self.evaluate(
                    rule: rule,
                    classifier: classifier,
                    profile: profile,
                    expander: expander,
                    scanRoots: roots,
                    processChecker: processChecker,
                    availableEcosystems: ecosystems,
                    onSizing: onSizing
                )
            }.value

            for warning in evaluation.warnings {
                await progress?.recordError(warning)
                observerRef?.didEmit(ScanProgressEvent(
                    path: rule.id,
                    outcome: .failed(reason: warning)
                ))
            }
            // Deduplicate by path across rules so overlapping rules don't double-count
            // bytes or trigger a second recycle attempt after the first succeeds.
            for result in evaluation.results where seenPaths.insert(result.path).inserted {
                results.append(result)
                reclaimableBytes += result.size
                observerRef?.didEmit(ScanProgressEvent(
                    path: result.path,
                    outcome: .match,
                    bytes: result.size
                ))
            }
        }

        await progress?.finish(itemsFound: results.count)
        logger.info("NativeScanAdapter: produced \(results.count) items")
        return results
    }

    // MARK: - Private

    struct RuleEvaluation: Sendable {
        var results: [ScanResult]
        var warnings: [String]
    }

    private static func evaluate(
        rule: ScanRule,
        classifier: SafetyClassifier,
        profile: CleanupProfile,
        expander: PathExpander,
        scanRoots: [URL],
        processChecker: any RunningProcessChecking,
        availableEcosystems: Set<RuleEcosystem>,
        onSizing: @Sendable (String) -> Void = { _ in }
    ) -> RuleEvaluation {
        if NativeRuleGuardEvaluator.shouldSkipRule(rule: rule, processChecker: processChecker) {
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
                   !availableEcosystems.contains(required) {
                    continue
                }

                let expansion = expander.expand(pattern: pattern, roots: scanRoots)
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
                        classifier: classifier,
                        profile: profile,
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
                        classifier: classifier,
                        profile: profile
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

private enum NativeRuleGuardEvaluator {
    static func shouldSkipRule(
        rule: ScanRule,
        processChecker: any RunningProcessChecking
    ) -> Bool {
        rule.skipIfProcessRunning.contains { processChecker.isRunning(identifier: $0) }
    }

    static func matchesRuleFilters(
        rule: ScanRule,
        lastAccessed: Date?,
        modifiedAt: Date?
    ) -> Bool {
        let evaluator = ConditionEvaluator()
        return rule.matchFilters.allSatisfy {
            evaluator.evaluate(condition: $0, lastAccessed: lastAccessed, modifiedAt: modifiedAt)
        }
    }

    static func isGuardedCandidate(rule: ScanRule, candidatePath: String) -> Bool {
        let fileManager = FileManager.default

        for guardRule in rule.presenceGuards {
            let path = resolveGuardPath(guardRule.path, scope: guardRule.scope, candidatePath: candidatePath)
            if fileManager.fileExists(atPath: path) {
                return true
            }
        }

        for guardRule in rule.contentGuards {
            let path = resolveGuardPath(guardRule.path, scope: guardRule.scope, candidatePath: candidatePath)
            guard fileManager.fileExists(atPath: path),
                  let contents = readGuardFile(atPath: path) else {
                continue
            }
            if guardRule.contains.contains(where: contents.contains) {
                return true
            }
        }

        return false
    }

    private static func resolveGuardPath(
        _ path: String,
        scope: RuleGuardPathScope,
        candidatePath: String
    ) -> String {
        if scope == .absolute || path.hasPrefix("/") || path.hasPrefix("~") {
            return expandTilde(path)
        }
        if path.isEmpty {
            return candidatePath
        }
        return (candidatePath as NSString).appendingPathComponent(path)
    }

    private static func readGuardFile(atPath path: String, byteLimit: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: byteLimit)
        return String(data: data, encoding: .utf8)
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
