import CoreGraphics

struct DiskTreemapTile: Identifiable {
    let item: DirectoryItem
    let rect: CGRect

    var id: String { item.id }
}

enum DiskTreemapLayout {
    private struct WeightedItem {
        let item: DirectoryItem
        let weight: Double
    }

    static func tiles(for items: [DirectoryItem], in bounds: CGRect) -> [DiskTreemapTile] {
        let bounds = bounds.standardized
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let weightedItems = weightedItems(for: items)
        guard !weightedItems.isEmpty else { return [] }

        return split(weightedItems, in: bounds)
    }

    private static func weightedItems(for items: [DirectoryItem]) -> [WeightedItem] {
        let positiveTotal = items.reduce(0.0) { total, item in
            total + max(Double(item.size), 0)
        }
        let affordanceCount = items.filter { $0.size <= 0 && ($0.isPermissionDenied || $0.isSizing) }.count
        let affordanceWeight = positiveTotal > 0
            ? max(positiveTotal * 0.03 / Double(max(affordanceCount, 1)), 1)
            : 1

        let weighted = items.compactMap { item -> WeightedItem? in
            if item.size > 0 {
                return WeightedItem(item: item, weight: Double(item.size))
            }
            if item.isPermissionDenied || item.isSizing {
                return WeightedItem(item: item, weight: affordanceWeight)
            }
            if positiveTotal == 0 {
                return WeightedItem(item: item, weight: 1)
            }
            return nil
        }

        return weighted
    }

    private static func split(_ items: [WeightedItem], in bounds: CGRect) -> [DiskTreemapTile] {
        guard let first = items.first else { return [] }
        guard items.count > 1 else {
            return [DiskTreemapTile(item: first.item, rect: bounds)]
        }

        let totalWeight = items.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return [] }

        let splitIndex = balancedSplitIndex(for: items, target: totalWeight / 2)
        let leadingItems = Array(items[..<splitIndex])
        let trailingItems = Array(items[splitIndex...])
        let leadingWeight = leadingItems.reduce(0.0) { $0 + $1.weight }
        let leadingFraction = CGFloat(leadingWeight / totalWeight)

        let leadingRect: CGRect
        let trailingRect: CGRect

        if bounds.width >= bounds.height {
            let leadingWidth = bounds.width * leadingFraction
            leadingRect = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: leadingWidth,
                height: bounds.height
            )
            trailingRect = CGRect(
                x: bounds.minX + leadingWidth,
                y: bounds.minY,
                width: bounds.width - leadingWidth,
                height: bounds.height
            )
        } else {
            let leadingHeight = bounds.height * leadingFraction
            leadingRect = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: leadingHeight
            )
            trailingRect = CGRect(
                x: bounds.minX,
                y: bounds.minY + leadingHeight,
                width: bounds.width,
                height: bounds.height - leadingHeight
            )
        }

        return split(leadingItems, in: leadingRect) + split(trailingItems, in: trailingRect)
    }

    private static func balancedSplitIndex(for items: [WeightedItem], target: Double) -> Int {
        var running = 0.0
        var bestIndex = 1
        var bestDistance = Double.greatestFiniteMagnitude

        for index in 0..<(items.count - 1) {
            running += items[index].weight
            let distance = abs(target - running)
            if distance <= bestDistance {
                bestDistance = distance
                bestIndex = index + 1
            } else {
                break
            }
        }

        return min(max(bestIndex, 1), items.count - 1)
    }
}
