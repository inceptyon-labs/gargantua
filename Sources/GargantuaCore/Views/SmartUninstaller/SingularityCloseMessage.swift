import Foundation

/// Flavor text shown above the post-uninstall `CleanupSummaryView`.
/// Pure derivation from a `CleanupResult` so it can be unit-tested without
/// touching SwiftUI.
public enum SingularityCloseMessage {
    /// Outcome bucket used to key the close-message copy pool.
    public enum Outcome: Equatable {
        case success
        case partial
        case totalFailure

        public static func from(result: CleanupResult) -> Outcome {
            let total = result.itemResults.count
            let succeeded = result.succeededItems.count
            if total == 0 { return .totalFailure }
            if succeeded == 0 { return .totalFailure }
            if succeeded == total { return .success }
            return .partial
        }
    }

    /// Build the flavor line shown above the summary.
    ///
    /// - `success`: "{n} artifacts lost to Gargantua. Mass recovered: {size}."
    /// - `partial`: "{n} artifacts lost to Gargantua. {m} resisted tidal forces."
    /// - `totalFailure`: "Signal lost. All artifacts still bound."
    public static func line(for result: CleanupResult) -> String {
        let outcome = Outcome.from(result: result)
        let succeeded = result.succeededItems.count
        let failed = result.failedItems.count
        switch outcome {
        case .success:
            let bytes = formatBytes(result.totalFreed)
            return "\(succeeded) artifacts lost to Gargantua. Mass recovered: \(bytes)."
        case .partial:
            return "\(succeeded) artifacts lost to Gargantua. \(failed) resisted tidal forces."
        case .totalFailure:
            return "Signal lost. All artifacts still bound."
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
