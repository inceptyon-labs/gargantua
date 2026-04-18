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

        /// Semantic accent role for the outcome, decoupled from SwiftUI
        /// `Color` so it can be unit-tested. View layer maps this to the
        /// concrete token (`GargantuaColors.safe` / `.accretion` / `.protected_`).
        public var accent: OutcomeAccent {
            switch self {
            case .success: return .safe
            case .partial: return .accretion
            case .totalFailure: return .protected
            }
        }
    }

    /// Semantic accent role for a cleanup outcome.
    public enum OutcomeAccent: Equatable {
        case safe
        case accretion
        case protected
    }

    /// All-caps heading shown above the flavor line. Keyed to the same
    /// outcome bucket as `line(for:)` so the two never contradict each
    /// other (heading "SIGNAL RECOVERED" with message "Signal lost." was
    /// a real bug before this helper existed).
    public static func heading(for result: CleanupResult) -> String {
        switch Outcome.from(result: result) {
        case .success: return "SIGNAL RECOVERED"
        case .partial: return "PARTIAL TRANSFER"
        case .totalFailure: return "SIGNAL LOST"
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
