import Foundation

extension SmartUninstallerViewModel {
    // MARK: - Plan access

    /// The plan currently under review or executing, if any.
    public var currentPlan: UninstallPlan? {
        switch phase {
        case .reviewingPlan(let plan): plan
        case .executing(let plan): plan
        case .summary(let plan, _): plan
        default: nil
        }
    }

    /// The selected remnant items as `ScanResult` — what the confirmation
    /// modal and executor consume.
    public var selectedScanResults: [ScanResult] {
        guard let plan = currentPlan else { return [] }
        return plan.allItems
            .filter { selectedIDs.contains($0.id) }
            .map { $0.toScanResult() }
    }

    public var selectedTotalBytes: Int64 {
        selectedScanResults.reduce(0) { $0 + $1.size }
    }

    /// Whether there's at least one selected item that's still actionable
    /// (protected items locked unless `includeProtected` is true).
    public var canProceed: Bool {
        guard !selectedIDs.isEmpty, let plan = currentPlan else { return false }
        let hasProtectedSelected = plan.allItems.contains { item in
            selectedIDs.contains(item.id) && item.safety == .protected_
        }
        return !hasProtectedSelected || includeProtected
    }

    // MARK: - App selection

    /// Scan the app's plan and immediately surface the confirmation modal
    /// so the user can uninstall without drilling through the plan-review
    /// screen. The plan-review screen is still rendered behind the modal
    /// scrim — declining the modal lands on it for further inspection.
    ///
    /// Selects every actionable item (safe + review, excluding protected)
    /// rather than only the safe defaults, because the user explicitly
    /// asked to uninstall the app — leaving the `.app` bundle unselected
    /// (review-classified by default) would surface a "0 items" modal.
    public func quickUninstall(_ app: AppInfo) async {
        await selectApp(app)
        if let plan = currentPlan {
            selectedIDs = Set(plan.actionableItems.map(\.id))
        }
        quickConfirmActive = true
    }

    /// Begin uninstall planning for a chosen app.
    ///
    /// Planning hits the filesystem (glob expansion, directory enumeration,
    /// size scanning), so we run it off the main actor to keep the
    /// `.scanning` phase actually observable on large apps.
    public func selectApp(_ app: AppInfo) async {
        pathStream.clear()
        phase = .scanning(app)
        let planner = observing(self.planner)
        let plan = await Task.detached { planner.plan(for: app, includeAppBundle: true) }.value
        // Sever Tether routed elsewhere — don't surface the plan we just
        // computed; severTether() already cleared selection state.
        guard !Task.isCancelled else { return }
        selectedIDs = Set(plan.allItems
            .filter { $0.safety.isSelectedByDefault }
            .map(\.id))
        includeProtected = false
        phase = .reviewingPlan(plan)
    }

    // MARK: - Selection ops

    public func toggleSelection(_ item: RemnantItem) {
        // Protected items require the explicit unlock toggle first.
        if item.safety == .protected_, !includeProtected { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    public func selectAll(in items: [RemnantItem]) {
        for item in items where item.safety.isActionable || (item.safety == .protected_ && includeProtected) {
            selectedIDs.insert(item.id)
        }
    }

    public func deselectAll(in items: [RemnantItem]) {
        for item in items { selectedIDs.remove(item.id) }
    }

    /// Toggle the "include protected items" override. Deselecting it also
    /// removes any protected items from the current selection so the state
    /// stays internally consistent.
    public func setIncludeProtected(_ value: Bool) {
        includeProtected = value
        if !value, let plan = currentPlan {
            for item in plan.allItems where item.safety == .protected_ {
                selectedIDs.remove(item.id)
            }
        }
    }
}
