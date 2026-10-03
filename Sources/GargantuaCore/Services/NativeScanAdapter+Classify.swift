import Foundation

// Single-path classification for the MCP `explain` tool.
//
// `scan` works forward: expand every rule's globs, walk the filesystem, emit
// results. `explain` needs the reverse — given one arbitrary absolute path,
// which rule (if any) claims it, and what is its Trust Layer verdict? Rather
// than run a full scan to answer one question, `classify(path:)` reverse-matches
// the path against the rule set in memory and reuses `evaluate`'s exact
// `makeResult` path (guards, sizing, minSize, mount-point skip, and the
// SafetyClassifier override pass) so an explained path gets byte-for-byte the
// same verdict scan would have produced — with no directory walk.
extension NativeScanAdapter {

    /// Resolve `queryPath` to the Trust Layer verdict the rule set assigns it,
    /// or `nil` when no rule in the active profile claims the path (the caller
    /// then falls back to a conservative "review" shell).
    ///
    /// The match mirrors `evaluate` exactly:
    /// - A rule with a `pattern:` selects children of its resolved directories,
    ///   so the path matches when its *parent* matches a rule glob and its leaf
    ///   matches the pattern.
    /// - A literal rule path carrying `exclude:` also enumerates children, so the
    ///   path matches when its parent equals the literal directory.
    /// - Everything else treats the rule glob as the item itself, so the path
    ///   matches when it matches a rule glob directly.
    /// `exclude` is honored in every case; `makeResult` applies the remaining
    /// guards and may still return `nil` (e.g. zero-byte, below `minSize`, or a
    /// guarded candidate), which surfaces as "no rule verdict".
    public func classify(path queryPath: String) -> ScanResult? {
        let path = Self.normalizedPath(queryPath)
        let parent = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent

        let applicable = rules.filter {
            profile.categories.isEmpty || profile.categories.contains($0.category)
        }

        for rule in applicable where Self.rule(rule, selects: path, parent: parent, leaf: leaf) {
            var counter = 0
            if let result = Self.makeResult(
                rule: rule,
                path: path,
                counter: &counter,
                classifier: classifier,
                profile: profile
            ) {
                return result
            }
        }
        return nil
    }

    // MARK: - Reverse matching

    /// Whether `rule` would surface `path` as one of its items, replicating the
    /// `paths` + `pattern` + `exclude` selection logic in `evaluate` (sans the
    /// filesystem walk).
    static func rule(_ rule: ScanRule, selects path: String, parent: String, leaf: String) -> Bool {
        let excludesURL = URL(fileURLWithPath: path)
        for glob in rule.paths {
            let g = expandTilde(glob)
            let isGlob = g.contains("*")

            if let filePattern = rule.pattern {
                // Children selected by filename pattern: parent must match the
                // rule's container glob, and the leaf must match the pattern.
                if globMatches(pattern: g, path: parent),
                   fnmatch(pattern: filePattern, name: leaf),
                   !isExcluded(child: excludesURL, excludes: rule.exclude) {
                    return true
                }
            } else if !isGlob, !rule.exclude.isEmpty {
                // Literal directory with excludes: immediate children are
                // enumerated, so the parent must be the literal directory.
                if g == parent, !isExcluded(child: excludesURL, excludes: rule.exclude),
                   !holdsExcludedEntry(excludesURL, excludes: rule.exclude) {
                    return true
                }
                // An entry offered from inside a child that holds an excluded
                // entry (`*/device.plist`).
                let grandparent = (parent as NSString).deletingLastPathComponent
                if g == grandparent, !isExcluded(child: excludesURL, excludes: rule.exclude),
                   holdsExcludedEntry(URL(fileURLWithPath: parent), excludes: rule.exclude) {
                    return true
                }
            } else {
                // The resolved glob/literal path is itself the item.
                if globMatches(pattern: g, path: path),
                   !isExcluded(child: excludesURL, excludes: rule.exclude) {
                    return true
                }
            }
        }
        return false
    }

    /// Full-path glob match over `/`-delimited segments. `**` matches zero or
    /// more whole segments; within a segment `*` matches any run of non-`/`
    /// characters and `?` matches a single one. Both inputs are absolute.
    static func globMatches(pattern: String, path: String) -> Bool {
        let pSegs = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let nSegs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return matchSegments(pSegs, 0, nSegs, 0)
    }

    private static func matchSegments(_ p: [String], _ pi: Int, _ n: [String], _ ni: Int) -> Bool {
        var pi = pi
        var ni = ni
        while pi < p.count {
            if p[pi] == "**" {
                // Trailing `**` matches whatever is left, including nothing.
                if pi + 1 == p.count { return true }
                var k = ni
                while k <= n.count {
                    if matchSegments(p, pi + 1, n, k) { return true }
                    k += 1
                }
                return false
            }
            if ni >= n.count { return false }
            guard segmentMatch(p[pi], n[ni]) else { return false }
            pi += 1
            ni += 1
        }
        return ni == n.count
    }

    /// Single-segment wildcard match supporting `*` (non-`/` run) and `?`.
    private static func segmentMatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        // Classic two-pointer glob with backtracking on `*`.
        var pi = 0
        var si = 0
        var star = -1
        var mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "*" {
                star = pi
                mark = si
                pi += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Tilde-expand and strip a trailing slash — and nothing else. The forward
    /// scanner expands rule globs with `expandingTildeInPath` only (no symlink
    /// resolution, no `..` collapsing), so classification mirrors that to keep
    /// the reverse match consistent with what a scan would have produced.
    private static func normalizedPath(_ path: String) -> String {
        let expanded = expandTilde(path)
        if expanded.count > 1, expanded.hasSuffix("/") {
            return String(expanded.dropLast())
        }
        return expanded
    }
}
