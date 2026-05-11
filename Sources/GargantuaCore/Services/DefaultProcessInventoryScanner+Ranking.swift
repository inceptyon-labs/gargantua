import Foundation

extension DefaultProcessInventoryScanner {
    /// Single-source-of-truth ordering used by both the scanner and the
    /// session's in-place `resort`. Mirrored in `ProcessInventorySession.rank`
    /// — keep them in sync if the comparators change.
    func rank(_ items: [ProcessItem], by metric: ProcessSortMetric) -> [ProcessItem] {
        items.sorted(by: { lhs, rhs in
            let lhsPrimary = Self.primary(lhs, metric: metric)
            let rhsPrimary = Self.primary(rhs, metric: metric)
            if lhsPrimary != rhsPrimary { return lhsPrimary > rhsPrimary }
            let lhsSecondary = Self.secondary(lhs, metric: metric)
            let rhsSecondary = Self.secondary(rhs, metric: metric)
            if lhsSecondary != rhsSecondary { return lhsSecondary > rhsSecondary }
            let nameCmp = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id < rhs.id
        })
    }

    func rankSamples(
        _ samples: [RawProcessSample],
        firstByPID: [Int32: RawProcessSample],
        metric: ProcessSortMetric,
        topN: Int?
    ) -> [RawProcessSample] {
        let ranked = samples.sorted { lhs, rhs in
            let lhsPrior = comparablePrior(for: lhs, in: firstByPID)
            let rhsPrior = comparablePrior(for: rhs, in: firstByPID)
            let lhsPrimary = samplePrimary(lhs, prior: lhsPrior, metric: metric)
            let rhsPrimary = samplePrimary(rhs, prior: rhsPrior, metric: metric)
            if lhsPrimary != rhsPrimary { return lhsPrimary > rhsPrimary }
            let lhsSecondary = sampleSecondary(lhs, prior: lhsPrior, metric: metric)
            let rhsSecondary = sampleSecondary(rhs, prior: rhsPrior, metric: metric)
            if lhsSecondary != rhsSecondary { return lhsSecondary > rhsSecondary }
            let nameCmp = lhs.command.localizedCaseInsensitiveCompare(rhs.command)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            let lhsPath = lhs.executablePath ?? ""
            let rhsPath = rhs.executablePath ?? ""
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            if lhs.startTimeUnixSeconds != rhs.startTimeUnixSeconds {
                return lhs.startTimeUnixSeconds < rhs.startTimeUnixSeconds
            }
            return lhs.pid < rhs.pid
        }
        guard let topN, topN > 0 else { return ranked }
        return Array(ranked.prefix(topN))
    }

    private func samplePrimary(
        _ sample: RawProcessSample,
        prior: RawProcessSample?,
        metric: ProcessSortMetric
    ) -> Double {
        switch metric {
        case .cpu: computeCPUFraction(prior: prior, current: sample)
        case .rss: Double(sample.residentBytes)
        }
    }

    private func sampleSecondary(
        _ sample: RawProcessSample,
        prior: RawProcessSample?,
        metric: ProcessSortMetric
    ) -> Double {
        switch metric {
        case .cpu: Double(sample.residentBytes)
        case .rss: computeCPUFraction(prior: prior, current: sample)
        }
    }

    static func primary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: item.cpuFraction
        case .rss: Double(item.residentBytes)
        }
    }

    static func secondary(_ item: ProcessItem, metric: ProcessSortMetric) -> Double {
        switch metric {
        case .cpu: Double(item.residentBytes)
        case .rss: item.cpuFraction
        }
    }
}
