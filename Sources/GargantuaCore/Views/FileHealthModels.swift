import Foundation

// MARK: - Display Metadata

extension CzkawkaCategory {
    /// Human-readable label used as the File Health tab title.
    public var displayName: String {
        switch self {
        case .emptyFiles: "Empty Files"
        case .emptyFolders: "Empty Folders"
        case .brokenSymlinks: "Broken Symlinks"
        case .temporaryFiles: "Temporary Files"
        case .bigFiles: "Big Files"
        case .similarImages: "Similar Images"
        case .similarVideos: "Similar Videos"
        case .brokenFiles: "Broken / Corrupt"
        }
    }

    /// SF Symbol used on the File Health tab for this category.
    public var iconName: String {
        switch self {
        case .emptyFiles: "doc"
        case .emptyFolders: "folder"
        case .brokenSymlinks: "link"
        case .temporaryFiles: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .bigFiles: "externaldrive"
        case .similarImages: "photo.on.rectangle"
        case .similarVideos: "film"
        case .brokenFiles: "exclamationmark.triangle"
        }
    }
}

// MARK: - Tab Model

/// A single File Health tab: a czkawka category that produced at least one
/// finding in the most recent scan.
///
/// Fed by ``FileHealthGrouper`` from a flat `[ScanResult]` — one tab per
/// category string present in the results, with Trust Layer display metadata
/// (label, icon, safety) attached.
public struct FileHealthCategoryTab: Identifiable {
    public let id: String
    public let category: CzkawkaCategory
    public let safety: SafetyLevel
    public let findings: [ScanResult]

    public init(
        category: CzkawkaCategory,
        safety: SafetyLevel,
        findings: [ScanResult]
    ) {
        self.id = category.rawValue
        self.category = category
        self.safety = safety
        self.findings = findings
    }

    public var label: String { category.displayName }
    public var iconName: String { category.iconName }
    public var count: Int { findings.count }

    public var totalSize: Int64 {
        findings.reduce(Int64(0)) { sum, item in
            let (next, overflow) = sum.addingReportingOverflow(item.size)
            return overflow ? Int64.max : next
        }
    }

    /// Number of findings in this tab that appear in `selection`. Used by the
    /// tab strip and header so the user can see per-category selection impact
    /// without switching tabs.
    public func selectedCount(in selection: Set<String>) -> Int {
        findings.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    /// Sum of sizes for the currently-selected findings in this tab. Saturates
    /// on overflow for parity with `totalSize`.
    public func selectedBytes(in selection: Set<String>) -> Int64 {
        findings.reduce(Int64(0)) { sum, item in
            guard selection.contains(item.id) else { return sum }
            let (next, overflow) = sum.addingReportingOverflow(item.size)
            return overflow ? Int64.max : next
        }
    }
}

// MARK: - Grouper

/// Groups czkawka ``ScanResult`` output into per-category File Health tabs.
///
/// Tabs are ordered **safe-first, then review**, matching the Trust Layer's
/// review-by-default posture (risk-free categories bubble up so users see
/// the quick wins first). Within each safety bucket, categories follow the
/// declaration order of ``CzkawkaCategory`` so tab placement is stable.
public enum FileHealthGrouper {
    /// Group `results` by their czkawka category, dropping anything not
    /// produced by the czkawka adapter. Tabs are returned in the order
    /// defined above; categories with no findings are omitted.
    public static func group(_ results: [ScanResult]) -> [FileHealthCategoryTab] {
        var bucket: [CzkawkaCategory: [ScanResult]] = [:]
        for result in results {
            guard let category = category(for: result.category) else { continue }
            bucket[category, default: []].append(result)
        }

        return CzkawkaCategory.allCases
            .sorted { lhs, rhs in
                let lhsRank = safetyRank(for: lhs)
                let rhsRank = safetyRank(for: rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return declarationIndex(of: lhs) < declarationIndex(of: rhs)
            }
            .compactMap { category in
                guard let findings = bucket[category], !findings.isEmpty else { return nil }
                return FileHealthCategoryTab(
                    category: category,
                    safety: inferredSafety(from: findings, defaultFor: category),
                    findings: findings
                )
            }
    }

    // MARK: - Private

    /// Reverse-lookup a ``CzkawkaCategory`` from the `resultCategory` string
    /// stamped on ``ScanResult`` by ``CzkawkaAdapter``.
    static func category(for resultCategory: String) -> CzkawkaCategory? {
        for category in CzkawkaCategory.allCases where category.resultCategory == resultCategory {
            return category
        }
        return nil
    }

    /// The tab's safety level is whatever the Trust Layer already stamped on
    /// the findings themselves — we don't re-classify here. If results carry
    /// mixed safety levels (e.g., a future ``SafetyClassifier`` downgrade
    /// overrides the category default on some paths), prefer the least-safe
    /// level present so the tab badge doesn't under-warn.
    static func inferredSafety(
        from findings: [ScanResult],
        defaultFor category: CzkawkaCategory
    ) -> SafetyLevel {
        let rank: (SafetyLevel) -> Int = {
            switch $0 {
            case .safe: 0
            case .review: 1
            case .protected_: 2
            }
        }
        if let worst = findings.map(\.safety).max(by: { rank($0) < rank($1) }) {
            return worst
        }
        return CzkawkaTrustDefaults.builtIn.entry(for: category).safety
    }

    private static func safetyRank(for category: CzkawkaCategory) -> Int {
        switch CzkawkaTrustDefaults.builtIn.entry(for: category).safety {
        case .safe: 0
        case .review: 1
        case .protected_: 2
        }
    }

    private static func declarationIndex(of category: CzkawkaCategory) -> Int {
        CzkawkaCategory.allCases.firstIndex(of: category) ?? Int.max
    }
}

// MARK: - Cleanup Flow Helpers

/// Pure helpers for File Health's selected-item cleanup flow.
///
/// Kept outside the SwiftUI container so the selection, post-clean refresh,
/// and failure-message behavior can be unit-tested without driving views.
public enum FileHealthCleanupFlow {
    public static func selectedResults(
        from results: [ScanResult],
        selectedIDs: Set<String>
    ) -> [ScanResult] {
        results.filter { selectedIDs.contains($0.id) }
    }

    public static func confirmationTier(
        for results: [ScanResult],
        selectedIDs: Set<String>
    ) -> ConfirmationTier {
        GargantuaCore.confirmationTier(for: selectedResults(from: results, selectedIDs: selectedIDs))
    }

    public static func remainingResults(
        after cleanupResult: CleanupResult,
        from results: [ScanResult]
    ) -> [ScanResult] {
        let succeededIDs = Set(cleanupResult.succeededItems.map(\.item.id))
        return results.filter { !succeededIDs.contains($0.id) }
    }

    public static func remainingSelection(
        after cleanupResult: CleanupResult,
        from selectedIDs: Set<String>
    ) -> Set<String> {
        let succeededIDs = Set(cleanupResult.succeededItems.map(\.item.id))
        return selectedIDs.subtracting(succeededIDs)
    }

    public static func failureWarnings(from cleanupResult: CleanupResult) -> [String] {
        cleanupResult.failedItems.map { failure in
            let message = failure.error ?? "Unknown cleanup error"
            return "\(failure.item.name): \(message)"
        }
    }
}
