import Foundation

extension DiskExplorerView {
    /// Bundle directories whose size is < 1% of the largest into a single
    /// synthetic "Others" tile. Avoids the ant-farm of unidentifiable
    /// 60×60-pixel icons that plague treemaps of skewed distributions.
    static func collapseSmall(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let sized = items.filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
        guard let largest = sized.map(\.size).max(), largest > 0 else { return items }

        let threshold = max(largest / 100, 1)
        var kept: [DirectoryItem] = []
        var aggregated: [DirectoryItem] = []

        for item in items {
            if item.isPermissionDenied || item.isSizing || item.isFilesAggregate {
                kept.append(item)
                continue
            }
            if item.size < threshold {
                aggregated.append(item)
            } else {
                kept.append(item)
            }
        }

        // Only collapse when it's worth it — a single small item gets a normal
        // tile rather than a misleading "Others (1)" wrapper.
        guard aggregated.count >= 2 else { return items }

        let totalSize = aggregated.reduce(0) { $0 + $1.size }
        let aggregateName = "Others (\(aggregated.count))"
        let parentPath = aggregated.first?.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/") ?? ""
        let aggregatePath = "/\(parentPath)#others"
        kept.append(DirectoryItem(
            name: aggregateName,
            path: aggregatePath,
            size: totalSize,
            isOthersAggregate: true
        ))
        return kept
    }
}
