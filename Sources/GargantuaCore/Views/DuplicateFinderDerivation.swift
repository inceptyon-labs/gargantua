import Foundation

// MARK: - Memoized derivation

/// Snapshot of every value the body needs from `(results, includeManaged)`.
/// Computed once per change of those inputs and cached in `@State` so scroll
/// frames don't re-run filter + grouper. Replaces a previous shape where each
/// view-property access ran the O(N) filter pipeline.
struct DuplicateFinderDerivation {
    let visibleResults: [ScanResult]
    let groups: [DuplicateGroup]
    let hidden: DuplicateFinderHiddenSummary
    let totalReclaimableCeiling: Int64
    let selectableByID: [String: ScanResult]

    static let empty = DuplicateFinderDerivation(
        visibleResults: [],
        groups: [],
        hidden: DuplicateFinderHiddenSummary(groups: 0, files: 0, reclaimableBytes: 0),
        totalReclaimableCeiling: 0,
        selectableByID: [:]
    )

    static func compute(
        results: [ScanResult],
        showEverything: Bool,
        personalRoots configuredRoots: [URL]? = nil
    ) -> DuplicateFinderDerivation {
        let personalRoots: [URL]?
        if showEverything {
            personalRoots = nil
        } else if let configured = configuredRoots, !configured.isEmpty {
            personalRoots = configured
        } else {
            personalRoots = DuplicateFinderScopeFilter.defaultPersonalRoots()
        }
        let visible = DuplicateFinderScopeFilter.apply(
            to: results,
            personalRoots: personalRoots,
            excludeManaged: !showEverything
        )
        let groups = DuplicateGrouper.group(visible)

        // Derive hidden via id-set difference instead of re-running the filter.
        let visibleIDs = Set(visible.map(\.id))
        let hiddenResults = results.filter { !visibleIDs.contains($0.id) }
        let hiddenGroups = DuplicateGrouper.group(hiddenResults)
        let hiddenBytes = hiddenGroups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }

        let ceiling = groups.reduce(Int64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.reclaimableCeilingBytes)
            return overflow ? Int64.max : next
        }

        var selectable: [String: ScanResult] = [:]
        for group in groups {
            for file in group.files where file.safety != .protected_ {
                selectable[file.id] = file
            }
        }

        return DuplicateFinderDerivation(
            visibleResults: visible,
            groups: groups,
            hidden: DuplicateFinderHiddenSummary(
                groups: hiddenGroups.count,
                files: hiddenResults.count,
                reclaimableBytes: hiddenBytes
            ),
            totalReclaimableCeiling: ceiling,
            selectableByID: selectable
        )
    }
}

public struct DuplicateFinderHiddenSummary: Sendable, Equatable {
    public let groups: Int
    public let files: Int
    public let reclaimableBytes: Int64

    public init(groups: Int, files: Int, reclaimableBytes: Int64) {
        self.groups = groups
        self.files = files
        self.reclaimableBytes = reclaimableBytes
    }
}
