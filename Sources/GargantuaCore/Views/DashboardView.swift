import AppKit
import SwiftUI

// swiftlint:disable file_length
// File-length over the 1000-line ceiling because this is the cockpit screen
// — many sub-sections (alerts, roadmap, metrics) live in one file by design.
// Tracked for refactor in a separate bean.

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
        HStack(alignment: .top, spacing: GargantuaSpacing.space5) {
            HealthGaugeView(
                diskUsage: diskUsage,
                reclaimableFraction: reclaimableFraction
            )
            .help(gaugeHelpText)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                Text("CLEANUP ROADMAP")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Text(roadmapHeadline)
                    .font(GargantuaFonts.title)
                    .foregroundStyle(GargantuaColors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roadmapDetail)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(maxWidth: 760, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: GargantuaSpacing.space2) {
                    DashboardEvidencePill(text: "\(freeDiskGB) GB free", monospaced: true)
                    if reclaimableFraction > 0 {
                        DashboardEvidencePill(text: reclaimableSummary, monospaced: true)
                    }
                    DashboardEvidencePill(text: triageStatusPill)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
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
        DashboardSection(title: "NEXT ACTIONS") {
            VStack(spacing: 0) {
                ForEach(roadmapSteps) { step in
                    DashboardRoadmapRow(
                        step: step,
                        isScanning: scanProgress.isScanning,
                        onAction: { performRoadmapAction(step.action) }
                    )

                    if step.id != roadmapSteps.last?.id {
                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
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
        Task {
            do {
                let adapter = try NativeScanAdapter.loadDefaults(profile: .light)
                let results = try await adapter.scan(progress: progress)
                session.alerts = AlertItem.aggregate(from: results)
                session.lastTriageAt = Date()
            } catch {
                progress.recordError(error.localizedDescription)
                progress.finish(itemsFound: 0)
            }
        }
    }

    private func loadMetrics() async {
        let metrics = await collector.collect()
        diskTotalGB = Int(metrics.diskTotal / (1024 * 1024 * 1024))
        diskUsedGB = Int(metrics.diskUsed / (1024 * 1024 * 1024))
        diskUsage = metrics.diskUsage
        scheduledScanSummary = try? persistence?.fetchPendingScheduledScanSummary()
        isLoading = false
    }

    private func acknowledgeScheduledScanSummary() {
        scheduledScanSummary = nil
        try? persistence?.acknowledgeScheduledScanSummary()
    }
}

// MARK: - Roadmap Model

fileprivate enum DashboardRoadmapAction: Equatable {
    case scan
    case navigate(String)
}

fileprivate struct DashboardRoadmapStep: Identifiable {
    let id: String
    let rank: Int
    let title: String
    let status: String
    let detail: String
    let evidence: [String]
    let actionLabel: String
    let systemImage: String
    let action: DashboardRoadmapAction
}

private struct DashboardRoadmapAggregate {
    let size: Int64
    let itemCount: Int
    let categories: [String]
}

private extension DashboardView {
    var roadmapHeadline: String {
        if scanProgress.isScanning { return "Building the cleanup roadmap" }
        if !hasRunTriageScan { return "Run triage, then follow the tool roadmap" }
        if session.triageIsStale {
            return "Triage is \(session.triageAgeLabel) — refresh before acting"
        }
        if alerts.isEmpty { return "No obvious bulk cleanup found by triage" }
        return "Start with \(roadmapSteps.first?.title ?? "the top cleanup step")"
    }

    var roadmapDetail: String {
        if scanProgress.isScanning {
            return "The triage scan is checking lightweight local rules and grouping findings by the tool that should handle them."
        }
        if !hasRunTriageScan {
            return "Triage checks caches, logs, trash, installers, and developer artifacts. "
                + "It does not uninstall apps or run duplicate matching. "
                + "Its job is to rank which deeper tool you should open first."
        }
        if session.triageIsStale {
            return "The last triage finished \(session.triageAgeLabel). Disk state may have shifted — re-run before you act on the roadmap below."
        }
        if alerts.isEmpty {
            return "The lightweight pass did not find safe or review-tier cleanup groups. Use the manual tools below when disk pressure still feels wrong."
        }
        return "The list below is ordered from highest reclaimable impact to deeper manual passes. Each row routes to the tool that owns that kind of cleanup."
    }

    var triageStatusTitle: String {
        if scanProgress.isScanning { return "Scanning" }
        if !hasRunTriageScan { return "Not run" }
        if alerts.isEmpty { return "No bulk finds" }
        return "\(alerts.count) groups found"
    }

    var triageStatusDetail: String {
        if scanProgress.isScanning {
            if let category = scanProgress.currentCategory {
                return "Checking \(category)."
            }
            return "Checking local cleanup rules."
        }
        if !hasRunTriageScan {
            return "Creates a route through Deep Clean, Dev Artifact Purge, Disk Explorer, and manual follow-up tools."
        }
        if alerts.isEmpty {
            return "Safe and review-tier groups did not cross the roadmap threshold."
        }
        return "\(AlertItem.formatBytes(totalAlertBytes)) across \(totalAlertItems) actionable items."
    }

    var triageStatusPill: String {
        if scanProgress.isScanning { return "triage running" }
        if !hasRunTriageScan { return "triage not run" }
        if session.triageIsStale { return "triage \(session.triageAgeLabel) · refresh" }
        if alerts.isEmpty { return "triage clear" }
        return "\(alerts.count) triage groups"
    }

    var triageButtonLabel: String {
        if scanProgress.isScanning { return "Scanning" }
        return hasRunTriageScan ? "Refresh Triage" : "Run Triage Scan"
    }

    var roadmapSteps: [DashboardRoadmapStep] {
        if scanProgress.isScanning {
            return scanningRoadmap
        }

        if !hasRunTriageScan && !scanProgress.isScanning {
            return preTriageRoadmap
        }

        let base = alerts.isEmpty ? noFindingsRoadmap : alertDrivenRoadmap

        if session.triageIsStale {
            return [staleTriageStep] + bumpedRanks(base)
        }
        return base
    }

    var staleTriageStep: DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: "triage-refresh",
            rank: 1,
            title: "Refresh Triage",
            status: "Stale",
            detail: "Last triage finished \(session.triageAgeLabel). Re-run the lightweight pass so the roadmap reflects what's on disk now.",
            evidence: ["local only", "safe + review items", "no deletion"],
            actionLabel: "Refresh Triage",
            systemImage: "arrow.clockwise",
            action: .scan
        )
    }

    func bumpedRanks(_ steps: [DashboardRoadmapStep]) -> [DashboardRoadmapStep] {
        steps.enumerated().map { index, step in
            DashboardRoadmapStep(
                id: step.id,
                rank: index + 2,
                title: step.title,
                status: step.status == "Start here" ? "Top reclaim" : step.status,
                detail: step.detail,
                evidence: step.evidence,
                actionLabel: step.actionLabel,
                systemImage: step.systemImage,
                action: step.action
            )
        }
    }

    var scanningRoadmap: [DashboardRoadmapStep] {
        [
            DashboardRoadmapStep(
                id: "triage-running",
                rank: 1,
                title: "Triage Scan",
                status: "Scanning",
                detail: scanProgress.currentCategory.map { "Checking \($0) and grouping matches by cleanup tool." }
                    ?? "Checking lightweight local rules and building the ordered tool list.",
                evidence: [
                    "\(Int((scanProgress.fractionCompleted * 100).rounded()))% complete",
                    scanProgress.itemsFound > 0 ? "\(scanProgress.itemsFound) items found" : "collecting evidence",
                ],
                actionLabel: "Scanning",
                systemImage: "hourglass",
                action: .scan
            ),
        ]
    }

    var preTriageRoadmap: [DashboardRoadmapStep] {
        [
            DashboardRoadmapStep(
                id: "triage",
                rank: 1,
                title: "Run Triage Scan",
                status: "Needed",
                detail: "Builds this roadmap from lightweight local cleanup rules before you spend time in deeper tools.",
                evidence: ["local only", "safe + review items", "no deletion"],
                actionLabel: "Run Triage",
                systemImage: "list.bullet.clipboard",
                action: .scan
            ),
            baselineStep(
                id: "deepClean",
                rank: 2,
                title: "Deep Clean",
                status: "Common first pass",
                detail: "Caches, logs, temporary files, trash, and installers. Triage can usually route concrete findings here.",
                evidence: ["caches", "logs", "trash"],
                systemImage: "bubbles.and.sparkles",
                selection: "deepClean"
            ),
            baselineStep(
                id: "devPurge",
                rank: 3,
                title: "Dev Artifact Purge",
                status: "Developer cleanup",
                detail: "Node, Docker, Homebrew, Xcode, and build outputs. This is where developer-disk pressure usually lives.",
                evidence: ["node_modules", "Docker", "build caches"],
                systemImage: "hammer",
                selection: "devPurge"
            ),
            baselineStep(
                id: "smartUninstaller",
                rank: 4,
                title: "Smart Uninstaller",
                status: "Manual app pass",
                detail: "Use when large apps or remnants are the real target. Triage does not decide which apps you want removed.",
                evidence: ["apps", "remnants", "user intent"],
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            baselineStep(
                id: "duplicateFinder",
                rank: 5,
                title: "Duplicate Finder",
                status: "Deeper scan",
                detail: "Run after obvious bulk cleanup. Duplicate matching costs more time than triage, so it belongs later.",
                evidence: ["content match", "review required"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
        ]
    }

    var noFindingsRoadmap: [DashboardRoadmapStep] {
        [
            baselineStep(
                id: "diskExplorer",
                rank: 1,
                title: "Disk Explorer",
                status: diskUsage > 0.75 ? "Inspect pressure" : "Optional",
                detail: "Use this when the numbers still feel wrong. It shows where space is going without relying on cleanup rules.",
                evidence: ["manual inspection", "\(freeDiskGB) GB free"],
                systemImage: "internaldrive",
                selection: "diskExplorer"
            ),
            baselineStep(
                id: "smartUninstaller",
                rank: 2,
                title: "Smart Uninstaller",
                status: "Manual app pass",
                detail: "Look for large apps and remnants that triage intentionally avoids because app removal needs user intent.",
                evidence: ["apps", "remnants"],
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            baselineStep(
                id: "duplicateFinder",
                rank: 3,
                title: "Duplicate Finder",
                status: "Deeper scan",
                detail: "Check duplicate files after the cheap cleanup pass is clear.",
                evidence: ["content match", "manual review"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
            baselineStep(
                id: "fileHealth",
                rank: 4,
                title: "File Health",
                status: "Integrity check",
                detail: "Review broken links, risky leftovers, and file-health issues that are not primarily space reclamation.",
                evidence: ["broken links", "risk review"],
                systemImage: "stethoscope",
                selection: "fileHealth"
            ),
        ]
    }

    var alertDrivenRoadmap: [DashboardRoadmapStep] {
        var rank = 1
        var steps: [DashboardRoadmapStep] = []
        let destinations = [AlertDestination.deepClean, .devPurge, .diskExplorer]

        for destination in destinations.compactMap({ destination in
            alertAggregate(for: destination).map { (destination, $0) }
        }).sorted(by: { $0.1.size > $1.1.size }) {
            let (target, aggregate) = destination
            steps.append(alertStep(destination: target, aggregate: aggregate, rank: rank))
            rank += 1
        }

        let followUps = [
            baselineStep(
                id: "smartUninstaller",
                rank: rank,
                title: "Smart Uninstaller",
                status: "Manual follow-up",
                detail: "Use after reclaimable groups if installed apps or orphaned remnants are the likely source.",
                evidence: ["apps + remnants", "not triage-owned"],
                systemImage: "trash.slash",
                selection: "smartUninstaller"
            ),
            baselineStep(
                id: "duplicateFinder",
                rank: rank + 1,
                title: "Duplicate Finder",
                status: "Deeper pass",
                detail: "Run once the obvious cleanup is handled. Duplicate matching is slower and needs explicit review.",
                evidence: ["content match", "review required"],
                systemImage: "doc.on.doc",
                selection: "duplicateFinder"
            ),
            baselineStep(
                id: "diskExplorer",
                rank: rank + 2,
                title: "Disk Explorer",
                status: "Verify space",
                detail: "Use if free space is still tight after the recommended cleanup passes.",
                evidence: ["space map", "\(freeDiskGB) GB free"],
                systemImage: "internaldrive",
                selection: "diskExplorer"
            ),
        ].filter { followUp in
            !steps.contains { $0.id == followUp.id }
        }
        steps.append(contentsOf: followUps)

        return steps
    }

    var totalAlertBytes: Int64 {
        alerts.reduce(Int64(0)) { $0 + $1.reclaimableSize }
    }

    var totalAlertItems: Int {
        alerts.reduce(0) { $0 + $1.itemCount }
    }

    func alertAggregate(for destination: AlertDestination) -> DashboardRoadmapAggregate? {
        let matching = alerts.filter { $0.destination == destination }
        guard !matching.isEmpty else { return nil }
        let categories = Array(Set(matching.map(\.categoryLabel))).sorted()
        return DashboardRoadmapAggregate(
            size: matching.reduce(Int64(0)) { $0 + $1.reclaimableSize },
            itemCount: matching.reduce(0) { $0 + $1.itemCount },
            categories: categories
        )
    }

    func alertStep(
        destination: AlertDestination,
        aggregate: DashboardRoadmapAggregate,
        rank: Int
    ) -> DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: destination.rawValue,
            rank: rank,
            title: destinationLabel(destination),
            status: rank == 1 ? "Start here" : "Then check",
            detail: roadmapDetail(for: destination),
            evidence: [
                AlertItem.formatBytes(aggregate.size),
                aggregate.itemCount == 1 ? "1 item" : "\(aggregate.itemCount) items",
                aggregate.categories.prefix(2).joined(separator: ", "),
            ].filter { !$0.isEmpty },
            actionLabel: "Open",
            systemImage: systemImage(for: destination),
            action: .navigate(destination.rawValue)
        )
    }

    func baselineStep(
        id: String,
        rank: Int,
        title: String,
        status: String,
        detail: String,
        evidence: [String],
        systemImage: String,
        selection: String
    ) -> DashboardRoadmapStep {
        DashboardRoadmapStep(
            id: id,
            rank: rank,
            title: title,
            status: status,
            detail: detail,
            evidence: evidence,
            actionLabel: "Open",
            systemImage: systemImage,
            action: .navigate(selection)
        )
    }

    func roadmapDetail(for destination: AlertDestination) -> String {
        switch destination {
        case .deepClean:
            return "Review safe and review-tier cleanup groups: caches, logs, trash, installers, and temporary files."
        case .devPurge:
            return "Clear developer artifacts that can usually be rebuilt: Node dependencies, Docker data, Homebrew cache, and build outputs."
        case .diskExplorer:
            return "Inspect broad disk usage when reclaimable groups point to space pressure rather than one cleanup category."
        }
    }

    func systemImage(for destination: AlertDestination) -> String {
        switch destination {
        case .deepClean: return "bubbles.and.sparkles"
        case .devPurge: return "hammer"
        case .diskExplorer: return "internaldrive"
        }
    }
}

// MARK: - Roadmap Views

private struct DashboardRoadmapRow: View {
    let step: DashboardRoadmapStep
    let isScanning: Bool
    let onAction: () -> Void

    private var actionIsDisabled: Bool {
        isScanning && step.action == .scan
    }

    private var isPrimary: Bool { step.rank == 1 }

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text("\(step.rank)")
                .font(GargantuaFonts.monoData.weight(.semibold))
                .foregroundStyle(isPrimary ? GargantuaColors.ink : GargantuaColors.ink2)
                .frame(width: 28, height: 28)
                .background(isPrimary ? GargantuaColors.accent : GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            Image(systemName: step.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isPrimary ? GargantuaColors.accent : GargantuaColors.ink2)
                .frame(width: 24, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
                    Text(step.title)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text(step.status.uppercased())
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }

                Text(step.detail)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        ForEach(step.evidence, id: \.self) { evidence in
                            DashboardEvidencePill(text: evidence)
                        }
                    }

                    VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                        ForEach(step.evidence, id: \.self) { evidence in
                            DashboardEvidencePill(text: evidence)
                        }
                    }
                }
            }

            Spacer(minLength: GargantuaSpacing.space4)

            Button(action: onAction) {
                Label(actionIsDisabled ? "Scanning" : step.actionLabel, systemImage: buttonSystemImage)
                    .font(GargantuaFonts.label)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(GargantuaColors.ink)
                    .frame(width: 120)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(step.action == .scan ? Color.clear : GargantuaColors.borderEm, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(actionIsDisabled)
            .opacity(actionIsDisabled ? 0.65 : 1)
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var buttonBackground: Color {
        if step.action == .scan {
            return actionIsDisabled ? GargantuaColors.ink4 : GargantuaColors.accent
        }
        return GargantuaColors.surface3
    }

    private var buttonSystemImage: String {
        if actionIsDisabled { return "hourglass" }
        switch step.action {
        case .scan: return "list.bullet.clipboard"
        case .navigate: return "arrow.right"
        }
    }
}

private struct DashboardTriageEvidenceView: View {
    let alerts: [AlertItem]
    let hasRunTriage: Bool
    let scanProgress: ScanProgress
    let onNavigate: (AlertDestination) -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scanProgress.isScanning {
                progressContent
            } else if alerts.isEmpty {
                emptyContent
            } else {
                ForEach(alerts) { alert in
                    DashboardTriageEvidenceRow(alert: alert) {
                        onNavigate(alert.destination)
                    }

                    if alert.id != alerts.last?.id {
                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                            .padding(.leading, GargantuaSpacing.space4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.surface2)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.accent)
                        .frame(
                            width: geo.size.width * scanProgress.fractionCompleted,
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            HStack(spacing: GargantuaSpacing.space2) {
                Text(scanProgress.currentCategory.map { "Scanning \($0)" } ?? "Scanning local cleanup rules")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                if scanProgress.itemsFound > 0 {
                    Text("\(scanProgress.itemsFound) items found")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .padding(GargantuaSpacing.space4)
    }

    private var emptyContent: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: hasRunTriage ? "checkmark.circle" : "list.bullet.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasRunTriage ? GargantuaColors.safe : GargantuaColors.accent)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(hasRunTriage ? "No triage groups found" : "No triage evidence yet")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(hasRunTriage
                    ? "The lightweight local pass did not find safe or review-tier cleanup groups."
                    : "Run triage to populate evidence and rank the deeper cleanup tools.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            Button(action: onScan) {
                Text(hasRunTriage ? "Refresh Triage" : "Run Triage")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
        }
        .padding(GargantuaSpacing.space4)
    }
}

private struct DashboardTriageEvidenceRow: View {
    let alert: AlertItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(alert.categoryLabel.capitalized)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text("\(alert.detail) routed to \(destinationLabel)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }

                Spacer()

                Text(AlertItem.formatBytes(alert.reclaimableSize))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var destinationLabel: String {
        switch alert.destination {
        case .deepClean: return "Deep Clean"
        case .devPurge: return "Dev Artifact Purge"
        case .diskExplorer: return "Disk Explorer"
        }
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
                        .foregroundStyle(GargantuaColors.ink)
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

private struct DashboardSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text(title)
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    func destinationLabel(_ destination: AlertDestination) -> String {
        switch destination {
        case .deepClean: return "Deep Clean"
        case .devPurge: return "Dev Artifact Purge"
        case .diskExplorer: return "Disk Explorer"
        }
    }

}

private struct DashboardEvidencePill: View {
    let text: String
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? GargantuaFonts.monoData : GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(Capsule().fill(GargantuaColors.surface3))
    }
}
