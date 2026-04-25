import AppKit
import SwiftUI

// MARK: - Dashboard View

/// Landing screen that turns raw system metrics into a recommended next step.
///
/// The dashboard leads with one evidence-backed cleanup recommendation,
/// then shows supporting system metrics and the largest reclaimable groups
/// from the latest quick scan.
public struct DashboardView: View {
    @Binding var sidebarSelection: String?

    private let persistence: PersistenceController?

    @State private var healthScore: Int = 0
    @State private var diskUsedGB: Int = 0
    @State private var diskTotalGB: Int = 0
    @State private var diskUsage: Double = 0
    @State private var memoryUsedGB: Int = 0
    @State private var memoryTotalGB: Int = 0
    @State private var memoryPressure: Double = 0
    @State private var thermalLevel: ThermalLevel = .nominal
    @State private var alerts: [AlertItem] = []
    @State private var scanProgress = ScanProgress()
    @State private var isLoading = true
    @State private var hasRunQuickScan = false
    @State private var cloudStatus: CloudAIStatus?
    @State private var scheduledScanSummary: ScheduledScanSummary?
    @StateObject private var mcpStatusModel: MCPServerStatusViewModel

    private let collector = SystemMetricCollector()

    @MainActor
    public init(sidebarSelection: Binding<String?>, persistence: PersistenceController? = nil) {
        self._sidebarSelection = sidebarSelection
        self.persistence = persistence
        self._mcpStatusModel = StateObject(wrappedValue: MCPServerStatusViewModel())
    }

    @MainActor
    public init(
        sidebarSelection: Binding<String?>,
        persistence: PersistenceController? = nil,
        mcpStatusModel: MCPServerStatusViewModel
    ) {
        self._sidebarSelection = sidebarSelection
        self.persistence = persistence
        self._mcpStatusModel = StateObject(wrappedValue: mcpStatusModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: GargantuaSpacing.space5) {
                        recommendationSection
                        systemSnapshotSection
                        scheduledScanSection
                        alertsSection
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space4)
                }
            }
        }
        .background(GargantuaColors.void_)
        .task {
            await loadMetrics()
            await refreshMCPStatusLoop()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text("Dashboard")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text("Start with the strongest cleanup recommendation, then drill into evidence.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space4)
    }

    // MARK: - Recommendation

    private var recommendationSection: some View {
        let recommendation = dashboardRecommendation
        return VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space5) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                    Text(recommendation.eyebrow)
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(recommendation.tone)

                    Text(recommendation.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(recommendation.detail)
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: GargantuaSpacing.space2) {
                        ForEach(recommendation.evidence, id: \.self) { item in
                            DashboardEvidencePill(text: item)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: GargantuaSpacing.space3) {
                        Button(action: recommendation.primaryAction) {
                            Text(recommendation.primaryLabel)
                                .font(GargantuaFonts.label)
                                .foregroundStyle(.white)
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.vertical, GargantuaSpacing.space2)
                                .background(GargantuaColors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                        }
                        .buttonStyle(.plain)
                        .disabled(scanProgress.isScanning)
                        .opacity(scanProgress.isScanning ? 0.6 : 1)

                        if recommendation.showsRefresh {
                            Button(action: startQuickScan) {
                                Text("Refresh Recommendations")
                                    .font(GargantuaFonts.label)
                                    .foregroundStyle(GargantuaColors.ink)
                                    .padding(.horizontal, GargantuaSpacing.space4)
                                    .padding(.vertical, GargantuaSpacing.space2)
                                    .background(
                                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                            .fill(GargantuaColors.surface3)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                            .stroke(GargantuaColors.borderEm, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(scanProgress.isScanning)
                            .opacity(scanProgress.isScanning ? 0.6 : 1)
                        }
                    }
                }

                Spacer(minLength: GargantuaSpacing.space5)

                DashboardStatusPanel(
                    healthScore: healthScore,
                    healthLabel: healthLabel,
                    freeDiskText: "\(freeDiskGB) GB free",
                    freeDiskDetail: diskPressureSummary,
                    highlightColor: diskBarColor
                )
                .frame(maxWidth: 240)
            }

            if !scanProgress.errors.isEmpty {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GargantuaColors.review)

                    Text(scanProgress.errors.first ?? "Quick scan failed.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(2)
                }
            }
        }
        .padding(GargantuaSpacing.space5)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    // MARK: - System Snapshot

    private var systemSnapshotSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text("SYSTEM SNAPSHOT")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 180), spacing: GargantuaSpacing.space3),
                    GridItem(.flexible(minimum: 180), spacing: GargantuaSpacing.space3),
                ],
                spacing: GargantuaSpacing.space3
            ) {
                DashboardMetricCard(
                    label: "Composite Health",
                    value: "\(healthScore)",
                    detail: healthSummaryText,
                    tone: HealthScoreRange(score: healthScore).color
                )
                DashboardMetricCard(
                    label: "Disk",
                    value: "\(freeDiskGB) GB free",
                    detail: "\(diskUsedGB) / \(diskTotalGB) GB used",
                    tone: diskBarColor
                )
                DashboardMetricCard(
                    label: "Memory Pressure",
                    value: "\(Int((memoryPressure * 100).rounded()))%",
                    detail: "\(memoryUsedGB) / \(memoryTotalGB) GB in use",
                    tone: memoryTone
                )
                DashboardMetricCard(
                    label: "Thermal",
                    value: thermalTitle,
                    detail: thermalDetail,
                    tone: thermalTone
                )
                DashboardCloudAIMetricCard(status: cloudStatus)
                DashboardMCPStatusCard(
                    model: mcpStatusModel,
                    onOpenAuditLog: openMCPAuditLog
                )
            }
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

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("EVIDENCE")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Text("Largest reclaimable groups from the latest quick scan.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            AlertListView(
                alerts: alerts,
                onNavigate: { destination in
                    navigateTo(destination)
                },
                scanProgress: scanProgress,
                onScan: { startQuickScan() },
                sectionTitle: "Largest reclaimable groups"
            )
            .background(GargantuaColors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func navigateTo(_ destination: AlertDestination) {
        switch destination {
        case .deepClean:    sidebarSelection = "deepClean"
        case .devPurge:     sidebarSelection = "devPurge"
        case .diskExplorer: sidebarSelection = "diskExplorer"
        }
    }

    private func startQuickScan() {
        hasRunQuickScan = true
        scanProgress = ScanProgress()
        Task {
            do {
                let adapter = try NativeScanAdapter.loadDefaults(profile: .light)
                let results = try await adapter.scan(progress: scanProgress)
                alerts = AlertItem.aggregate(from: results)
            } catch {
                scanProgress.recordError(error.localizedDescription)
                scanProgress.finish(itemsFound: 0)
            }
        }
    }

    private func openMCPAuditLog() {
        let logFile = AuditWriter().logFile
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        }
    }

    private func refreshMCPStatusLoop() async {
        while !Task.isCancelled {
            await MainActor.run {
                mcpStatusModel.refresh()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func loadMetrics() async {
        let metrics = await collector.collect()
        healthScore = metrics.healthScore
        diskTotalGB = Int(metrics.diskTotal / (1024 * 1024 * 1024))
        diskUsedGB = Int(metrics.diskUsed / (1024 * 1024 * 1024))
        diskUsage = metrics.diskUsage
        memoryTotalGB = Int(metrics.memoryTotal / (1024 * 1024 * 1024))
        memoryUsedGB = Int(metrics.memoryUsed / (1024 * 1024 * 1024))
        memoryPressure = metrics.memoryPressure
        thermalLevel = metrics.thermalLevel
        cloudStatus = await CloudAIStatusProvider.snapshot()
        scheduledScanSummary = try? persistence?.fetchPendingScheduledScanSummary()
        isLoading = false
    }

    private func acknowledgeScheduledScanSummary() {
        scheduledScanSummary = nil
        try? persistence?.acknowledgeScheduledScanSummary()
    }

    // MARK: - Recommendation Model

    private struct Recommendation {
        let eyebrow: String
        let title: String
        let detail: String
        let evidence: [String]
        let primaryLabel: String
        let primaryAction: () -> Void
        let showsRefresh: Bool
        let tone: Color
    }

    private var dashboardRecommendation: Recommendation {
        if let topAlert = alerts.first {
            return Recommendation(
                eyebrow: "RECOMMENDED NEXT STEP",
                title: "Review \(topAlert.headline)",
                detail: "This is the biggest actionable pile from your latest quick scan. Start here before exploring lower-value cleanup work.",
                evidence: [
                    topAlert.detail,
                    destinationLabel(topAlert.destination),
                    topAlert.staleness ?? "recently verified",
                ],
                primaryLabel: primaryLabel(for: topAlert.destination),
                primaryAction: { navigateTo(topAlert.destination) },
                showsRefresh: true,
                tone: tone(for: topAlert.destination)
            )
        }

        if hasRunQuickScan {
            return Recommendation(
                eyebrow: "NO URGENT CLEANUP DETECTED",
                title: "Quick Scan did not find actionable cleanup",
                detail: """
                Nothing safe or review-tier stood out in the last pass. You can run another scan later or inspect the \
                system manually if disk pressure keeps climbing.
                """,
                evidence: [
                    "\(freeDiskGB) GB free",
                    healthSummaryText,
                    thermalTitle,
                ],
                primaryLabel: "Run Quick Scan Again",
                primaryAction: startQuickScan,
                showsRefresh: false,
                tone: GargantuaColors.safe
            )
        }

        return Recommendation(
            eyebrow: "BUILD RECOMMENDATIONS",
            title: "Run a quick scan before making cleanup decisions",
            detail: """
            The dashboard can show evidence-backed cleanup priorities, but it needs one lightweight scan first. \
            Gargantua will surface the biggest reclaimable groups and route you to the right tool.
            """,
            evidence: [
                "\(freeDiskGB) GB free",
                healthSummaryText,
                "local scan only",
            ],
            primaryLabel: "Run Quick Scan",
            primaryAction: startQuickScan,
            showsRefresh: false,
            tone: GargantuaColors.accent
        )
    }
}

private struct ScheduledScanDashboardCard: View {
    let summary: ScheduledScanSummary
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            Image(systemName: summary.errorMessage == nil ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tone)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(summary.headline)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("\(summary.detail) · \(summary.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            if summary.errorMessage == nil {
                Button(action: onReview) {
                    Text("Review")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 24, height: 24)
                    .background(GargantuaColors.surface3)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss scheduled scan summary")
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(tone.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var tone: Color {
        summary.errorMessage == nil ? GargantuaColors.safe : GargantuaColors.review
    }
}

private extension DashboardView {
    var freeDiskGB: Int {
        max(diskTotalGB - diskUsedGB, 0)
    }

    var diskBarColor: Color {
        if diskUsage > 0.9 { return GargantuaColors.protected_ }
        if diskUsage > 0.75 { return GargantuaColors.review }
        return GargantuaColors.safe
    }

    var memoryTone: Color {
        if memoryPressure > 0.85 { return GargantuaColors.protected_ }
        if memoryPressure > 0.65 { return GargantuaColors.review }
        return GargantuaColors.safe
    }

    var thermalTone: Color {
        switch thermalLevel {
        case .nominal: return GargantuaColors.safe
        case .fair: return GargantuaColors.review
        case .serious, .critical: return GargantuaColors.protected_
        }
    }

    var healthLabel: String {
        switch HealthScoreRange(score: healthScore) {
        case .healthy: return "Healthy"
        case .moderate: return "Needs attention"
        case .poor: return "Pressure rising"
        }
    }

    var healthSummaryText: String {
        switch HealthScoreRange(score: healthScore) {
        case .healthy:
            return "System looks stable overall."
        case .moderate:
            return "Some pressure is building."
        case .poor:
            return "The machine is under sustained pressure."
        }
    }

    var diskPressureSummary: String {
        if diskUsage > 0.9 { return "Disk pressure is high." }
        if diskUsage > 0.75 { return "Free space is getting tight." }
        return "Enough headroom for normal work."
    }

    var thermalTitle: String {
        thermalLevel.rawValue.capitalized
    }

    var thermalDetail: String {
        switch thermalLevel {
        case .nominal: return "No thermal pressure."
        case .fair: return "Warm, but still stable."
        case .serious: return "Performance may throttle."
        case .critical: return "System is heavily constrained."
        }
    }

    func destinationLabel(_ destination: AlertDestination) -> String {
        switch destination {
        case .deepClean: return "Deep Clean"
        case .devPurge: return "Dev Artifact Purge"
        case .diskExplorer: return "Disk Explorer"
        }
    }

    func primaryLabel(for destination: AlertDestination) -> String {
        "Open \(destinationLabel(destination))"
    }

    func tone(for destination: AlertDestination) -> Color {
        switch destination {
        case .deepClean: return GargantuaColors.accent
        case .devPurge: return GargantuaColors.review
        case .diskExplorer: return GargantuaColors.safe
        }
    }
}

private struct DashboardStatusPanel: View {
    let healthScore: Int
    let healthLabel: String
    let freeDiskText: String
    let freeDiskDetail: String
    let highlightColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("CURRENT PRESSURE")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            Text("\(healthScore)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(GargantuaColors.ink)

            Text(healthLabel)
                .font(GargantuaFonts.label)
                .foregroundStyle(highlightColor)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
                .padding(.vertical, GargantuaSpacing.space2)

            Text(freeDiskText)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)

            Text(freeDiskDetail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }
}

private struct DashboardMetricCard: View {
    let label: String
    let value: String
    let detail: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text(label.uppercased())
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink)

            Text(detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(tone)
                .frame(width: 28, height: 2)
                .padding(.horizontal, GargantuaSpacing.space4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }
}

private struct DashboardEvidencePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(
                Capsule()
                    .fill(GargantuaColors.surface3)
            )
            .overlay(
                Capsule()
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
    }
}
