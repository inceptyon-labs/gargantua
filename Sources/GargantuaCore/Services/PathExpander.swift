import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "PathExpander")

/// Resolves YAML rule path patterns into concrete filesystem paths, with bounded walking.
///
/// Supports the glob forms used by `cleanup_rules/*.yaml`:
/// - `~/Library/Caches` — literal path, tilde-expanded
/// - `/tmp/homebrew-*` — single-segment wildcard applied to filenames
/// - `~/Library/Caches/Firefox/Profiles/*/cache2` — wildcard for one directory level
/// - `**/node_modules` — recursive descent from scan roots
/// - `~/Projects/**/node_modules` — recursive descent within a concrete prefix
///
/// Hard caps prevent runaway walks of the entire filesystem. When a cap trips the
/// expander returns partial results and marks `hitCap = true`; callers surface this
/// through `ScanProgress.recordError` as a non-fatal warning.
public struct PathExpander: Sendable {

    /// Bounds on a single `expand` call.
    public struct Limits: Sendable {
        public let maxDepth: Int
        public let maxEntries: Int
        public let timeBudget: TimeInterval

        public init(maxDepth: Int = 8, maxEntries: Int = 100_000, timeBudget: TimeInterval = 30) {
            self.maxDepth = maxDepth
            self.maxEntries = maxEntries
            self.timeBudget = timeBudget
        }
    }

    /// Outcome of expanding one pattern.
    public struct ExpansionResult: Sendable {
        public let paths: [String]
        public let hitCap: Bool
        public let capReason: String?
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Expand `pattern` into concrete filesystem paths.
    ///
    /// - Parameters:
    ///   - pattern: A path pattern from a `ScanRule.paths` entry (may contain `~`, `*`, `**`).
    ///   - roots: Directories to walk when `pattern` has no concrete prefix (e.g. `**/node_modules`).
    /// - Returns: Matched paths plus cap telemetry.
    public func expand(pattern: String, roots: [URL]) -> ExpansionResult {
        let expandedPattern = (pattern as NSString).expandingTildeInPath
        let isAbsolute = expandedPattern.hasPrefix("/")
        let components = expandedPattern
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard let firstGlobIdx = components.firstIndex(where: Self.hasWildcard) else {
            // Literal path — return if it exists.
            let path = isAbsolute
                ? "/" + components.joined(separator: "/")
                : components.joined(separator: "/")
            if FileManager.default.fileExists(atPath: path) {
                return ExpansionResult(paths: [path], hitCap: false, capReason: nil)
            }
            return ExpansionResult(paths: [], hitCap: false, capReason: nil)
        }

        let prefixComponents = Array(components[0 ..< firstGlobIdx])
        let globComponents = Array(components[firstGlobIdx...])

        let prefixPaths: [String]
        if prefixComponents.isEmpty {
            // No concrete prefix — walk from provided scan roots.
            prefixPaths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        } else {
            let prefix = (isAbsolute ? "/" : "") + prefixComponents.joined(separator: "/")
            prefixPaths = FileManager.default.fileExists(atPath: prefix) ? [prefix] : []
        }

        let state = WalkState(limits: limits)
        var results: Set<String> = []
        for prefix in prefixPaths {
            if state.shouldStop { break }
            walk(
                atPath: prefix,
                remaining: globComponents,
                depth: 0,
                results: &results,
                state: state
            )
        }

        if state.hitCap {
            let reason = state.capReason ?? "unknown"
            logger.warning(
                "PathExpander cap \(reason, privacy: .public) on '\(pattern, privacy: .public)' — partial: \(results.count)"
            )
        }

        return ExpansionResult(
            paths: Array(results).sorted(),
            hitCap: state.hitCap,
            capReason: state.capReason
        )
    }

    // MARK: - Internal

    private func walk(
        atPath path: String,
        remaining: [String],
        depth: Int,
        results: inout Set<String>,
        state: WalkState
    ) {
        if state.shouldStop { return }

        if remaining.isEmpty {
            results.insert(path)
            return
        }

        if depth >= limits.maxDepth {
            state.recordCap(reason: "depth", abort: false)
            return
        }

        let segment = remaining[0]
        let rest = Array(remaining.dropFirst())

        if segment == "**" {
            walkRecursive(path: path, remaining: remaining, rest: rest, depth: depth, results: &results, state: state)
        } else if segment.contains("*") {
            walkWildcard(path: path, segment: segment, rest: rest, depth: depth, results: &results, state: state)
        } else {
            walkLiteral(path: path, segment: segment, rest: rest, depth: depth, results: &results, state: state)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func walkRecursive(
        path: String,
        remaining: [String],
        rest: [String],
        depth: Int,
        results: inout Set<String>,
        state: WalkState
    ) {
        // Match zero directories: proceed with the remaining segments here.
        walk(atPath: path, remaining: rest, depth: depth, results: &results, state: state)
        // Match one or more directories: descend, keep `**` in remaining.
        for (childPath, childName) in enumerateChildren(
            atPath: path,
            includeHidden: Self.requiresHiddenEnumeration(remaining),
            state: state
        ) {
            if state.shouldStop { return }
            // Don't descend into well-known dependency / artifact dirs unless the
            // pattern itself names that dir. For a pattern like `**/.next/cache`,
            // walking into every `node_modules` tree burns through the entries
            // cap and never reaches sibling projects with shallower matches. For
            // a pattern like `**/node_modules/.vite`, the dir IS named in the
            // pattern, so we keep descending.
            if Self.shouldSkipRecursiveDescent(into: childName, pattern: remaining) {
                continue
            }
            walk(atPath: childPath, remaining: remaining, depth: depth + 1, results: &results, state: state)
        }
    }

    /// Dependency / artifact directories that should never be descended into during
    /// `**` recursion, unless the user's pattern explicitly names them.
    ///
    /// Limited to names that are *unambiguously* dependency caches or VCS metadata
    /// — not generic dir names like `build`, `dist`, or `out` which are commonly
    /// user-authored (e.g. a Cargo target dir nested under a `build/` workspace
    /// folder). Pruning a generic name would silently miss legitimate matches.
    ///
    /// The prune-when-not-in-pattern check below ensures rules that *target* these
    /// names (e.g. `**/.next/cache`, `**/node_modules`) still descend correctly: the
    /// match-zero branch in `walkRecursive` finds them at the current level, and
    /// only sibling subtrees that don't name them get pruned.
    private static let pruneOnRecursiveDescent: Set<String> = [
        // Dependency dirs (rarely user-authored at these names)
        "node_modules", "vendor", "Pods",
        "__pycache__", ".venv", "venv",
        // VCS metadata
        ".git", ".svn", ".hg",
        // Per-tool artifact / cache dirs (dotted, tool-specific)
        "DerivedData",
        ".next", ".nuxt", ".svelte-kit", ".angular",
        ".gradle",
        ".terraform",
        ".serverless",
        ".zig-cache",
        ".turbo",
        ".vite", ".parcel-cache",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
    ]

    private static func shouldSkipRecursiveDescent(into name: String, pattern: [String]) -> Bool {
        guard pruneOnRecursiveDescent.contains(name) else { return false }
        // If the pattern explicitly names this directory as a literal segment, the
        // walk needs to descend into it (or to the level just above it). Patterns
        // that contain wildcards in the segment match independently.
        return !pattern.contains(name)
    }

    // swiftlint:disable:next function_parameter_count
    private func walkWildcard(
        path: String,
        segment: String,
        rest: [String],
        depth: Int,
        results: inout Set<String>,
        state: WalkState
    ) {
        for (childPath, childName) in enumerateChildren(
            atPath: path,
            includeHidden: Self.requiresHiddenEnumeration([segment]),
            state: state
        ) {
            if state.shouldStop { return }
            if Self.fnmatch(pattern: segment, name: childName) {
                walk(atPath: childPath, remaining: rest, depth: depth + 1, results: &results, state: state)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func walkLiteral(
        path: String,
        segment: String,
        rest: [String],
        depth: Int,
        results: inout Set<String>,
        state: WalkState
    ) {
        let child = (path as NSString).appendingPathComponent(segment)
        if FileManager.default.fileExists(atPath: child) {
            walk(atPath: child, remaining: rest, depth: depth + 1, results: &results, state: state)
        }
    }

    private func enumerateChildren(
        atPath path: String,
        includeHidden: Bool = false,
        state: WalkState
    ) -> [(path: String, name: String)] {
        if state.shouldStop { return [] }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: options
        ) else {
            return []
        }

        var out: [(path: String, name: String)] = []
        out.reserveCapacity(contents.count)
        for child in contents {
            if state.shouldStop { break }
            state.incrementEntries()
            if state.shouldStop { break }

            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }
            out.append((child.path, child.lastPathComponent))
        }
        return out
    }

    private static func hasWildcard(_ component: String) -> Bool {
        component.contains("*")
    }

    private static func requiresHiddenEnumeration(_ components: [String]) -> Bool {
        components.contains { component in
            component.hasPrefix(".") || component.hasPrefix(".*")
        }
    }

    /// Minimal fnmatch supporting `*` wildcards against a single segment name.
    ///
    /// `*` matches any substring (including empty). Pattern anchoring respects
    /// the presence of leading/trailing `*`: `foo*` must prefix-match, `*foo`
    /// must suffix-match, `foo*bar` must prefix `foo` and suffix `bar`.
    static func fnmatch(pattern: String, name: String) -> Bool {
        if pattern == "*" { return true }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            return pattern == name
        }

        var cursor = name.startIndex
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }

            if i == 0 {
                // Must prefix-match.
                guard name.hasPrefix(part) else { return false }
                cursor = name.index(cursor, offsetBy: part.count)
            } else if i == parts.count - 1 {
                // Must suffix-match in the remaining window.
                return name[cursor...].hasSuffix(part)
            } else {
                guard let range = name.range(of: part, range: cursor ..< name.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}

// MARK: - Walk state (internal)

/// Shared mutable walk state.
///
/// Reference type (class) so nested recursive walks and child enumerations can
/// update caps without Swift exclusivity violations on overlapping `inout` access.
///
/// Distinguishes between a *partial* outcome (we hit some cap and the result
/// set may be incomplete) and an *aborted* walk (we ran out of a global budget
/// — entries or time — and must stop visiting siblings). Depth cap is a
/// per-branch property: hitting it on one subtree does not preclude finding
/// shallower matches in sibling subtrees.
private final class WalkState {
    let limits: PathExpander.Limits
    let start: Date = Date()
    var entries: Int = 0
    private(set) var hitCap: Bool = false
    private(set) var capReason: String?
    private(set) var aborted: Bool = false

    init(limits: PathExpander.Limits) {
        self.limits = limits
    }

    /// True only when a global resource cap (entries / time) has been exhausted.
    /// Depth cap does NOT set this — it just trims the current branch.
    var shouldStop: Bool {
        aborted
    }

    func incrementEntries() {
        entries += 1
        if entries >= limits.maxEntries {
            recordCap(reason: "entries", abort: true)
            return
        }
        if Date().timeIntervalSince(start) > limits.timeBudget {
            recordCap(reason: "time", abort: true)
        }
    }

    /// Record that the walk truncated some result. Pass `abort: true` for budgets
    /// (entries / time) that should stop visiting any further paths.
    func recordCap(reason: String, abort: Bool) {
        if !hitCap {
            hitCap = true
            capReason = reason
        }
        if abort {
            aborted = true
        }
    }
}

// MARK: - Default scan roots

extension PathExpander {
    /// Reasonable default directories to walk when a pattern has no concrete prefix.
    ///
    /// Prefers common developer project locations (`~/Projects`, `~/GitHub`, etc.) that
    /// actually exist on the user's machine. Avoids walking the full home directory
    /// because that would traverse `~/Library` and dominate scan time.
    ///
    /// Returns an empty array when none of the candidates exist; callers should treat
    /// that as "no globs to expand" rather than falling back to `$HOME`, which would
    /// silently widen scope to the entire user directory.
    public static func defaultScanRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = ["Projects", "GitHub", "dev", "www", "Code", "Development", "Documents", "Desktop"]
        return candidates.compactMap { name -> URL? in
            let url = home.appendingPathComponent(name, isDirectory: true)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }
}
