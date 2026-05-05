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

    /// Seed selection from a finished scan. Always starts empty: at scan
    /// scale the Trust Layer commitment is "review-by-default", which means
    /// the user picks every item that ships to Trash. Auto-preselection
    /// silently accumulated thousands of safe-tier hits across tabs the user
    /// hadn't seen, leading to "send 3024 items" surprises. Bulk selection
    /// stays one click away via per-tab Select All in the UI.
    public func finishScan(results: [ScanResult]) {
        _ = results
        selectedResultIDs = []
    }

    /// Select every id in `ids`. Used by per-tab "Select all" so the user
    /// can opt into a bulk deletion deliberately, scoped to the tab they're
    /// looking at.
    public func selectAll(_ ids: [String]) {
        selectedResultIDs.formUnion(ids)
    }

    /// Remove every id in `ids` from the selection. Per-tab "Deselect all".
    public func deselectAll(_ ids: [String]) {
        selectedResultIDs.subtract(ids)
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
