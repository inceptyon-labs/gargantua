import Foundation

/// Tiny Sendable holder so a closure can keep a weak reference to the view
/// model without re-capturing `[weak self]` in nested Tasks (which trips a
/// Swift 6 concurrency warning).
private struct WeakHolder: @unchecked Sendable {
    weak var value: SmartUninstallerViewModel?
    init(_ value: SmartUninstallerViewModel) { self.value = value }
}

extension SmartUninstallerViewModel {
    // MARK: - Derived: filtered + sorted apps

    /// Installed apps filtered by query and system-app toggle, sorted by the
    /// current `sort` selection. Recomputed on every access; the picker is at
    /// most a few hundred rows so a cache would be premature.
    public var visibleApps: [AppInfo] {
        let filtered = apps.filter { app in
            if !showSystemApps, app.isSystemApp { return false }
            guard !query.isEmpty else { return true }
            let needle = query.lowercased()
            if app.name.lowercased().contains(needle) { return true }
            if app.displayName?.lowercased().contains(needle) == true { return true }
            if app.bundleID.lowercased().contains(needle) { return true }
            return false
        }

        // Each branch sorts in the field's "natural" direction (asc for name,
        // desc for size and recency); a final reverse flips it when the user
        // has toggled away from the default.
        let naturallySorted: [AppInfo]
        switch sort {
        case .name:
            naturallySorted = filtered.sorted { lhs, rhs in
                lhs.displayName ?? lhs.name < rhs.displayName ?? rhs.name
            }
        case .size:
            naturallySorted = filtered.sorted { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
        case .lastUsed:
            naturallySorted = filtered.sorted { lhs, rhs in
                switch (lhs.lastUsedDate, rhs.lastUsedDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name < rhs.name
                }
            }
        }

        return sortAscending == sort.defaultAscending ? naturallySorted : naturallySorted.reversed()
    }

    // MARK: - App loading

    /// Load the installed-app list and transition into the picker.
    public func loadApps() async {
        pathStream.clear()
        phase = .loadingApps
        let scanner = observing(appScanner)
        let loaded = await scanner.scanApps()
        // If the user severed the tether mid-scan, severTether() has already
        // routed the phase — don't pivot to .pickingApp on top of it.
        guard !Task.isCancelled else { return }
        apps = loaded
        // Drop any checked bundle IDs that didn't survive the rescan so the
        // batch bar can't quietly omit them later — `startBatchUninstall`
        // filters by `apps.contains`, so without this prune a stale ID would
        // count toward the bar but never actually run.
        let validBundleIDs = Set(loaded.map(\.bundleID))
        multiSelected = multiSelected.intersection(validBundleIDs)
        phase = .pickingApp
        startBackgroundCategoryCountScan()
    }

    /// Re-run the installed-app enumeration without resetting selections.
    /// Triggered by the picker's Rescan button — discards the cached list and
    /// rebuilds it from scratch (filesystem walk + size scan).
    public func rescanApps() async {
        await loadApps()
    }

    /// Cheap refresh: stat() every cached app's bundle path and drop the rows
    /// whose bundles no longer exist on disk. Used by the picker's Refresh
    /// button to clear out apps the user just uninstalled (or removed via
    /// Finder) without paying for a full enumeration.
    public func pruneMissingApps() {
        pruneUninstalledApps(apps)
    }

    // MARK: - Multi-select

    /// Toggle a row's checkbox for batch uninstall. Idempotent.
    public func toggleMultiSelect(bundleID: String) {
        if multiSelected.contains(bundleID) {
            multiSelected.remove(bundleID)
        } else {
            multiSelected.insert(bundleID)
        }
    }

    public func clearMultiSelect() {
        multiSelected = []
    }

    /// Bundle IDs the user has checked but that aren't in the currently
    /// visible filter slice. Surfaced so the picker can warn the user that
    /// hitting "Uninstall N apps" would trash apps they can't see.
    public var hiddenSelectedBundleIDs: Set<String> {
        let visible = Set(visibleApps.map(\.bundleID))
        return multiSelected.subtracting(visible)
    }

    public var hiddenSelectedCount: Int {
        hiddenSelectedBundleIDs.count
    }

    /// Drop every checked bundle ID that isn't currently visible. The user's
    /// escape hatch when they realize the batch bar is counting selections
    /// that the active filter, search, or system-apps toggle is hiding.
    public func clearHiddenSelections() {
        multiSelected.subtract(hiddenSelectedBundleIDs)
    }

    /// How many system apps match the active query but are filtered out by
    /// `showSystemApps == false`. The picker's no-matches empty state uses
    /// this to invite the user to flip the toggle when their search would
    /// have hit something.
    public var hiddenSystemMatchCount: Int {
        guard !showSystemApps, !query.isEmpty else { return 0 }
        let needle = query.lowercased()
        return apps.reduce(into: 0) { count, app in
            guard app.isSystemApp else { return }
            if app.name.lowercased().contains(needle)
                || app.displayName?.lowercased().contains(needle) == true
                || app.bundleID.lowercased().contains(needle) {
                count += 1
            }
        }
    }

    // MARK: - Background category counts

    /// Kick off background planning for every loaded app so the picker can
    /// show "X categories" without users having to drill in. Throttled to
    /// 4 concurrent plans so a couple hundred installed apps don't peg the
    /// CPU during routine picker browsing.
    private func startBackgroundCategoryCountScan() {
        categoryCountTask?.cancel()
        categoryCountTask = nil
        // Snapshot the apps list and planner so the detached task doesn't
        // observe later mutations.
        let snapshot = apps
        let planner = self.planner
        let weakSelf = WeakHolder(self)
        categoryCountTask = Task {
            await Self.scanCategoryCounts(
                apps: snapshot,
                planner: planner,
                concurrency: 4,
                report: { @Sendable bundleID, count in
                    Task { @MainActor in
                        weakSelf.value?.categoryCounts[bundleID] = count
                    }
                }
            )
        }
    }

    /// Walk `apps` and emit `(bundleID, distinctCategoryCount)` per app via
    /// `report`. Limits in-flight planner calls to `concurrency` so heavy
    /// picker scans don't overwhelm the system.
    private static func scanCategoryCounts(
        apps: [AppInfo],
        planner: any UninstallPlanning,
        concurrency: Int,
        report: @Sendable @escaping (_ bundleID: String, _ count: Int) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var iterator = apps.makeIterator()
            while let app = iterator.next() {
                if Task.isCancelled { return }
                if inFlight >= concurrency {
                    await group.next()
                    inFlight -= 1
                }
                let bundleID = app.bundleID
                group.addTask {
                    let plan = planner.plan(for: app, includeAppBundle: false)
                    let categories = Set(plan.remnants.map(\.category))
                    report(bundleID, categories.count)
                }
                inFlight += 1
            }
        }
    }

    /// Remove apps from the cached `apps` list once they no longer exist on
    /// disk. Called after a successful uninstall so the picker doesn't have
    /// to be re-scanned just to drop a row that the user just trashed.
    /// Also prunes the bundle IDs from `multiSelected` and `categoryCounts`
    /// so stale entries don't survive across batches.
    func pruneUninstalledApps(_ candidates: [AppInfo]) {
        let fm = FileManager.default
        let removedBundleIDs: Set<String> = Set(
            candidates
                .filter { !fm.fileExists(atPath: $0.bundlePath) }
                .map(\.bundleID)
        )
        guard !removedBundleIDs.isEmpty else { return }
        apps.removeAll { removedBundleIDs.contains($0.bundleID) }
        multiSelected.subtract(removedBundleIDs)
        for id in removedBundleIDs { categoryCounts.removeValue(forKey: id) }
    }
}
