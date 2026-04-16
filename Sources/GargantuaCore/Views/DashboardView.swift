import SwiftUI

// MARK: - Dashboard View

/// Landing screen showing system health, disk usage, and actionable alerts.
///
/// Composes ``HealthGaugeView`` for the health score arc,
/// disk usage stats from ``SystemMetricCollector``, and
/// ``AlertListView`` for reclaimable space alerts with navigation.
public struct DashboardView: View {
    @Binding var sidebarSelection: String?

    @State private var healthScore: Int = 0
    @State private var diskUsedGB: Int = 0
    @State private var diskTotalGB: Int = 0
    @State private var diskUsage: Double = 0
    @State private var alerts: [AlertItem] = []
    @State private var scanProgress = ScanProgress()
    @State private var isLoading = true

    private let collector = SystemMetricCollector()

    public init(sidebarSelection: Binding<String?>) {
        self._sidebarSelection = sidebarSelection
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Dashboard")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

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
                        healthSection
                        alertsSection
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space4)
                }
            }
        }
        .background(GargantuaColors.void_)
        .task { await loadMetrics() }
    }

    // MARK: - Health Section

    private var healthSection: some View {
        HStack(spacing: GargantuaSpacing.space5) {
            HealthGaugeView(score: healthScore, size: 140, lineWidth: 10)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                // Disk usage
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text("Disk Usage")
                        .font(GargantuaFonts.sectionLabel)
                        .foregroundStyle(GargantuaColors.ink4)
                        .tracking(0.08 * 10)
                        .textCase(.uppercase)

                    Text("\(diskUsedGB) / \(diskTotalGB) GB")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)

                    // Usage bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(GargantuaColors.surface2)
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(diskBarColor)
                                .frame(width: geo.size.width * diskUsage, height: 6)
                        }
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 200)
                }

                // Status line
                Text(statusText)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var diskBarColor: Color {
        if diskUsage > 0.9 { return GargantuaColors.protected_ }
        if diskUsage > 0.75 { return GargantuaColors.review }
        return GargantuaColors.safe
    }

    private var statusText: String {
        let freeGB = diskTotalGB - diskUsedGB
        let range = HealthScoreRange(score: healthScore)
        switch range {
        case .healthy:  return "\(freeGB) GB free — system is healthy"
        case .moderate: return "\(freeGB) GB free — consider cleaning up"
        case .poor:     return "\(freeGB) GB free — disk space is low"
        }
    }

    // MARK: - Alerts Section

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlertListView(
                alerts: alerts,
                onNavigate: { destination in
                    navigateTo(destination)
                },
                scanProgress: scanProgress,
                onScan: { startQuickScan() }
            )
        }
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
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
        scanProgress = ScanProgress()
        Task {
            let runner = MoleRunner()
            let adapter = MoCleanAdapter(runner: runner)
            do {
                let results = try await adapter.scan(progress: scanProgress)
                alerts = AlertItem.aggregate(from: results)
            } catch {
                // Errors recorded in scanProgress
            }
        }
    }

    private func loadMetrics() async {
        do {
            let metrics = try await collector.collect()
            healthScore = metrics.healthScore
            diskTotalGB = Int(metrics.diskTotal / (1024 * 1024 * 1024))
            diskUsedGB = Int(metrics.diskUsed / (1024 * 1024 * 1024))
            diskUsage = metrics.diskUsage
        } catch {
            // Fallback: show zeros, not an error state
        }
        isLoading = false
    }
}
