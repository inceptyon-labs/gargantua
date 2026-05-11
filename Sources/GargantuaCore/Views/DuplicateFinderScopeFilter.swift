import Foundation

// MARK: - Scope filter

/// Restrict the Duplicate Finder to byte-identical groups the user can
/// plausibly act on at the file level.
///
/// Two complementary rules:
/// - **Whitelist** (`personalRoots`): every file in the group must live
///   inside one of the supplied roots. Catches the long tail of "duplicate
///   in some part of the system the user doesn't think about" — dev
///   project trees, build outputs, anything outside `~/Documents`,
///   `~/Downloads`, `~/Desktop`, etc.
/// - **Blacklist** (`excludeManaged`): even inside a personal root, drop
///   groups whose files all live in a known managed sub-tree (Adobe auto-
///   saves under `~/Documents/Adobe/`, the iCloud sync mirror, etc.) or
///   that form an intra-archive cluster.
///
/// Both default on. Pass `personalRoots: nil` and `excludeManaged: false`
/// for the raw fclones firehose.
public enum DuplicateFinderScopeFilter {

    /// Default personal-scope roots: the standard user-document folders
    /// where deliberate duplicates plausibly land. Used as a fallback when
    /// no user-configured roots are supplied.
    public static func defaultPersonalRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            "Documents",
            "Downloads",
            "Desktop",
            "Pictures",
            "Movies",
            "Music",
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Validate and normalize a user-typed personal-scope folder path.
    /// Returns the trimmed path preserving the user's `~/` style on success,
    /// `nil` for any string that would weaken the filter — empty, relative,
    /// bare `~`/`~/`, exactly `/` (filesystem root), or exactly `$HOME`.
    /// The latter two are rejected because they make every duplicate
    /// "personal", defeating the whole point of the scope.
    public static func normalize(
        _ raw: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else { return nil }
        guard trimmed != "~/" else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL.path
        let home = homeDirectory.standardizedFileURL.path

        guard standardized != "/", standardized != home else { return nil }

        return trimmed
    }

    /// `true` when `raw` is acceptable as a personal-scope root entry.
    public static func isValidRoot(_ raw: String) -> Bool {
        normalize(raw) != nil
    }

    /// Expand user-facing path strings (e.g. `~/Documents`, `/Volumes/Photos`)
    /// to absolute URLs suitable for `apply(personalRoots:)`. Patterns that
    /// fail `normalize` are silently dropped — the Settings layer is
    /// responsible for rejecting bad input upfront; this is defence in depth.
    public static func expand(
        patterns: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        patterns.compactMap { raw in
            guard let normalized = normalize(raw, homeDirectory: homeDirectory) else { return nil }

            if normalized.hasPrefix("~/") {
                let suffix = String(normalized.dropFirst(2))
                return homeDirectory.appendingPathComponent(suffix, isDirectory: true)
            }

            return URL(fileURLWithPath: normalized, isDirectory: true)
        }
    }

    /// Filter `results` according to the supplied scope rules. See the
    /// type-level doc for semantics.
    public static func apply(
        to results: [ScanResult],
        personalRoots: [URL]?,
        excludeManaged: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ScanResult] {
        if !excludeManaged && personalRoots == nil { return results }

        var byGroup: [String: [ScanResult]] = [:]
        var orderByGroup: [String: Int] = [:]
        var untagged: [ScanResult] = []

        for result in results {
            guard let groupTag = result.tags.first(where: { $0.hasPrefix("fclones_group_") }) else {
                untagged.append(result)
                continue
            }
            if byGroup[groupTag] == nil {
                orderByGroup[groupTag] = orderByGroup.count
            }
            byGroup[groupTag, default: []].append(result)
        }

        let homeDepth = pathSegmentCount(of: homeDirectory.path)
        let personalPrefixes: [String]? = personalRoots?.map { url in
            url.path.hasSuffix("/") ? url.path : url.path + "/"
        }

        let kept = byGroup.compactMap { tag, files -> (Int, [ScanResult])? in
            let paths = files.map(\.path)

            if excludeManaged {
                if paths.allSatisfy({ ManagedTreePathFilter.isManaged($0, homeDirectory: homeDirectory) }) { return nil }
                if isDeeplyColocated(paths: paths, homeDepth: homeDepth) { return nil }
            }

            if let prefixes = personalPrefixes {
                let allInside = paths.allSatisfy { path in
                    prefixes.contains { path.hasPrefix($0) }
                }
                if !allInside { return nil }
            }

            return (orderByGroup[tag] ?? 0, files)
        }
        .sorted { $0.0 < $1.0 }
        .flatMap { $0.1 }

        return kept + untagged
    }

    /// Counts of duplicate groups that the filter currently hides for a
    /// given raw result list. Used by the empty/summary view to tell the
    /// user there are X groups and Y bytes available behind the toggle.
    public static func hiddenSummary(
        for results: [ScanResult],
        personalRoots: [URL]?,
        excludeManaged: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DuplicateFinderHiddenSummary {
        let visible = Set(
            apply(
                to: results,
                personalRoots: personalRoots,
                excludeManaged: excludeManaged,
                homeDirectory: homeDirectory
            ).map(\.id)
        )
        let hidden = results.filter { !visible.contains($0.id) }
        let hiddenGroups = DuplicateGrouper.group(hidden)
        let bytes = hiddenGroups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }
        return DuplicateFinderHiddenSummary(
            groups: hiddenGroups.count,
            files: hidden.count,
            reclaimableBytes: bytes
        )
    }

    /// Detect the intra-archive / intra-payload shape: every file in the
    /// group lives below a deep common ancestor (≥ 5 segments below $HOME).
    /// Catches expanded installers, framework copies, and asset bundles that
    /// vendor the same file at multiple positions inside one tree.
    static func isDeeplyColocated(paths: [String], homeDepth: Int) -> Bool {
        guard paths.count >= 2 else { return false }
        let split = paths.map { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
        guard let minLen = split.map(\.count).min(), minLen >= 1 else { return false }

        var commonDepth = 0
        for index in 0 ..< minLen {
            let segment = split[0][index]
            if split.allSatisfy({ $0[index] == segment }) {
                commonDepth = index + 1
            } else {
                break
            }
        }

        return commonDepth >= homeDepth + 5
    }

    private static func pathSegmentCount(of path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }
}
