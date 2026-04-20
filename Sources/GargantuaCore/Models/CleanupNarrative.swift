import Foundation
import SwiftUI

/// Signature for the cleanup-narrative closure threaded through the
/// environment. Non-throwing: the service always returns a usable
/// `CleanupNarrative`, falling back to a deterministic template when no
/// model is available or the engine fails. Main-actor-isolated because
/// `CleanupSummaryView.task` calls it from the main actor and the backing
/// service (`LocalAIService`) is `@MainActor`.
public typealias CleanupNarrator = @MainActor (CleanupResult) async -> CleanupNarrative

private struct CleanupNarratorKey: EnvironmentKey {
    static let defaultValue: CleanupNarrator? = nil
}

public extension EnvironmentValues {
    /// Optional post-cleanup narrator. When set, `CleanupSummaryView` renders
    /// an AI-attributed narrative row in addition to its structured lists.
    /// Default `nil` means no narrative section appears — scan views that
    /// embed `CleanupSummaryView` without wiring this environment value keep
    /// their previous UI.
    var cleanupNarrator: CleanupNarrator? {
        get { self[CleanupNarratorKey.self] }
        set { self[CleanupNarratorKey.self] = newValue }
    }
}

/// A 1–2 sentence post-cleanup summary shown in `CleanupSummaryView` alongside
/// the existing structured item lists (PRD §6.2).
///
/// The narrative is display-only and is not persisted to the audit record.
/// `source` tracks whether the text came from the AI engine or a deterministic
/// template so the UI can attribute it correctly.
public struct CleanupNarrative: Sendable, Equatable {
    public let text: String
    public let source: ExplanationSource

    public init(text: String, source: ExplanationSource) {
        self.text = text
        self.source = source
    }
}

/// Deterministic template narratives for `CleanupResult`. Used:
///   1. As the fallback when no model is available or the engine fails, and
///   2. As the default implementation of `AIInferenceEngine.narrate(cleanup:)`.
///
/// Everything the template reads is already on `CleanupResult`, so the output
/// never exposes information the caller didn't already hand in. Per-item paths
/// are intentionally not included in the prose — only the top group *names*
/// (already in `CleanupResult` via each item's `ScanResult.name`) and
/// aggregated counts/bytes.
public enum CleanupNarrativeTemplate {
    /// Build a deterministic, display-ready narrative for `result`.
    public static func text(for result: CleanupResult) -> String {
        let freed = AlertItem.formatBytes(result.totalFreed)
        let succeeded = result.succeededItems.count
        let failed = result.failedItems.count

        if succeeded == 0 && failed == 0 {
            return "Nothing to clean — no items were removed."
        }

        if succeeded == 0 {
            return "Nothing was cleaned — \(failed) \(itemWord(failed)) could not be removed."
        }

        let lead: String
        switch result.cleanupMethod {
        case .trash:
            lead = "Moved \(succeeded) \(itemWord(succeeded)) to Trash, freeing \(freed)"
        case .delete:
            lead = "Deleted \(succeeded) \(itemWord(succeeded)), freeing \(freed)"
        }

        var sentence = lead
        let groups = topGroups(in: result, limit: 2)
        if !groups.isEmpty {
            sentence += " — " + groups.joined(separator: ", ")
        }
        sentence += "."

        if failed > 0 {
            sentence += " \(failed) \(itemWord(failed)) could not be removed."
        }

        return sentence
    }

    /// A single group entry: all succeeded items sharing a `ScanResult.name`,
    /// with accumulated count and bytes.
    struct Group: Equatable {
        let name: String
        var count: Int
        var bytes: Int64
    }

    /// Format the top `limit` groups (count > 1) as "Name (N items)".
    ///
    /// Singleton groups — a single cleaned item sharing a unique name — are
    /// intentionally excluded. Only *repeated* names have useful aggregate
    /// meaning, and skipping singletons keeps the narrative from surfacing
    /// individual file names any more than the structured card already does.
    /// Returns an empty array when no group has more than one item.
    private static func topGroups(in result: CleanupResult, limit: Int) -> [String] {
        groupSucceededItems(in: result)
            .lazy
            .filter { $0.count > 1 }
            .prefix(limit)
            .map { "\($0.name) (\($0.count) items)" }
    }

    static func groupSucceededItems(in result: CleanupResult) -> [Group] {
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for entry in result.succeededItems {
            let name = entry.item.name
            if let existing = index[name] {
                groups[existing].count += 1
                groups[existing].bytes += entry.item.size
            } else {
                index[name] = groups.count
                groups.append(Group(name: name, count: 1, bytes: entry.item.size))
            }
        }
        // Size-descending, name as deterministic tiebreaker (matches the list
        // sort in `CleanupSummaryView`).
        groups.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return groups
    }

    private static func itemWord(_ count: Int) -> String {
        count == 1 ? "item" : "items"
    }
}
