import Foundation
import Observation

/// Session-scoped state for the File Health panel: the set of czkawka
/// findings the user has picked as candidates for the (not-yet-wired)
/// Send-to-Trash action.
///
/// Lives on ``FileHealthContainerView`` so selection survives tab switches
/// within a single scan session, and is reset the moment a new scan starts.
/// Mirrors ``DeepCleanSessionState`` — the downstream Confirmation flow is
/// planned to be shared, so keeping the shape parallel avoids a second
/// selection model when that wiring lands.
@Observable @MainActor
public final class FileHealthSessionState {
    /// IDs of ``ScanResult`` entries currently checked.
    public var selectedResultIDs: Set<String> = []

    public init() {}

    /// Reset selection, e.g. when the user kicks off a fresh scan. The scan
    /// itself is owned by the container; this only wipes selection state.
    public func clear() {
        selectedResultIDs = []
    }

    /// Seed selection from a finished scan. Pre-selects Trust Layer `.safe`
    /// items only — review and protected tiers stay unchecked so the user
    /// consciously opts into riskier deletions (matches Deep Clean default).
    public func finishScan(results: [ScanResult]) {
        selectedResultIDs = Set(results.filter { $0.safety == .safe }.map(\.id))
    }

    /// Flip a single row's selection. Called from the checkbox tap handler.
    public func toggleSelection(for resultID: String) {
        if selectedResultIDs.contains(resultID) {
            selectedResultIDs.remove(resultID)
        } else {
            selectedResultIDs.insert(resultID)
        }
    }

    public func isSelected(_ resultID: String) -> Bool {
        selectedResultIDs.contains(resultID)
    }
}
