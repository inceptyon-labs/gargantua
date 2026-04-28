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
