import AppKit
import SwiftUI

// MARK: - Dashboard View

/// Landing screen that turns raw system metrics and local scan evidence into a cleanup roadmap.
///
/// The dashboard leads with a triage pass that ranks the deeper cleanup tools,
/// then keeps supporting system metrics and evidence below the roadmap.
public struct DashboardView: View {
    @Binding var sidebarSelection: String?

    @Bindable private var session: DashboardSessionState
    private let persistence: PersistenceController?

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
        persistence: PersistenceController? = nil
    ) {
        self._sidebarSelection = sidebarSelection
        self.session = session
        self.persistence = persistence
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
        )
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
        session.hasRunTriageScan = true
        session.scanProgress = ScanProgress()
        let progress = session.scanProgress
        // Resolve the user's active profile up-front on MainActor so the
        // background scan honours their setting instead of always running
        // the Light profile (which excludes dev_artifacts/docker/homebrew
        // and would silently hide Dev Purge from the roadmap).
        let profile = resolveTriageProfile()
        Task {
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
            }
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
        scheduledScanSummary = try? persistence?.fetchPendingScheduledScanSummary()
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
        try? persistence?.acknowledgeScheduledScanSummary()
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
