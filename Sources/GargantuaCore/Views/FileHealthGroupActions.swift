import Foundation

/// Pure selection helpers for File Health's per-group bulk actions on
/// similarity categories (Similar Images, Similar Videos).
///
/// Each helper returns the set of `ScanResult.id`s that should be sent to
/// Trash for one cluster — never mutates state directly so the same logic can
/// be exercised under test without driving SwiftUI.
///
/// The Trust Layer is preserved by keeping a "keep at least one member"
/// invariant on `keepLargest` / `keepNewest`: whichever member is judged best
/// is retained, and only the rest are queued. `trashAll` is the explicit
/// opt-out for users who want every copy gone.
public enum FileHealthGroupActions {
    /// Stable tie-breaker for ranking results: when the primary key (size or
    /// last-accessed date) is equal between two findings, fall back to the
    /// finding's id so ordering is deterministic across runs.
    private static func stableTieBreak(_ lhs: ScanResult, _ rhs: ScanResult) -> Bool {
        lhs.id < rhs.id
    }

    /// Members of `group` with the single largest-size member removed. Ties
    /// on size are broken by id for stability — the lowest-id finding wins
    /// the "keep" slot, the rest queue for trash.
    ///
    /// If `group` has 0 or 1 members, returns an empty set: there is nothing
    /// to discard while preserving "keep one."
    public static func keepLargest(in group: [ScanResult]) -> Set<String> {
        guard group.count > 1 else { return [] }
        let keeper = group.max(by: { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            return !stableTieBreak(lhs, rhs)
        })
        guard let keeperID = keeper?.id else { return [] }
        return Set(group.lazy.map(\.id).filter { $0 != keeperID })
    }

    /// Members of `group` with the most recently accessed member removed.
    ///
    /// Members without a `lastAccessed` timestamp are treated as oldest, so
    /// they sort behind any timestamped member. Ties on timestamp fall back
    /// to id stability. If no member has a `lastAccessed` value at all, this
    /// returns the same set as `keepLargest` — the user still gets a keeper,
    /// chosen by file size, instead of an action that silently no-ops or
    /// queues every copy.
    public static func keepNewest(in group: [ScanResult]) -> Set<String> {
        guard group.count > 1 else { return [] }
        let anyTimestamped = group.contains { $0.lastAccessed != nil }
        guard anyTimestamped else { return keepLargest(in: group) }

        let keeper = group.max(by: { lhs, rhs in
            let lhsDate = lhs.lastAccessed ?? .distantPast
            let rhsDate = rhs.lastAccessed ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return !stableTieBreak(lhs, rhs)
        })
        guard let keeperID = keeper?.id else { return [] }
        return Set(group.lazy.map(\.id).filter { $0 != keeperID })
    }

    /// All members of `group`. Used for the explicit "Trash all" action.
    public static func trashAll(in group: [ScanResult]) -> Set<String> {
        Set(group.map(\.id))
    }
}

// MARK: - Tab grouping

extension FileHealthCategoryTab {
    /// One contiguous slice of a tab's findings sharing a single czkawka
    /// group ID, paired with the display-time `GroupContext` so the UI can
    /// render headers with a 1-based "Group N · M copies" label.
    ///
    /// `groupedFindings(filteredBy:)` returns these in the same first-
    /// appearance order as the underlying findings array, so a filtered tab
    /// keeps the same group ordering the user saw before typing into the
    /// path filter.
    public struct GroupSection: Identifiable {
        public let context: GroupContext
        public let findings: [ScanResult]

        public var id: Int { context.index }
        public var totalSize: Int64 {
            findings.reduce(Int64(0)) { sum, item in
                let (next, overflow) = sum.addingReportingOverflow(item.size)
                return overflow ? Int64.max : next
            }
        }
    }

    /// Segment `findings` into per-group sections preserving first-appearance
    /// order. Findings without a czkawka group id (shouldn't happen for
    /// grouped categories, but defensively keep them out of the segmenter)
    /// are dropped — segmentation only applies to similarity clusters.
    ///
    /// `findings` is typically `filteredFindings(for:)` output, so the same
    /// search-narrowing the user sees applies before grouping.
    public func groupedFindings(filteredBy findings: [ScanResult]) -> [GroupSection] {
        var sections: [Int: [ScanResult]] = [:]
        var ordered: [Int] = []
        for finding in findings {
            guard let context = groupContext(for: finding) else { continue }
            if sections[context.index] == nil {
                sections[context.index] = []
                ordered.append(context.index)
            }
            sections[context.index]?.append(finding)
        }
        return ordered.compactMap { index in
            guard let members = sections[index], !members.isEmpty else { return nil }
            // Re-derive context with the *filtered* count so a partial filter
            // shows "3 of 5" via the surrounding UI rather than a wrong "5"
            // in the header — caller still sees the original tab-wide count
            // via groupContext(for:) on a single finding.
            let context = GroupContext(index: index, count: members.count)
            return GroupSection(context: context, findings: members)
        }
    }
}
