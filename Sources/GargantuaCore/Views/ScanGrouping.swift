import Foundation

/// How the Deep Clean results list is segmented for viewing.
public enum ScanGroupingMode: String, CaseIterable, Identifiable, Sendable {
    case safety
    case folder
    case category

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .safety:   return "Safety"
        case .folder:   return "Folder"
        case .category: return "Category"
        }
    }
}

/// The source dimension a `ScanGroup` was built from. Used by the renderer to
/// pick icons and decide whether to treat the whole group as protected.
public enum ScanGroupKind: Equatable, Sendable {
    case safety(SafetyLevel)
    case folder(path: String)
    case category(name: String)
}

/// A named slice of `ScanResult`s for the list view, with a stable id suitable
/// for use as a `@State` key across mode toggles.
public struct ScanGroup: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let kind: ScanGroupKind
    public let items: [ScanResult]

    public var count: Int { items.count }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// IDs of items eligible for bulk selection — protected rows are skipped
    /// since they can never be cleaned.
    public var selectableIDs: [String] {
        items.filter { $0.safety != .protected_ }.map(\.id)
    }
}

/// Tri-state selection summary for a group. Drives the group-header checkbox.
public enum GroupSelectionState: Equatable {
    /// Every group item is protected — no checkbox should be shown.
    case allProtected
    /// At least one selectable item exists; none are currently selected.
    case none
    /// Some (not all) selectable items are selected.
    case partial
    /// Every selectable item in the group is selected.
    case all
}

public extension ScanGroup {
    func selectionState(selectedIDs: Set<String>) -> GroupSelectionState {
        let ids = selectableIDs
        guard !ids.isEmpty else { return .allProtected }
        let hits = ids.filter { selectedIDs.contains($0) }.count
        if hits == 0 { return .none }
        if hits == ids.count { return .all }
        return .partial
    }
}

public enum ScanGrouper {
    public static func group(_ results: [ScanResult], mode: ScanGroupingMode) -> [ScanGroup] {
        switch mode {
        case .safety:   return groupBySafety(results)
        case .folder:   return groupByFolder(results)
        case .category: return groupByCategory(results)
        }
    }

    static func groupBySafety(_ results: [ScanResult]) -> [ScanGroup] {
        let grouped = Dictionary(grouping: results) { $0.safety }
        return SafetyLevel.allCases.map { level in
            let items = (grouped[level] ?? []).sorted { $0.size > $1.size }
            return ScanGroup(
                id: "safety:\(level)",
                title: title(forSafety: level),
                subtitle: nil,
                kind: .safety(level),
                items: items
            )
        }
    }

    static func groupByFolder(_ results: [ScanResult]) -> [ScanGroup] {
        let grouped = Dictionary(grouping: results) { result in
            URL(fileURLWithPath: result.path).deletingLastPathComponent().path
        }
        return grouped.map { key, items in
            let sorted = items.sorted { $0.size > $1.size }
            let leaf = URL(fileURLWithPath: key).lastPathComponent
            return ScanGroup(
                id: "folder:\(key)",
                title: leaf.isEmpty ? key : leaf,
                subtitle: abbreviateHomePath(key),
                kind: .folder(path: key),
                items: sorted
            )
        }.sorted { $0.totalSize > $1.totalSize }
    }

    static func groupByCategory(_ results: [ScanResult]) -> [ScanGroup] {
        let grouped = Dictionary(grouping: results) { $0.category }
        return grouped.map { key, items in
            let sorted = items.sorted { $0.size > $1.size }
            return ScanGroup(
                id: "category:\(key)",
                title: prettyScanCategory(key) ?? key,
                subtitle: nil,
                kind: .category(name: key),
                items: sorted
            )
        }.sorted { $0.totalSize > $1.totalSize }
    }

    private static func title(forSafety level: SafetyLevel) -> String {
        switch level {
        case .safe:       return "Safe to Clean"
        case .review:     return "Review Required"
        case .protected_: return "Protected"
        }
    }
}
