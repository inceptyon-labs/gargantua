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
        let sizeCache: DirectorySizeCache
        /// A single wall-clock reference captured once at scan start. Every rule's
        /// age/mtime filter and safety override resolves against this same instant,
        /// so a concurrent scan and a serial scan of the same tree classify a
        /// threshold-edge file identically — evaluation order can't shift "now".
        let referenceDate: Date
    }

    /// Memoizes recursive directory sizes for the span of a single scan.
    ///
    /// Overlapping rules (and, within a rule, two patterns) can resolve to the
    /// *same* path. Sizing is the expensive part of a match — a full recursive
    /// walk of that subtree — so pricing it once and serving cached bytes to the
    /// later consumers removes the double-walk without changing any byte count.
    ///
    /// Thread-safe: concurrent rule evaluation shares one instance. The compute
    /// runs outside the lock so sizing of *different* paths stays parallel; a
    /// rare race sizes one path twice, but both walks yield the same total, so
    /// the memoized value is unchanged.
    final class DirectorySizeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [String: Int64] = [:]

        func size(at path: String, compute: () -> Int64) -> Int64 {
            lock.lock()
            if let cached = sizes[path] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let value = compute()
            lock.lock()
            sizes[path] = value
            lock.unlock()
            return value
        }
    }

    static func evaluate(
        rule: ScanRule,
        context: EvaluationContext,
        onSizing: @Sendable (String) -> Void = { _ in }
    ) -> RuleEvaluation {
        // A running owner app (browser, Xcode, …) no longer hides this rule's
        // items — they are surfaced locked and tagged so the UI can offer to quit
        // the app and unblock them in place.
        let blockedByApp = NativeRuleGuardEvaluator.blockingApp(
            rule: rule,
            processChecker: context.processChecker
        )

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
                        sizeCache: context.sizeCache,
                        now: context.referenceDate,
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
                        profile: context.profile,
                        sizeCache: context.sizeCache,
                        now: context.referenceDate
                    ) {
                        out.append(result)
                    }
                }
            }
        }

        if let blockedByApp {
            for index in out.indices { out[index].blockedByApp = blockedByApp }
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
        sizeCache: DirectorySizeCache,
        now: Date,
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
            if rule.pattern == nil, holdsExcludedEntry(child, excludes: rule.exclude, fileManager: fileManager) {
                // Removing this child would take the excluded entry with it
                // (`*/device.plist` in a simulator's device folder), so offer
                // the child's other entries instead.
                let grandchildren = (try? fileManager.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for grandchild in grandchildren where !isExcluded(child: grandchild, excludes: rule.exclude) {
                    onSizing(grandchild.path)
                    if let result = makeResult(
                        rule: rule,
                        path: grandchild.path,
                        counter: &counter,
                        classifier: classifier,
                        profile: profile,
                        sizeCache: sizeCache,
                        now: now
                    ) {
                        out.append(result)
                    }
                }
                continue
            }
            onSizing(child.path)
            if let result = makeResult(
                rule: rule,
                path: child.path,
                counter: &counter,
                classifier: classifier,
                profile: profile,
                sizeCache: sizeCache,
                now: now
            ) {
                out.append(result)
            }
        }
    }

    static func makeResult(
        rule: ScanRule,
        path: String,
        counter: inout Int,
        classifier: SafetyClassifier,
        profile: CleanupProfile,
        sizeCache: DirectorySizeCache = DirectorySizeCache(),
        now: Date = Date()
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

        // Never target a mount point. Broad temp rules like /private/tmp/* would
        // otherwise match mounted read-only disk images (e.g. Xcode's mounted DDIs
        // at /private/tmp/dmg.XXXXXX), which can't be deleted and aren't junk.
        if isDirectory, Self.isMountPoint(path) {
            return nil
        }

        guard NativeRuleGuardEvaluator.matchesRuleFilters(
            rule: rule,
            lastAccessed: lastAccessed,
            modifiedAt: modifiedAt,
            now: now
        ),
            !NativeRuleGuardEvaluator.isGuardedCandidate(rule: rule, candidatePath: path) else {
            return nil
        }

        let size: Int64
        if isDirectory {
            // Memoize per unique path so overlapping rules that resolve the same
            // directory don't each re-walk the subtree to size it.
            size = sizeCache.size(at: path) {
                DirectorySizeScanner.directorySize(at: path).totalSize
            }
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard size > 0 else { return nil }
        if let minSize = rule.minSize, size < minSize { return nil }

        let displayName = Self.displayName(forRule: rule, path: path)
        // Age-based overrides judge a folder by its most recent activity, not
        // only its own timestamps (see `newestActivity(inDirectory:since:)`).
        let classifiedAccess = isDirectory && !(rule.safetyOverrides.isEmpty && profile.safetyOverrides.isEmpty)
            ? Self.newestActivity(inDirectory: path, since: lastAccessed)
            : lastAccessed

        let base = ScanResult(
            id: "\(rule.id)-\(counter)",
            name: displayName,
            path: path,
            size: size,
            safety: rule.safety,
            confidence: rule.confidence,
            explanation: rule.explanation,
            source: rule.source,
            lastAccessed: classifiedAccess,
            category: rule.category,
            tags: rule.tags,
            regenerates: rule.regenerates,
            regenerateCommand: rule.regenerateCommand
        )
        counter += 1

        let classified = classifier.classify(result: base, rule: rule, profile: profile, now: now)
        // Record the parent-chain resolution here, at the moment the item is
        // confirmed on disk, not at the pipeline tail. Recording later would
        // capture a symlink swap that happened *during* the scan as if it
        // were scan-time truth, defeating the pre-delete guard for the
        // primary filesystem source. Idempotent, so the composite/engine
        // backstop map is a no-op for these.
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
        ).recordingScanTimeAncestry()
    }

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    /// A directory is a mount point when it sits on a different device than its
    /// parent — true for mounted disk images, network shares, and external
    /// volumes. Comparing `st_dev` catches them all without parsing mount tables.
    /// The most recent activity in a directory: `since` (its own access or
    /// modification date) or any direct child's modification date, whichever
    /// is newer. A directory's own timestamps move only when entries are added
    /// or removed, so a folder whose contents are written in place (Chromium's
    /// Local Storage holds one `leveldb/` folder) looks untouched for months
    /// while the browser uses it daily.
    static func newestActivity(inDirectory path: String, since: Date?) -> Date? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        var newest = since
        for child in children {
            guard let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if newest.map({ modified > $0 }) ?? true {
                newest = modified
            }
        }
        return newest
    }

    static func isMountPoint(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return false }
        var here = stat()
        var above = stat()
        guard stat(path, &here) == 0, stat(parent, &above) == 0 else { return false }
        return here.st_dev != above.st_dev
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
        // An entry offered from inside a child (see `holdsExcludedEntry`):
        // name the child too, since every device folder has a `data`.
        let grandparent = url.deletingLastPathComponent().deletingLastPathComponent().path
        if rule.exclude.contains(where: { $0.hasPrefix("*/") }),
           rule.paths.contains(where: { expandTilde($0) == grandparent }) {
            return "\(rule.name) — \(parent)/\(last)"
        }

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

    /// Whether `child` is a folder holding an entry a `*/name` exclude names.
    /// Excludes are matched against the rule directory's children, so
    /// `*/Google` drops the child named Google; but `*/device.plist` names a
    /// file inside each child, which taking the child whole would delete.
    static func holdsExcludedEntry(_ child: URL, excludes: [String], fileManager: FileManager = .default) -> Bool {
        let nestedNames = excludes.compactMap { pattern -> String? in
            guard pattern.hasPrefix("*/") else { return nil }
            let name = String(pattern.dropFirst(2))
            return name.contains("/") ? nil : name
        }
        guard !nestedNames.isEmpty,
              let entries = try? fileManager.contentsOfDirectory(atPath: child.path) else { return false }
        return entries.contains { entry in nestedNames.contains { fnmatch(pattern: $0, name: entry) } }
    }

    static func isExcluded(child: URL, excludes: [String]) -> Bool {
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
    static func fnmatch(pattern: String, name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        // A wildcard-free pattern is an exact name, not a prefix: "Cache.db"
        // must not sweep up Cache.db-wal, and an exclude of "com.apple.Safari"
        // must not also strip com.apple.SafariTechnologyPreview.
        if parts.count == 1 {
            return pattern == name
        }
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
