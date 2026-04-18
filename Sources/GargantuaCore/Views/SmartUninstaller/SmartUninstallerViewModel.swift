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
    public var sort: UninstallAppSort = .name
    public var showSystemApps: Bool = false

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

    /// Live path-streaming view model backing the Event Horizon Console.
    /// Observed by the scanners and executor when they support it (via
    /// `withObserver(_:)` on concrete types).
    public let pathStream: PathStreamViewModel

    public init(
        appScanner: any AppScanning,
        planner: any UninstallPlanning,
        executor: any UninstallExecuting,
        authorizationProvider: @escaping @MainActor @Sendable () -> UninstallAuthorization? = { nil },
        pathStream: PathStreamViewModel = PathStreamViewModel()
    ) {
        self.appScanner = appScanner
        self.planner = planner
        self.executor = executor
        self.authorizationProvider = authorizationProvider
        self.pathStream = pathStream
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

        switch sort {
        case .name:
            return filtered.sorted { lhs, rhs in
                lhs.displayName ?? lhs.name < rhs.displayName ?? rhs.name
            }
        case .size:
            return filtered.sorted { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
        case .lastUsed:
            return filtered.sorted { lhs, rhs in
                switch (lhs.lastUsedDate, rhs.lastUsedDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name < rhs.name
                }
            }
        }
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
        apps = loaded
        phase = .pickingApp
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
            phase = .summary(prunedPlan, result)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
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
        phase = .pickingApp
    }
}
