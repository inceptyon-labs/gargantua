import Foundation

/// A dashboard alert representing a group of reclaimable scan results in one category.
///
/// AlertItems aggregate individual ``ScanResult``s into human-readable alerts like
/// "23 GB of stale dev artifacts (>30 days)". Each links to the relevant cleanup screen.
public struct AlertItem: Sendable, Identifiable {
    public let id: String
    /// Total reclaimable bytes across all items in this alert.
    public let reclaimableSize: Int64
    /// Number of individual scan results aggregated into this alert.
    public let itemCount: Int
    /// Scan category that groups these items (e.g., "dev_artifacts").
    public let category: String
    /// Human-readable category label (e.g., "stale dev artifacts").
    public let categoryLabel: String
    /// Optional staleness qualifier (e.g., ">30 days").
    public let staleness: String?
    /// Which cleanup screen handles this category.
    public let destination: AlertDestination

    public init(
        id: String,
        reclaimableSize: Int64,
        itemCount: Int,
        category: String,
        categoryLabel: String,
        staleness: String? = nil,
        destination: AlertDestination
    ) {
        self.id = id
        self.reclaimableSize = reclaimableSize
        self.itemCount = itemCount
        self.category = category
        self.categoryLabel = categoryLabel
        self.staleness = staleness
        self.destination = destination
    }

    /// Formatted headline: "23 GB of stale dev artifacts (>30 days)"
    public var headline: String {
        let size = AlertItem.formatBytes(reclaimableSize)
        if let staleness {
            return "\(size) of \(categoryLabel) (\(staleness))"
        }
        return "\(size) of \(categoryLabel)"
    }

    /// Detail line: "45 items"
    public var detail: String {
        itemCount == 1 ? "1 item" : "\(itemCount) items"
    }
}

// MARK: - AlertDestination

/// Navigation target for an alert — maps to a cleanup screen.
public enum AlertDestination: String, Sendable {
    case deepClean
    case devPurge
    case diskExplorer
}

// MARK: - Category Metadata

/// Maps scan categories to display labels and navigation destinations.
private struct CategoryMeta {
    let label: String
    let destination: AlertDestination

    static let lookup: [String: CategoryMeta] = [
        "browser_cache":   CategoryMeta(label: "browser cache",       destination: .deepClean),
        "browser_data":    CategoryMeta(label: "browser data",        destination: .deepClean),
        "system_cache":    CategoryMeta(label: "system cache",        destination: .deepClean),
        "system_logs":     CategoryMeta(label: "system logs",         destination: .deepClean),
        "temp_files":      CategoryMeta(label: "temporary files",     destination: .deepClean),
        "trash":           CategoryMeta(label: "Trash items",         destination: .deepClean),
        "dev_artifacts":   CategoryMeta(label: "dev artifacts",       destination: .devPurge),
        "docker":          CategoryMeta(label: "Docker data",         destination: .devPurge),
        "homebrew":        CategoryMeta(label: "Homebrew cache",      destination: .devPurge),
        "installers":      CategoryMeta(label: "old installers",      destination: .deepClean),
        "similar_images":  CategoryMeta(label: "similar images",      destination: .deepClean),
        "empty_files":     CategoryMeta(label: "empty files",         destination: .deepClean),
        "broken_symlinks": CategoryMeta(label: "broken symlinks",     destination: .deepClean),
    ]
}

// MARK: - Aggregation

extension AlertItem {
    /// Aggregate scan results into dashboard alerts, grouped by category.
    ///
    /// Only actionable items (safe + review) are included. Protected items
    /// don't generate alerts since they require explicit user action.
    ///
    /// Results are sorted by reclaimable size descending — biggest savings first.
    public static func aggregate(
        from results: [ScanResult],
        referenceDate: Date = Date()
    ) -> [AlertItem] {
        // Filter to actionable items only
        let actionable = results.filter { $0.safety.isActionable }

        // Group by category
        let grouped = Dictionary(grouping: actionable) { $0.category }

        var alerts: [AlertItem] = []
        for (category, items) in grouped {
            let totalSize = items.reduce(Int64(0)) { $0 + $1.size }
            guard totalSize > 0 else { continue }

            let meta = CategoryMeta.lookup[category]
            let label = meta?.label ?? category.replacingOccurrences(of: "_", with: " ")
            let destination = meta?.destination ?? .deepClean

            // Compute staleness from oldest lastAccessed date
            let staleness = Self.computeStaleness(items: items, referenceDate: referenceDate)
            let stalePrefix = staleness != nil ? "stale " : ""

            alerts.append(AlertItem(
                id: "alert_\(category)",
                reclaimableSize: totalSize,
                itemCount: items.count,
                category: category,
                categoryLabel: "\(stalePrefix)\(label)",
                staleness: staleness,
                destination: destination
            ))
        }

        return alerts.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    /// Compute a staleness qualifier from item access dates.
    ///
    /// If all items in the group were last accessed more than 7 days ago,
    /// returns a qualifier like ">30 days". Uses the most recent access
    /// date as the threshold (conservative — "at least this stale").
    private static func computeStaleness(items: [ScanResult], referenceDate: Date) -> String? {
        let accessDates = items.compactMap(\.lastAccessed)
        guard !accessDates.isEmpty else { return nil }

        // Most recent access = minimum staleness for the group
        guard let mostRecent = accessDates.max() else { return nil }
        let daysSince = Calendar.current.dateComponents([.day], from: mostRecent, to: referenceDate).day ?? 0

        guard daysSince >= 7 else { return nil }

        if daysSince >= 365 {
            let years = daysSince / 365
            return ">\(years) year\(years == 1 ? "" : "s")"
        } else if daysSince >= 30 {
            let months = daysSince / 30
            return ">\(months) month\(months == 1 ? "" : "s")"
        } else {
            return ">\(daysSince) days"
        }
    }
}

// MARK: - Size Formatting

extension AlertItem {
    /// Format bytes into a human-readable string with appropriate unit.
    ///
    /// Uses base-10 (SI) units to match macOS Finder behavior:
    /// - Under 1 KB: "123 bytes"
    /// - Under 1 MB: "4.2 KB"
    /// - Under 1 GB: "128 MB"
    /// - Under 1 TB: "23.4 GB"
    /// - 1 TB and above: "1.2 TB"
    public static func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)

        switch absBytes {
        case 0..<1_000:
            return "\(bytes) bytes"
        case 1_000..<1_000_000:
            let kb = Double(bytes) / 1_000
            return kb >= 10 ? "\(Int(kb)) KB" : String(format: "%.1f KB", kb)
        case 1_000_000..<1_000_000_000:
            let mb = Double(bytes) / 1_000_000
            return mb >= 10 ? "\(Int(mb)) MB" : String(format: "%.1f MB", mb)
        case 1_000_000_000..<1_000_000_000_000:
            let gb = Double(bytes) / 1_000_000_000
            return gb >= 10 ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
        default:
            let tb = Double(bytes) / 1_000_000_000_000
            return tb >= 10 ? "\(Int(tb)) TB" : String(format: "%.1f TB", tb)
        }
    }
}
