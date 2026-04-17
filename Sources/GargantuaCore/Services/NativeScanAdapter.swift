import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "NativeScanAdapter")

/// Native filesystem scanner driven by YAML rules.
///
/// Walks the paths declared in `ScanRule` files, measures sizes, applies
/// profile-aware safety overrides via `SafetyClassifier`, and emits `ScanResult`
/// values. Mirrors the `MoCleanAdapter.scan` shape for drop-in use.
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

    public init(
        rules: [ScanRule],
        profile: CleanupProfile = .light,
        classifier: SafetyClassifier = SafetyClassifier(),
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander()
    ) {
        self.rules = rules
        self.profile = profile
        self.classifier = classifier
        self.scanRoots = scanRoots
        self.expander = expander
    }

    /// Build a scanner against the YAML rules shipped with the app.
    ///
    /// Locates the `cleanup_rules` directory via `RuleDirectoryResolver`, loads
    /// every YAML file under it with `RuleLoader`, and returns a configured adapter.
    /// Rule-file parse errors are reported via the returned load result but do not
    /// abort — successfully-parsed rules are still used.
    public static func loadDefaults(profile: CleanupProfile) throws -> NativeScanAdapter {
        guard let dir = RuleDirectoryResolver.resolve() else {
            throw ScanAdapterError.rulesDirectoryNotFound
        }
        let load = try RuleLoader().loadRules(from: dir)
        for err in load.errors {
            logger.warning("Rule parse error: \(err.localizedDescription, privacy: .public)")
        }
        return NativeScanAdapter(rules: load.rules, profile: profile)
    }

    /// Run the scan against the configured rules and profile.
    ///
    /// - Parameter progress: Optional observer driven per-rule for UI feedback.
    /// - Returns: Scan results with final (classified) safety levels.
    public func scan(progress: ScanProgress? = nil) async throws -> [ScanResult] {
        await progress?.start()

        let applicable = rules.filter { rule in
            profile.categories.isEmpty || profile.categories.contains(rule.category)
        }

        logger.info("NativeScanAdapter: \(applicable.count) rules match profile \(profile.id, privacy: .public)")

        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        let total = max(applicable.count, 1)

        for (idx, rule) in applicable.enumerated() {
            await progress?.update(
                fractionCompleted: Double(idx) / Double(total),
                currentCategory: rule.category,
                itemsFound: results.count
            )

            let expander = expander
            let roots = scanRoots
            let evaluation = await Task.detached {
                Self.evaluate(rule: rule, classifier: classifier, profile: profile, expander: expander, scanRoots: roots)
            }.value

            for warning in evaluation.warnings {
                await progress?.recordError(warning)
            }
            // Deduplicate by path across rules so overlapping rules don't double-count
            // bytes or trigger a second recycle attempt after the first succeeds.
            for result in evaluation.results where seenPaths.insert(result.path).inserted {
                results.append(result)
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
        scanRoots: [URL]
    ) -> RuleEvaluation {
        let fileManager = FileManager.default
        var out: [ScanResult] = []
        var warnings: [String] = []
        var counter = 0

        for pattern in rule.paths {
            let isGlob = pattern.contains("*")
            let resolvedPaths: [String]

            if isGlob {
                let expansion = expander.expand(pattern: pattern, roots: scanRoots)
                resolvedPaths = expansion.paths
                if expansion.hitCap {
                    let reason = expansion.capReason ?? "cap"
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
                        into: &out
                    )
                } else {
                    if !rule.exclude.isEmpty,
                       isExcluded(child: URL(fileURLWithPath: path), excludes: rule.exclude) {
                        continue
                    }
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
        let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let size: Int64
        if isDirectory {
            size = DirectorySizeScanner.directorySize(at: path)
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard size > 0 else { return nil }

        let attrs = try? fileManager.attributesOfItem(atPath: path)
        let lastAccessed = (attrs?[.modificationDate] as? Date)

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
            ".venv", "venv", ".gradle", "vendor", ".next", ".nuxt"
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
                guard let range = name.range(of: part, range: cursor..<name.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}

/// Resolves the directory containing YAML cleanup rules.
///
/// Search order:
/// 1. `GARGANTUA_RULES_DIR` environment variable
/// 2. `Bundle.main.resourceURL/cleanup_rules` (shipped .app)
/// 3. `<executable>/cleanup_rules` (same dir as binary)
/// 4. Walk upward from the executable directory looking for a `cleanup_rules/` sibling of `Package.swift` (dev via `swift run`)
public enum RuleDirectoryResolver {
    public static func resolve() -> URL? {
        let fm = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["GARGANTUA_RULES_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let execDir {
            let candidate = execDir.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }

            // Walk upward until we find a directory containing both Package.swift and cleanup_rules.
            var dir = execDir
            for _ in 0..<8 {
                let rules = dir.appendingPathComponent("cleanup_rules", isDirectory: true)
                let pkg = dir.appendingPathComponent("Package.swift")
                if fm.fileExists(atPath: rules.path) && fm.fileExists(atPath: pkg.path) {
                    return rules
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Last resort: CWD.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("cleanup_rules", isDirectory: true)
        if fm.fileExists(atPath: cwd.path) { return cwd }

        return nil
    }
}
