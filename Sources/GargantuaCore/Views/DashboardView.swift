import AppKit
import OSLog
import SwiftUI

private let dashboardLogger = Logger(subsystem: "com.gargantua.core", category: "DashboardView")

// MARK: - Dashboard View

/// Landing screen that turns raw system metrics and local scan evidence into a cleanup roadmap.
///
/// The dashboard leads with a triage pass that ranks the deeper cleanup tools,
/// then keeps supporting system metrics and evidence below the roadmap.
public struct DashboardView: View {
    /// Probes the total on-demand Homebrew reclaimable bytes. Returns `nil`
    /// when Homebrew isn't installed or the dry-run fails. Blocking — invoked
    /// off the main actor. Injectable so tests don't shell out to `brew`.
    public typealias HomebrewReclaimableProvider = @Sendable () -> Int64?

    @Binding var sidebarSelection: String?

    @Bindable private var session: DashboardSessionState
    private let persistence: PersistenceController?
    private let homebrewReclaimableProvider: HomebrewReclaimableProvider
    /// Opens a fresh store for reads the scheduler process writes. The app's
    /// boot-time `persistence` caches settings in its long-lived context and
    /// never sees another process's write, so — like the menu bar — the
    /// scheduled-scan summary is read through a newly-opened controller to
    /// avoid showing stale data until relaunch.
    private let makeFreshPersistence: @MainActor () throws -> PersistenceController

    @State private var diskUsedGB: Int = 0
    @State private var diskTotalGB: Int = 0
    @State private var diskUsage: Double = 0
    @State private var isLoading = true
    @State private var scheduledScanSummary: ScheduledScanSummary?
    @State private var installedAppCount: Int = 0

    private var alerts: [AlertItem] {
        session.alerts
    }

    private var scanProgress: ScanProgress {
        session.scanProgress
    }

    private var hasRunTriageScan: Bool {
        session.hasRunTriageScan
    }

    private let collector = SystemMetricCollector()

    @MainActor
    public init(
        sidebarSelection: Binding<String?>,
        session: DashboardSessionState,
        persistence: PersistenceController? = nil,
        makeFreshPersistence: @escaping @MainActor () throws -> PersistenceController = { try PersistenceController() },
        homebrewReclaimableProvider: @escaping HomebrewReclaimableProvider = { HomebrewReclaimableProbe.probe() }
    ) {
        self._sidebarSelection = sidebarSelection
        self.session = session
        self.persistence = persistence
        self.makeFreshPersistence = makeFreshPersistence
        self.homebrewReclaimableProvider = homebrewReclaimableProvider
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if isLoading {
                Spacer()
                AccretionDiskView(activityRate: 18, size: 28, color: GargantuaColors.accretion)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: GargantuaSpacing.space5) {
                        triageOverviewSection
                        roadmapSection
                        homebrewSignpostSection
                        scheduledScanSection
                        triageEvidenceSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space4)
                }
            }
        }
        .background(GargantuaColors.void_)
        .task {
            await loadMetrics()
        }
    }

    // MARK: - Header

    private var header: some View {
        PageHeaderView(
            title: "Dashboard",
            subtitle: "Glance the system. Pick where to dig in next.",
            subtitleStyle: .voice
        ) {
            if hasRunTriageScan || scanProgress.isScanning {
                triageRefreshButton
            }
        }
    }

    private var triageRefreshButton: some View {
        Button(action: startTriageScan) {
            HStack(spacing: GargantuaSpacing.space1) {
                if scanProgress.isScanning {
                    AccretionDiskView(activityRate: 14, size: 12, color: GargantuaColors.accent)
                    Text("Scanning")
                        .font(GargantuaFonts.label)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Re-run triage")
                        .font(GargantuaFonts.label)
                }
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .disabled(scanProgress.isScanning)
        .keyboardShortcut("r", modifiers: .command)
        .help("Re-run triage to refresh reclaimable estimates after a cleanup (⌘R)")
        .accessibilityLabel("Re-run triage")
    }

    // MARK: - Triage Overview

    private var triageOverviewSection: some View {
        DashboardTriageOverviewSection(
            diskUsage: diskUsage,
            reclaimableFraction: reclaimableFraction,
            freeDiskGB: freeDiskGB,
            reclaimableSummary: reclaimableSummary,
            triageStatusPill: triageStatusPill,
            roadmapHeadline: roadmapHeadline,
            roadmapDetail: roadmapDetail,
            gaugeHelpText: gaugeHelpText
        )
    }

    private var reclaimableFraction: Double {
        let totalBytes = Double(diskTotalGB) * 1_073_741_824
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(totalAlertBytes) / totalBytes, 0), 1)
    }

    private var reclaimableSummary: String {
        "\(AlertItem.formatBytes(totalAlertBytes)) reclaimable"
    }

    private var gaugeHelpText: String {
        let used = Int((diskUsage * 100).rounded())
        if reclaimableFraction > 0 {
            let pct = Int((reclaimableFraction * 100).rounded())
            return "\(used)% disk used. Triage found \(reclaimableSummary) (\(pct)% of disk)."
        }
        return "\(used)% disk used. Run triage to estimate reclaim potential."
    }

    // MARK: - Roadmap

    private var roadmapSection: some View {
        DashboardRoadmapView(
            steps: roadmapSteps,
            isScanning: scanProgress.isScanning,
            onAction: performRoadmapAction
        )
    }

    // MARK: - Homebrew Signpost

    @ViewBuilder
    private var homebrewSignpostSection: some View {
        if let bytes = session.homebrewReclaimableBytes, bytes > 0 {
            DashboardHomebrewSignpost(
                reclaimableBytes: bytes,
                onOpen: { sidebarSelection = "devTools" }
            )
        }
    }

    // MARK: - Alerts Section

    @ViewBuilder
    private var scheduledScanSection: some View {
        if let scheduledScanSummary {
            ScheduledScanDashboardCard(
                summary: scheduledScanSummary,
                onReview: {
                    navigateTo(.deepClean)
                    acknowledgeScheduledScanSummary()
                },
                onDismiss: acknowledgeScheduledScanSummary
            )
        }
    }

    @ViewBuilder
    private var triageEvidenceSection: some View {
        if hasRunTriageScan || scanProgress.isScanning {
            DashboardSection(title: "TRIAGE EVIDENCE") {
                DashboardTriageEvidenceView(
                    alerts: alerts,
                    hasRunTriage: hasRunTriageScan,
                    scanProgress: scanProgress,
                    triageFailure: session.triageFailure,
                    onNavigate: navigateTo,
                    onScan: startTriageScan
                )
            }
        }
    }

    // MARK: - Actions

    private func navigateTo(_ destination: AlertDestination) {
        switch destination {
        case .deepClean: sidebarSelection = "deepClean"
        case .devPurge: sidebarSelection = "devPurge"
        case .diskExplorer: sidebarSelection = "diskExplorer"
        }
    }

    private func performRoadmapAction(_ action: DashboardRoadmapAction) {
        switch action {
        case .scan:
            startTriageScan()
        case .navigate(let selection):
            sidebarSelection = selection
        }
    }

    private func startTriageScan() {
        // beginTriageScan claims the slot synchronously — ⌘R key-repeat or a
        // double-click can't spawn a second overlapping scan in the window
        // before the adapter flips `scanProgress.isScanning`.
        guard session.beginTriageScan() else { return }
        refreshHomebrewSignpost()
        let progress = session.scanProgress
        // Resolve the user's active profile up-front on MainActor so the
        // background scan honours their setting instead of always running
        // the Light profile (which excludes dev_artifacts/docker/homebrew
        // and would silently hide Dev Purge from the roadmap).
        let profile = resolveTriageProfile()
        Task {
            defer { session.finishTriageScan() }
            do {
                let pathExclusions = staleVersionPinnedPaths()
                let adapter = try ProfileScanAdapterFactory.make(
                    profile: profile,
                    staleVersionPinnedPaths: pathExclusions,
                    aiModelExcludedPaths: pathExclusions
                )
                let results = try await adapter.scan(progress: progress)
                session.alerts = AlertItem.aggregate(from: results)
                session.lastTriageAt = Date()
            } catch {
                progress.recordError(error.localizedDescription)
                progress.finish(itemsFound: 0)
                session.triageFailure = error.localizedDescription
            }
        }
    }

    /// Probe the on-demand Homebrew reclaimable total off the main actor
    /// (it shells out to `brew`) and cache it for the signpost. Fired
    /// alongside each triage so a user who never opens Developer Tools still
    /// learns there's space to reclaim there. A `nil` result (Homebrew absent
    /// or dry-run failed) leaves the prior value untouched rather than hiding
    /// a still-valid signpost on a transient failure.
    private func refreshHomebrewSignpost() {
        let provider = homebrewReclaimableProvider
        Task {
            let bytes = await Task.detached(priority: .utility) { provider() }.value
            if let bytes { session.homebrewReclaimableBytes = bytes }
        }
    }

    private func resolveTriageProfile() -> CleanupProfile {
        guard let persistence else { return .deep }
        do {
            let settings = try persistence.fetchSettings()
            let persisted = (try? persistence.fetchProfiles()) ?? []
            return CleanupProfile.resolve(
                activeProfileID: settings.activeProfileID,
                persisted: persisted,
                fallback: .deep
            )
        } catch {
            return .deep
        }
    }

    private func staleVersionPinnedPaths() -> Set<String> {
        guard let persistence else { return [] }
        return Set(((try? persistence.fetchExclusionEntries()) ?? []).map(\.pattern))
    }

    private func loadMetrics() async {
        let metrics = await collector.collect()
        diskTotalGB = Int(metrics.diskTotal / (1024 * 1024 * 1024))
        diskUsedGB = Int(metrics.diskUsed / (1024 * 1024 * 1024))
        diskUsage = metrics.diskUsage
        scheduledScanSummary = try? makeFreshPersistence().fetchPendingScheduledScanSummary()
        installedAppCount = await Self.countInstalledApps()
        isLoading = false
    }

    /// Cheap user-installed-app count for the Smart Uninstaller roadmap pill.
    /// Walks `/Applications`, `~/Applications`, `/System/Applications`, and
    /// running-app bundles, then drops `/System/` paths. Single directory
    /// enumeration with `skipsPackageDescendants` — fast enough for the
    /// dashboard's first paint.
    private static func countInstalledApps() async -> Int {
        let urls = DefaultAppBundleEnumerator().enumerateBundles()
        return urls.filter { !$0.path.hasPrefix("/System/") }.count
    }

    private func acknowledgeScheduledScanSummary() {
        scheduledScanSummary = nil
        do {
            try makeFreshPersistence().acknowledgeScheduledScanSummary()
        } catch {
            // A failed acknowledge means the card comes back next launch. The
            // dismissal still holds for this session; log it so the resurrection
            // is explicable rather than looking like the dismiss button is broken.
            dashboardLogger.warning(
                "Failed to persist scheduled-scan acknowledgement: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Dashboard Derivation

private extension DashboardView {
    var roadmapPlanner: DashboardRoadmapPlanner {
        DashboardRoadmapPlanner(
            alerts: alerts,
            scanProgress: scanProgress,
            hasRunTriageScan: hasRunTriageScan,
            triageIsStale: session.triageIsStale,
            triageAgeLabel: session.triageAgeLabel,
            diskUsage: diskUsage,
            freeDiskGB: freeDiskGB,
            installedAppCount: installedAppCount
        )
    }

    var roadmapHeadline: String {
        roadmapPlanner.headline
    }

    var roadmapDetail: String {
        roadmapPlanner.detail
    }

    var triageStatusPill: String {
        roadmapPlanner.statusPill
    }

    var roadmapSteps: [DashboardRoadmapStep] {
        roadmapPlanner.steps
    }

    var freeDiskGB: Int {
        max(diskTotalGB - diskUsedGB, 0)
    }

    var totalAlertBytes: Int64 {
        alerts.reduce(Int64(0)) { $0 + $1.reclaimableSize }
    }
}
