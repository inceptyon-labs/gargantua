import CoreGraphics

struct DiskTreemapTile: Identifiable {
    let item: DirectoryItem
    let rect: CGRect

    var id: String { item.id }
}

/// Squarified treemap layout (Bruls, Huijsen, van Wijk 1999).
///
/// Items are packed into rows along the shorter side of the remaining rectangle,
/// greedily extending each row while doing so improves the worst tile aspect
/// ratio. The result keeps tiles close to square instead of degenerating into
/// thin slivers, which is essential for legibility at the small end of the
/// distribution where folder labels would otherwise clip.
enum DiskTreemapLayout {
    private struct WeightedItem {
        let item: DirectoryItem
        let weight: Double
    }

    static func tiles(for items: [DirectoryItem], in bounds: CGRect) -> [DiskTreemapTile] {
        let bounds = bounds.standardized
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let weighted = weightedItems(for: items)
        guard !weighted.isEmpty else { return [] }

        // Normalize weights so total weight == bounds area; the squarified
        // algorithm below treats weights as pixel area directly.
        let totalWeight = weighted.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return [] }
        let totalArea = Double(bounds.width) * Double(bounds.height)
        let scale = totalArea / totalWeight
        let normalized = weighted.map { WeightedItem(item: $0.item, weight: $0.weight * scale) }

        var output: [DiskTreemapTile] = []
        squarify(items: normalized, current: [], remaining: bounds, output: &output)
        return output
    }

    private static func weightedItems(for items: [DirectoryItem]) -> [WeightedItem] {
        let positiveTotal = items.reduce(0.0) { total, item in
            total + max(Double(item.size), 0)
        }
        let affordanceCount = items.filter { $0.size <= 0 && ($0.isPermissionDenied || $0.isSizing) }.count
        let affordanceWeight = positiveTotal > 0
            ? max(positiveTotal * 0.03 / Double(max(affordanceCount, 1)), 1)
            : 1

        return items.compactMap { item -> WeightedItem? in
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
    }

    private static func squarify(
        items: [WeightedItem],
        current: [WeightedItem],
        remaining: CGRect,
        output: inout [DiskTreemapTile]
    ) {
        let side = Double(min(remaining.width, remaining.height))
        guard side > 0 else { return }

        guard let head = items.first else {
            if !current.isEmpty {
                layoutRow(current, in: remaining, output: &output)
            }
            return
        }

        let next = current + [head]
        let stayWorst = current.isEmpty ? .infinity : worstAspect(current, side: side)
        let extendWorst = worstAspect(next, side: side)

        if current.isEmpty || extendWorst <= stayWorst {
            squarify(
                items: Array(items.dropFirst()),
                current: next,
                remaining: remaining,
                output: &output
            )
        } else {
            let leftover = layoutRow(current, in: remaining, output: &output)
            squarify(items: items, current: [], remaining: leftover, output: &output)
        }
    }

    /// Worst-case aspect ratio (>= 1, lower is better) across all tiles in
    /// the candidate row when laid along `side`.
    private static func worstAspect(_ row: [WeightedItem], side: Double) -> Double {
        let sum = row.reduce(0.0) { $0 + $1.weight }
        guard sum > 0, side > 0 else { return .infinity }
        let s2 = side * side
        let r2 = sum * sum
        var worst = 0.0
        for item in row where item.weight > 0 {
            let a = (s2 * item.weight) / r2
            let b = r2 / (s2 * item.weight)
            worst = max(worst, max(a, b))
        }
        return worst == 0 ? .infinity : worst
    }

    /// Lay `row` along the shorter side of `rect` and return the rectangle
    /// remaining after the strip is consumed.
    @discardableResult
    private static func layoutRow(
        _ row: [WeightedItem],
        in rect: CGRect,
        output: inout [DiskTreemapTile]
    ) -> CGRect {
        let sum = row.reduce(0.0) { $0 + $1.weight }
        guard sum > 0, rect.width > 0, rect.height > 0 else { return rect }

        if rect.width >= rect.height {
            // Lay row as a vertical strip on the left edge.
            let stripWidth = min(CGFloat(sum / Double(rect.height)), rect.width)
            var y = rect.minY
            for (index, item) in row.enumerated() {
                let isLast = index == row.count - 1
                let h = isLast
                    ? rect.maxY - y
                    : CGFloat(item.weight / sum) * rect.height
                output.append(DiskTreemapTile(
                    item: item.item,
                    rect: CGRect(x: rect.minX, y: y, width: stripWidth, height: h)
                ))
                y += h
            }
            return CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(rect.width - stripWidth, 0),
                height: rect.height
            )
        } else {
            // Lay row as a horizontal strip on the top edge.
            let stripHeight = min(CGFloat(sum / Double(rect.width)), rect.height)
            var x = rect.minX
            for (index, item) in row.enumerated() {
                let isLast = index == row.count - 1
                let w = isLast
                    ? rect.maxX - x
                    : CGFloat(item.weight / sum) * rect.width
                output.append(DiskTreemapTile(
                    item: item.item,
                    rect: CGRect(x: x, y: rect.minY, width: w, height: stripHeight)
                ))
                x += w
            }
            return CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(rect.height - stripHeight, 0)
            )
        }
    }
}
