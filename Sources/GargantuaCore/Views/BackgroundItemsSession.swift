import AppKit
import SwiftUI

// MARK: - Session

/// Lightweight async wrapper around `BackgroundItemScanning` so the view can
/// kick scans off the main actor and observe the result via `@Observable`.
@MainActor
@Observable
public final class BackgroundItemsSession {
    public private(set) var scan: BackgroundItemScan?
    public private(set) var isScanning = false
    /// IDs of items currently being mutated. The row uses this to render a
    /// spinner inline so the user gets feedback while `launchctl` runs.
    public private(set) var busyItemIDs: Set<String> = []
    /// IDs the user disabled in this session. The scanner derives the
    /// `disabledFlag` reason from the plist's `Disabled` key, but
    /// `launchctl disable` writes runtime state to launchd's disabled DB
    /// instead — so a fresh scan after a successful disable still reports
    /// the plist as enabled. Carry the in-session disable state forward so
    /// the Delete button reveals on the same row the user just disabled.
    public private(set) var sessionDisabledIDs: Set<String> = []
    /// Plist path a Process-Inventory pre-selection already triggered its
    /// one rescan for. Lives on the session (not view @State) so its
    /// lifetime matches the scan cache it qualifies — navigating away
    /// mid-rescan and back must not grant the same handoff a second rescan.
    public var preSelectionRescanPath: String?
    /// Deep `launchctl print` detail fetched lazily on row expand, keyed by
    /// item id. Cached per scan generation — cleared whenever a new scan
    /// result lands.
    public private(set) var runtimeDetails: [String: LaunchdRuntimeDetail] = [:]
    /// IDs currently fetching deep runtime detail. Dedupes concurrent
    /// `loadRuntimeDetail` calls for the same item.
    public private(set) var loadingDetailIDs: Set<String> = []
    /// IDs whose detail fetch already ran this scan generation — including
    /// fetches that came back nil. `.onAppear` re-fires on every
    /// collapse/re-expand; without this an item whose `launchctl print`
    /// persistently fails would shell out again on each expansion.
    private var attemptedDetailIDs: Set<String> = []
    /// Bumped whenever the detail cache is invalidated. A suspended
    /// `loadRuntimeDetail` fetch compares its captured generation before
    /// writing back so a stale result can't repopulate a fresh cache.
    private var detailGeneration = 0

    private let scanner: any BackgroundItemScanning
    private let actionExecutor: (any BackgroundItemActionExecuting)?
    private let runtimeProvider: any LaunchdRuntimeStateProviding

    public init(
        scanner: any BackgroundItemScanning = DefaultBackgroundItemScanner(),
        actionExecutor: (any BackgroundItemActionExecuting)? = DefaultBackgroundItemActionExecutor(),
        runtimeProvider: any LaunchdRuntimeStateProviding = DefaultLaunchdRuntimeStateProvider()
    ) {
        self.scanner = scanner
        self.actionExecutor = actionExecutor
        self.runtimeProvider = runtimeProvider
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) {
            scanner.scan()
        }.value
        self.scan = result
        invalidateRuntimeDetails()
    }

    public func clearScan() {
        scan = nil
        busyItemIDs.removeAll()
        sessionDisabledIDs.removeAll()
        invalidateRuntimeDetails()
    }

    private func invalidateRuntimeDetails() {
        detailGeneration += 1
        runtimeDetails.removeAll()
        loadingDetailIDs.removeAll()
        attemptedDetailIDs.removeAll()
    }

    /// Fetch deep runtime detail for an expanded row. Cached per scan
    /// generation; concurrent calls for the same id dedupe via
    /// `loadingDetailIDs`.
    public func loadRuntimeDetail(for item: BackgroundItem) async {
        guard item.plistPath != nil else { return }
        guard !attemptedDetailIDs.contains(item.id), !loadingDetailIDs.contains(item.id) else { return }
        loadingDetailIDs.insert(item.id)
        let generation = detailGeneration
        // Only the generation that inserted the marker may remove it: after
        // an invalidation cleared the set, a stale fetch's cleanup must not
        // erase a marker the NEXT generation's fetch just inserted.
        defer {
            if generation == detailGeneration { loadingDetailIDs.remove(item.id) }
        }
        let provider = runtimeProvider
        let label = item.label
        let source = item.source
        let detail = await Task.detached(priority: .userInitiated) {
            provider.printDetail(label: label, source: source)
        }.value
        // A rescan may have invalidated the cache while the fetch was
        // suspended — its result describes the previous generation's world.
        guard generation == detailGeneration else { return }
        attemptedDetailIDs.insert(item.id)
        if let detail { runtimeDetails[item.id] = detail }
    }

    /// Run a `BackgroundItemAction` against `item`, marking the row busy for
    /// the duration. After success, the session re-scans so the row's
    /// disabled/enabled state reflects the new ground truth.
    public func perform(
        _ action: BackgroundItemAction,
        on item: BackgroundItem
    ) async -> BackgroundItemActionOutcome {
        guard let actionExecutor else {
            return BackgroundItemActionOutcome(
                itemID: item.id,
                action: action,
                succeeded: false,
                error: "Action executor is not configured."
            )
        }
        busyItemIDs.insert(item.id)
        defer { busyItemIDs.remove(item.id) }

        // The executor's delete pre-condition checks `disabledFlag` to enforce
        // "disable runs first." When the user disabled the item earlier in
        // this session — or launchd's override DB already marks it disabled
        // from a prior session — the plist key still reads as enabled, so
        // synthesize the reason on the fly.
        let effectiveItem = sessionDisabledIDs.contains(item.id) || item.runtime?.disabledOverride == true
            ? item.withSessionDisabled()
            : item

        let outcome: BackgroundItemActionOutcome
        switch action {
        case .disable:
            outcome = await actionExecutor.disable(effectiveItem)
        case .enable:
            outcome = await actionExecutor.enable(effectiveItem)
        case .delete:
            outcome = await actionExecutor.delete(effectiveItem, confirmedAt: item.safety.confirmationTier)
        }

        if outcome.succeeded {
            switch action {
            case .disable:
                sessionDisabledIDs.insert(item.id)
            case .enable, .delete:
                sessionDisabledIDs.remove(item.id)
            }
            await scan()
        }
        return outcome
    }
}
