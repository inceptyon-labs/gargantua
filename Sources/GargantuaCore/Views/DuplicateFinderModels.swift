import Foundation

// MARK: - DuplicateGroup

/// A cluster of files with identical content, surfaced by `FclonesAdapter`.
///
/// Built from a flat `[ScanResult]` whose rows carry `fclones_group_<id>` and
/// `fclones_hash_<short>` tags. Every file in a group has the same size, so
/// `perFileSize` is the canonical "keep one, reclaim the rest" unit.
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let shortHash: String
    public let files: [ScanResult]
    public let perFileSize: Int64

    public init(id: String, shortHash: String, files: [ScanResult], perFileSize: Int64) {
        self.id = id
        self.shortHash = shortHash
        self.files = files
        self.perFileSize = perFileSize
    }

    public var fileCount: Int { files.count }

    public var totalSize: Int64 {
        files.reduce(Int64(0)) { sum, result in
            let (next, overflow) = sum.addingReportingOverflow(result.size)
            return overflow ? Int64.max : next
        }
    }

    /// Maximum reclaimable bytes when keeping exactly one copy — equals
    /// `(fileCount - 1) * perFileSize`. Returns 0 for degenerate single-file
    /// groups. Overflow-clamped at `Int64.max`.
    public var reclaimableCeilingBytes: Int64 {
        guard fileCount >= 2 else { return 0 }
        let copies = Int64(fileCount - 1)
        let (product, overflow) = copies.multipliedReportingOverflow(by: perFileSize)
        return overflow ? Int64.max : product
    }

    /// IDs of files eligible for selection. Duplicates are never `.protected_`
    /// under the current `FclonesTrustDefaults`, but we honour the safety level
    /// defensively in case future trust overrides flip a row to protected.
    public var selectableIDs: [String] {
        files.filter { $0.safety != .protected_ }.map(\.id)
    }
}

public extension DuplicateGroup {
    /// Tri-state selection summary matching `ScanGroup.selectionState`. Reused
    /// here so the group-header checkbox behaves identically to the one in
    /// `ScanBucketView`.
    func selectionState(selectedIDs: Set<String>) -> GroupSelectionState {
        let ids = selectableIDs
        guard !ids.isEmpty else { return .allProtected }
        let hits = ids.filter { selectedIDs.contains($0) }.count
        if hits == 0 { return .none }
        if hits == ids.count { return .all }
        return .partial
    }

    /// Reclaimable bytes for this group given the current selection. The user
    /// explicitly picks which copies to trash, so this is simply
    /// `sum(size of selected files)` — we do not subtract a "keep one" copy.
    /// Overflow-clamped at `Int64.max`.
    func reclaimableBytes(selectedIDs: Set<String>) -> Int64 {
        files.filter { selectedIDs.contains($0.id) }
            .reduce(Int64(0)) { sum, result in
                let (next, overflow) = sum.addingReportingOverflow(result.size)
                return overflow ? Int64.max : next
            }
    }
}

// MARK: - DuplicateGrouper

public enum DuplicateGrouper {
    /// Reshape a flat list of fclones-tagged `ScanResult`s into `DuplicateGroup`s.
    ///
    /// Groups are identified by the `fclones_group_<id>` tag written by
    /// `FclonesAdapter`. Rows missing that tag are dropped — the Duplicate
    /// Finder surface is fclones-specific by design. Groups are sorted by
    /// `reclaimableCeilingBytes` descending so the biggest piles float to the
    /// top; within each group, files are sorted by path ascending for a stable
    /// "first" pick used by the "Keep one" quick action.
    public static func group(_ results: [ScanResult]) -> [DuplicateGroup] {
        var filesByID: [String: [ScanResult]] = [:]
        var hashByID: [String: String] = [:]
        var orderByID: [String: Int] = [:]

        for result in results {
            guard let groupTag = result.tags.first(where: { $0.hasPrefix("fclones_group_") }) else {
                continue
            }
            if filesByID[groupTag] == nil {
                orderByID[groupTag] = orderByID.count
            }
            filesByID[groupTag, default: []].append(result)
            if hashByID[groupTag] == nil,
               let hashTag = result.tags.first(where: { $0.hasPrefix("fclones_hash_") }) {
                hashByID[groupTag] = String(hashTag.dropFirst("fclones_hash_".count))
            }
        }

        let groups = filesByID.map { id, files -> DuplicateGroup in
            let sorted = files.sorted { $0.path < $1.path }
            return DuplicateGroup(
                id: id,
                shortHash: hashByID[id] ?? "",
                files: sorted,
                perFileSize: sorted.first?.size ?? 0
            )
        }

        return groups.sorted { lhs, rhs in
            if lhs.reclaimableCeilingBytes != rhs.reclaimableCeilingBytes {
                return lhs.reclaimableCeilingBytes > rhs.reclaimableCeilingBytes
            }
            // Stable fallback when two groups reclaim the same bytes: preserve
            // the order they first appeared in the input.
            return (orderByID[lhs.id] ?? 0) < (orderByID[rhs.id] ?? 0)
        }
    }
}

// MARK: - Refresh prune

public enum DuplicateFinderRefresh {
    /// Prune `results` against the set of paths that still exist on disk.
    ///
    /// Drops any row whose path is no longer present, then drops every row
    /// whose `fclones_group_<id>` group falls below 2 surviving members (a
    /// single-file "duplicate" is meaningless). Pure — caller is responsible
    /// for performing the filesystem existence checks (so this stays trivially
    /// testable and so the view can do the IO off the main actor).
    public static func prune(
        results: [ScanResult],
        existingPaths: Set<String>
    ) -> [ScanResult] {
        let surviving = results.filter { existingPaths.contains($0.path) }

        var countByGroup: [String: Int] = [:]
        for result in surviving {
            guard let groupTag = result.tags.first(where: { $0.hasPrefix("fclones_group_") }) else {
                continue
            }
            countByGroup[groupTag, default: 0] += 1
        }

        return surviving.filter { result in
            guard let groupTag = result.tags.first(where: { $0.hasPrefix("fclones_group_") }) else {
                // Untagged rows shouldn't reach the duplicate finder, but if
                // they do, drop them rather than try to render them ungrouped.
                return false
            }
            return (countByGroup[groupTag] ?? 0) >= 2
        }
    }

    /// Sanitize `selectedIDs` against a fresh `results` list. Drops any id
    /// that no longer corresponds to a row, so refresh + rescan can't leave
    /// the action bar pointing at vanished files.
    public static func sanitizeSelection(
        selectedIDs: Set<String>,
        against results: [ScanResult]
    ) -> Set<String> {
        let valid = Set(results.map(\.id))
        return selectedIDs.intersection(valid)
    }
}

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
    ) -> (groups: Int, files: Int, reclaimableBytes: Int64) {
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
        return (groups: hiddenGroups.count, files: hidden.count, reclaimableBytes: bytes)
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

// MARK: - Selection helpers

public enum DuplicateFinderSelection {
    /// Total reclaimable bytes across all groups for the current selection.
    /// Overflow-clamped at `Int64.max`.
    public static func totalReclaimableBytes(
        groups: [DuplicateGroup],
        selectedIDs: Set<String>
    ) -> Int64 {
        groups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(
                group.reclaimableBytes(selectedIDs: selectedIDs)
            )
            return overflow ? Int64.max : next
        }
    }

    /// Deterministic "keep the first, trash the rest" selection for a single
    /// group. "First" is defined by `DuplicateGrouper`'s path-ascending sort,
    /// so the choice is stable across runs. Protected files are never
    /// selected for trash — they are filtered out of the candidate set.
    public static func selectAllButFirst(in group: DuplicateGroup) -> Set<String> {
        guard group.files.count >= 2 else { return [] }
        return Set(
            group.files
                .dropFirst()
                .filter { $0.safety != .protected_ }
                .map(\.id)
        )
    }
}

// MARK: - Cross-view change notifications

extension Notification.Name {
    /// Posted by `PersonalScopeSettingsViewModel` after a successful add or
    /// remove. `DuplicateFinderView` listens to refresh its persisted roots
    /// and recompute the visible derivation without a rescan.
    public static let gargantuaPersonalScopeRootsChanged = Notification.Name(
        "GargantuaPersonalScopeRootsChanged"
    )
}
