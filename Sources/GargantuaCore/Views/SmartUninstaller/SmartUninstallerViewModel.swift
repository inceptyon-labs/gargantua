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

    public internal(set) var phase: SmartUninstallerPhase = .idle

    // MARK: - App picker state

    public internal(set) var apps: [AppInfo] = []
    public var query: String = ""
    public private(set) var sort: UninstallAppSort = .name
    public private(set) var sortAscending: Bool = UninstallAppSort.name.defaultAscending
    public var showSystemApps: Bool = false

    /// Bundle IDs the user has checked in the picker for batch uninstall.
    public internal(set) var multiSelected: Set<String> = []

    /// Distinct remnant-category counts per bundle ID, populated in the
    /// background after `loadApps()` so the picker can show "X categories"
    /// without forcing the user to drill in.
    public internal(set) var categoryCounts: [String: Int] = [:]

    /// Plans built up during a batch uninstall. Populated from
    /// `prepareBatchUninstall`; consumed by the confirmation modal and
    /// `executeBatch`.
    public internal(set) var batchPlans: [UninstallPlan] = []

    /// When true, the SmartUninstallerView should overlay the confirmation
    /// modal on top of the plan-review screen so the user can confirm and
    /// run a single-app uninstall without manually inspecting the plan.
    /// Set by `quickUninstall(_:)`; cleared on confirm/cancel/execute.
    public var quickConfirmActive = false

    /// Background task that fills `categoryCounts`. Cancelled when a new
    /// `loadApps` starts so we don't keep planning a stale app list.
    var categoryCountTask: Task<Void, Never>?

    /// In-flight scan / select / execute task. Stored so the EventHorizon
    /// console's "Sever Tether" button can cancel it. Always overwrite when
    /// starting new work — see `runTracked`.
    public var activeTask: Task<Void, Never>?

    // MARK: - Plan review state

    /// IDs of remnants the user has selected for removal. The app bundle is
    /// included here when selected.
    public internal(set) var selectedIDs: Set<String> = []
    /// Whether the user has explicitly unlocked protected items for this plan.
    public internal(set) var includeProtected: Bool = false

    // MARK: - Dependencies

    let appScanner: any AppScanning
    let planner: any UninstallPlanning
    let executor: any UninstallExecuting
    let authorizationProvider: @MainActor @Sendable () -> UninstallAuthorization?
    /// Delay between successful execution and the summary transition. Tunes
    /// how long the EventHorizonConsole stays visible so the spaghettify
    /// swallow animation has stage time. Set to 0 in tests.
    let postExecutionLinger: TimeInterval

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

    // MARK: - Sort

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

    // MARK: - Task tracking

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

    /// Return to the app picker and clear per-plan state.
    public func reset() {
        selectedIDs = []
        includeProtected = false
        batchPlans = []
        phase = .pickingApp
    }

    // MARK: - Observer wiring

    /// Wrap a scanner/executor with the live `pathStream` as observer,
    /// if the concrete type supports it via `withObserver(_:)`. Types
    /// that don't support it pass through unchanged (e.g. test stubs).
    func observing(_ scanner: any AppScanning) -> any AppScanning {
        // `DefaultAppScanner` accepts the observer at init; test stubs do
        // not. Since structs can't be retrofitted post-init, we return
        // the input untouched. The ViewModel's caller is expected to
        // construct the production scanner with the observer already
        // attached (see `SmartUninstallerView.makeDefaultViewModel`).
        return scanner
    }

    func observing(_ planner: any UninstallPlanning) -> any UninstallPlanning {
        if let remnant = planner as? RemnantScanner {
            return remnant.withObserver(pathStream)
        }
        return planner
    }

    func observing(_ executor: any UninstallExecuting) -> any UninstallExecuting {
        if let uninst = executor as? UninstallExecutor {
            return uninst.withObserver(pathStream)
        }
        return executor
    }
}
