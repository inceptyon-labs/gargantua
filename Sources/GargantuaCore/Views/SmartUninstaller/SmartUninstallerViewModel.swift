import Foundation
import Observation

/// Sort options for the Smart Uninstaller app picker.
public enum UninstallAppSort: String, CaseIterable, Sendable {
    case name
    case size
    case lastUsed

    public var label: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .lastUsed: "Last used"
        }
    }

    /// The direction users expect by default when first selecting this field.
    /// Names read alphabetically, but for size and recency the interesting
    /// rows are at the top in descending order.
    public var defaultAscending: Bool {
        switch self {
        case .name: true
        case .size, .lastUsed: false
        }
    }
}

/// Top-level phases of the Smart Uninstaller flow.
public enum SmartUninstallerPhase: Sendable {
    /// Initial state before the installed-app list has been fetched.
    case idle
    /// Enumerating installed apps.
    case loadingApps
    /// Showing the picker; `apps` lives on the view model itself.
    case pickingApp
    /// Expanding the plan for the chosen app.
    case scanning(AppInfo)
    /// Plan ready for review.
    case reviewingPlan(UninstallPlan)
    /// Executing the plan.
    case executing(UninstallPlan)
    /// Post-execution summary.
    case summary(UninstallPlan, UninstallExecutionResult)
    /// Scanning a batch of multi-selected apps in parallel.
    case batchScanning(completed: Int, total: Int)
    /// Executing a batch of plans sequentially.
    case batchExecuting(completed: Int, total: Int)
    /// Combined post-execution summary for a batch.
    case batchSummary([UninstallExecutionResult])
    /// Non-recoverable error; `message` is shown to the user with a retry.
    case failed(message: String)
}

/// Drives the Smart Uninstaller UI.
///
/// Owns the list of apps, the active plan, the user's selection, and the
/// transition between phases (picker → review → execute → summary). All state
/// mutations happen on the main actor; service calls are awaited so the UI
/// can show progress spinners between phases.
@MainActor
@Observable
public final class SmartUninstallerViewModel {

    // MARK: - Phase

    public private(set) var phase: SmartUninstallerPhase = .idle

    // MARK: - App picker state

    public private(set) var apps: [AppInfo] = []
    public var query: String = ""
    public private(set) var sort: UninstallAppSort = .name
    public private(set) var sortAscending: Bool = UninstallAppSort.name.defaultAscending
    public var showSystemApps: Bool = false

    /// Apply a sort selection. Tapping the active field flips direction;
    /// switching to another field resets to that field's natural default.
    public func applySort(_ field: UninstallAppSort) {
        if sort == field {
            sortAscending.toggle()
        } else {
            sort = field
            sortAscending = field.defaultAscending
        }
    }

    /// Flip the current sort direction without changing the field.
    public func toggleSortDirection() {
        sortAscending.toggle()
    }

    /// Bundle IDs the user has checked in the picker for batch uninstall.
    public private(set) var multiSelected: Set<String> = []

    /// Distinct remnant-category counts per bundle ID, populated in the
    /// background after `loadApps()` so the picker can show "X categories"
    /// without forcing the user to drill in.
    public private(set) var categoryCounts: [String: Int] = [:]

    /// Plans built up during a batch uninstall. Populated from
    /// `prepareBatchUninstall`; consumed by the confirmation modal and
    /// `executeBatch`.
    public private(set) var batchPlans: [UninstallPlan] = []

    /// When true, the SmartUninstallerView should overlay the confirmation
    /// modal on top of the plan-review screen so the user can confirm and
    /// run a single-app uninstall without manually inspecting the plan.
    /// Set by `quickUninstall(_:)`; cleared on confirm/cancel/execute.
    public var quickConfirmActive = false

    /// Background task that fills `categoryCounts`. Cancelled when a new
    /// `loadApps` starts so we don't keep planning a stale app list.
    private var categoryCountTask: Task<Void, Never>?

    /// In-flight scan / select / execute task. Stored so the EventHorizon
    /// console's "Sever Tether" button can cancel it. Always overwrite when
    /// starting new work — see `runTracked`.
    public var activeTask: Task<Void, Never>?

    /// Wrap an async entry point in a tracked `Task` so a sever-tether abort
    /// can cancel it. Cancels any previously stored task before replacing —
    /// callers that need to chain (e.g. `quickUninstall` → `selectApp`) should
    /// invoke the inner async functions directly rather than nesting tracked
    /// tasks, which would orphan the parent.
    public func runTracked(_ work: @escaping @MainActor @Sendable () async -> Void) {
        activeTask?.cancel()
        activeTask = Task { @MainActor in
            await work()
        }
    }

    /// User-initiated abort from the EventHorizon console. Cancels the
    /// in-flight task, clears the live path stream, and returns the surface
    /// to the most useful upstream phase: the picker if apps are loaded,
    /// otherwise the welcome screen. Any item already trashed during an
    /// in-progress execute() stays trashed — partial state is intentional and
    /// the audit log will reflect what actually ran.
    public func severTether() {
        activeTask?.cancel()
        activeTask = nil
        pathStream.clear()
        selectedIDs = []
        includeProtected = false
        batchPlans = []
        quickConfirmActive = false
        phase = apps.isEmpty ? .idle : .pickingApp
    }

    // MARK: - Plan review state

    /// IDs of remnants the user has selected for removal. The app bundle is
    /// included here when selected.
    public private(set) var selectedIDs: Set<String> = []
    /// Whether the user has explicitly unlocked protected items for this plan.
    public private(set) var includeProtected: Bool = false

    // MARK: - Dependencies

    private let appScanner: any AppScanning
    private let planner: any UninstallPlanning
    private let executor: any UninstallExecuting
    private let authorizationProvider: @MainActor @Sendable () -> UninstallAuthorization?
    /// Delay between successful execution and the summary transition. Tunes
    /// how long the EventHorizonConsole stays visible so the spaghettify
    /// swallow animation has stage time. Set to 0 in tests.
    private let postExecutionLinger: TimeInterval

    /// Live path-streaming view model backing the Event Horizon Console.
    /// Observed by the scanners and executor when they support it (via
    /// `withObserver(_:)` on concrete types).
    public let pathStream: PathStreamViewModel

    public init(
        appScanner: any AppScanning,
        planner: any UninstallPlanning,
        executor: any UninstallExecuting,
        authorizationProvider: @escaping @MainActor @Sendable () -> UninstallAuthorization? = { nil },
        pathStream: PathStreamViewModel = PathStreamViewModel(),
        postExecutionLinger: TimeInterval = 0.75
    ) {
        self.appScanner = appScanner
        self.planner = planner
        self.executor = executor
        self.authorizationProvider = authorizationProvider
        self.pathStream = pathStream
        self.postExecutionLinger = postExecutionLinger
    }

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

    // MARK: - Phase transitions

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

    /// Tiny Sendable holder so a closure can keep a weak reference to the
    /// view model without re-capturing `[weak self]` in nested Tasks (which
    /// trips a Swift 6 concurrency warning).
    private struct WeakHolder: @unchecked Sendable {
        weak var value: SmartUninstallerViewModel?
        init(_ value: SmartUninstallerViewModel) { self.value = value }
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
    private func pruneUninstalledApps(_ candidates: [AppInfo]) {
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

    /// Wrap a scanner/executor with the live `pathStream` as observer,
    /// if the concrete type supports it via `withObserver(_:)`. Types
    /// that don't support it pass through unchanged (e.g. test stubs).
    private func observing(_ scanner: any AppScanning) -> any AppScanning {
        // `DefaultAppScanner` accepts the observer at init; test stubs do
        // not. Since structs can't be retrofitted post-init, we return
        // the input untouched. The ViewModel's caller is expected to
        // construct the production scanner with the observer already
        // attached (see `SmartUninstallerView.makeDefaultViewModel`).
        return scanner
    }

    private func observing(_ planner: any UninstallPlanning) -> any UninstallPlanning {
        if let remnant = planner as? RemnantScanner {
            return remnant.withObserver(pathStream)
        }
        return planner
    }

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

    /// Run the uninstall. Surfaces execution errors as a `.failed` phase so
    /// the UI can show the message and offer retry.
    ///
    /// Only runs from `.reviewingPlan`; double-confirms or key-repeat on the
    /// confirm button are swallowed. Cleanup is hard-wired to Trash because
    /// `UninstallExecutor` rejects anything else.
    public func execute() async {
        guard case .reviewingPlan(let plan) = phase, canProceed else { return }
        let selectedItems = plan.allItems.filter { selectedIDs.contains($0.id) }
        let prunedPlan = UninstallPlan(
            id: plan.id,
            app: plan.app,
            appBundle: selectedItems.first { $0.id == plan.appBundle?.id },
            remnants: selectedItems.filter { $0.id != plan.appBundle?.id },
            createdAt: plan.createdAt
        )

        let tier = confirmationTier(for: prunedPlan.allItems.map { $0.toScanResult() })
        let options = UninstallExecutionOptions(
            includeProtectedItems: includeProtected,
            confirmationMethod: tier,
            cleanupMethod: .trash,
            authorization: authorizationProvider()
        )

        phase = .executing(prunedPlan)
        let exec = observing(executor)
        do {
            let result = try await exec.execute(prunedPlan, options: options)
            // Drop the app from the cached picker list when its bundle is
            // gone, so navigating back lands on a fresh list without a full
            // rescan. Idempotent: pruneUninstalledApps stat-checks each path.
            pruneUninstalledApps([prunedPlan.app])
            // Hold the EventHorizonConsole on screen long enough for the
            // spaghettify swallow animation to play. Without this hold, fast
            // uninstalls (small apps, few items) transition straight to the
            // summary card and SwiftUI cancels the per-row .task before its
            // dwell timer fires, so the swallow effect is invisible.
            await lingerForSpaghettify(after: result)
            // If the user severed the tether mid-execute, severTether()
            // already routed to picker/idle and the audit trail records what
            // actually ran. Don't pivot to a summary in that case.
            guard !Task.isCancelled else { return }
            phase = .summary(prunedPlan, result)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Spaghettify visuals last `Spaghettify.dwell + Spaghettify.duration`
    /// (~0.65s); add a small buffer for the per-row `.task` startup. Skip the
    /// linger if no items succeeded — there's nothing to swallow.
    private func lingerForSpaghettify(after result: UninstallExecutionResult) async {
        let succeeded = result.cleanupResult.itemResults.contains(where: \.succeeded)
        guard succeeded, postExecutionLinger > 0 else { return }
        let nanos = UInt64(postExecutionLinger * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func observing(_ executor: any UninstallExecuting) -> any UninstallExecuting {
        if let uninst = executor as? UninstallExecutor {
            return uninst.withObserver(pathStream)
        }
        return executor
    }

    /// Return to the app picker and clear per-plan state.
    public func reset() {
        selectedIDs = []
        includeProtected = false
        batchPlans = []
        phase = .pickingApp
    }

    // MARK: - Batch flow

    /// Scan every app the user has checked, build their uninstall plans, and
    /// surface them for confirmation. The view shows a single combined
    /// confirm modal listing items from every plan.
    ///
}

// MARK: - Batch uninstall

// Extracted into an extension so type_body_length stays under the
// SwiftLint threshold. Same file → `private(set)` setters remain
// accessible.
extension SmartUninstallerViewModel {

    /// On scan completion the phase remains `.batchScanning(total, total)`
    /// and `batchPlans` is populated; the view binds to `batchPlans` to
    /// decide whether the confirm modal should appear. This avoids a
    /// dedicated "ready to confirm" phase.
    public func startBatchUninstall() async {
        let bundleIDs = multiSelected
        let appsToScan = apps.filter { bundleIDs.contains($0.bundleID) }
        guard !appsToScan.isEmpty else { return }

        pathStream.clear()
        batchPlans = []
        // Default selection: every actionable item from every plan. Matches
        // single-app behavior where safe items are pre-selected.
        selectedIDs = []
        includeProtected = false
        phase = .batchScanning(completed: 0, total: appsToScan.count)

        let planner = observing(self.planner)
        var plans: [UninstallPlan] = []
        for (idx, app) in appsToScan.enumerated() {
            if Task.isCancelled { return }
            let plan = await Task.detached { planner.plan(for: app, includeAppBundle: true) }.value
            plans.append(plan)
            phase = .batchScanning(completed: idx + 1, total: appsToScan.count)
        }

        guard !Task.isCancelled else { return }
        batchPlans = plans
        // Pre-select every actionable item (safe + review). For batch flow
        // the user has chosen "uninstall N apps" without inspecting the
        // plan — defaulting to safe-only would leave the `.app` bundles
        // (review-classified) unselected and surface a "0 items" modal.
        selectedIDs = Set(
            plans.flatMap(\.actionableItems).map(\.id)
        )
    }

    /// Execute every plan in `batchPlans` sequentially and collect their
    /// results. Mirrors the single-app `execute()` path: trash-only,
    /// per-plan tier scaling, post-execution linger, and apps that succeed
    /// are pruned from the cached picker list.
    public func executeBatch() async {
        let plans = batchPlans
        guard !plans.isEmpty else { return }

        var results: [UninstallExecutionResult] = []
        let total = plans.count
        phase = .batchExecuting(completed: 0, total: total)

        let exec = observing(executor)
        for (idx, plan) in plans.enumerated() {
            if Task.isCancelled { break }
            let selected = plan.allItems.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else {
                phase = .batchExecuting(completed: idx + 1, total: total)
                continue
            }
            let pruned = UninstallPlan(
                id: plan.id,
                app: plan.app,
                appBundle: selected.first { $0.id == plan.appBundle?.id },
                remnants: selected.filter { $0.id != plan.appBundle?.id },
                createdAt: plan.createdAt
            )
            let tier = confirmationTier(for: pruned.allItems.map { $0.toScanResult() })
            let options = UninstallExecutionOptions(
                includeProtectedItems: includeProtected,
                confirmationMethod: tier,
                cleanupMethod: .trash,
                authorization: authorizationProvider()
            )
            do {
                let result = try await exec.execute(pruned, options: options)
                pruneUninstalledApps([pruned.app])
                results.append(result)
            } catch {
                // Record a synthetic failed result so the summary still
                // accounts for this plan; aborting the whole batch on one
                // failure would mask any successes already trashed.
                let failed = UninstallExecutionResult(
                    cleanupResult: CleanupResult(
                        itemResults: pruned.allItems.map {
                            CleanupItemResult(
                                item: $0.toScanResult(),
                                succeeded: false,
                                error: error.localizedDescription
                            )
                        },
                        cleanupMethod: .trash
                    ),
                    dryRun: false,
                    privilegedItems: [],
                    auditWritten: false
                )
                results.append(failed)
            }
            phase = .batchExecuting(completed: idx + 1, total: total)
        }

        await lingerForBatchSpaghettify(results: results)
        // If severed mid-batch, the partial results were already audit-logged
        // by each successful plan's executor; severTether() routed to picker.
        guard !Task.isCancelled else { return }
        phase = .batchSummary(results)
        batchPlans = []
        multiSelected = []
        selectedIDs = []
    }

    private func lingerForBatchSpaghettify(results: [UninstallExecutionResult]) async {
        let succeeded = results.contains { result in
            result.cleanupResult.itemResults.contains(where: \.succeeded)
        }
        guard succeeded, postExecutionLinger > 0 else { return }
        let nanos = UInt64(postExecutionLinger * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    /// Cancel an in-progress batch flow and return to the picker. Safe to
    /// call from the batch confirm modal's Cancel button.
    public func cancelBatch() {
        batchPlans = []
        selectedIDs = []
        includeProtected = false
        phase = .pickingApp
    }

    /// Combined items to display in the batch confirmation modal —
    /// selected `RemnantItem`s from every plan, mapped to `ScanResult`.
    public var batchSelectedScanResults: [ScanResult] {
        batchPlans
            .flatMap(\.allItems)
            .filter { selectedIDs.contains($0.id) }
            .map { $0.toScanResult() }
    }
}
