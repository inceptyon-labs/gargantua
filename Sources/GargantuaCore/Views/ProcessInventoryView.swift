import AppKit
import SwiftUI

// swiftlint:disable file_length

// Top-level view for the Process Inventory pane.
//
// Stop and Remove Source mutations route through `ProcessInventorySession` →
// `ProcessActionExecutor`. Remove Source is a navigation handoff to the
// Background Items pane (which owns the disable/delete pipeline).
// swiftlint:disable:next type_body_length
public struct ProcessInventoryView: View {
    @State private var session: ProcessInventorySession
    @State private var expandedID: String?
    @State private var sortMetric: ProcessSortMetric = .cpu
    @State private var safetyFilter: ProcessSafetyFilter = .all
    @State private var pendingAction: PendingProcessAction?
    @State private var lastError: String?
    private let onExplain: ((ScanResult) -> Void)?
    private let onTriage: (([ScanResult]) -> Void)?
    private let onNavigateToBackgroundItems: ((_ plistPath: String) -> Void)?

    /// Default top-N cap. Snapshot views shouldn't fight Activity Monitor for
    /// completeness — surfacing the top 50 keeps cognitive load low and lets
    /// the user re-rank by toggling the metric.
    public static let defaultTopN: Int = 50

    public init(
        session: ProcessInventorySession? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onTriage: (([ScanResult]) -> Void)? = nil,
        onNavigateToBackgroundItems: ((_ plistPath: String) -> Void)? = nil,
        actionExecutor: (any ProcessActionExecuting)? = nil
    ) {
        self.onExplain = onExplain
        self.onTriage = onTriage
        self.onNavigateToBackgroundItems = onNavigateToBackgroundItems
        self._session = State(
            initialValue: session ?? ProcessInventorySession(
                actionExecutor: actionExecutor ?? DefaultProcessActionExecutor()
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.scan == nil, !session.isScanning {
                startView
            } else {
                ScanResultsHeader(
                    title: "Processes",
                    subtitle: subtitleText,
                    subtitleStyle: .voice,
                    onBack: { clearSnapshot() },
                    onRescan: { startSnapshot() },
                    isBusy: session.isScanning
                )

                if session.isScanning {
                    scanningState
                } else if let scan = session.scan {
                    resultsState(scan)
                }
            }
        }
        .background(GargantuaColors.void_)
        .onChange(of: session.scan?.scannedAt) { _, _ in
            // Drop stale expansion state — a row that's no longer in the
            // visible list shouldn't keep its expanded marker.
            if let expandedID, !(session.scan?.items.contains(where: { $0.id == expandedID }) ?? false) {
                self.expandedID = nil
            }
        }
        .sheet(item: $pendingAction) { pending in
            ProcessActionConfirmation(
                item: pending.item,
                action: pending.action,
                onConfirm: {
                    let toRun = pending
                    pendingAction = nil
                    Task { await runAction(toRun) }
                },
                onCancel: { pendingAction = nil }
            )
        }
        .alert(
            "Process action failed",
            isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { lastError = nil }
        } message: {
            Text(lastError ?? "")
        }
    }

    private func processPreviewMetric(icon: String, label: String, value: String) -> some View {
        VStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.ink3)
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink4)
        }
    }

    // MARK: - States

    private var subtitleText: String {
        if let scan = session.scan {
            let shown = scan.items.count
            let total = scan.totalProcessCount
            if shown < total {
                return "Top \(shown) of \(total) running · ranked by \(scan.sortedBy.displayLabel)"
            }
            return "\(total) running · ranked by \(scan.sortedBy.displayLabel)"
        }
        if session.isScanning { return "Sampling running processes…" }
        return "Snapshot every running process. Decide what stays."
    }

    private var startView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Processes",
                subtitle: "Snapshot running work before deciding what stays.",
                subtitleStyle: .voice
            )

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: GargantuaSpacing.space3) {
                        Spacer(minLength: 0)

                        GargantuaBrandIcon(
                            resourceName: "process-inventory-gargantua-gpt2",
                            fallbackSystemName: "cpu",
                            fallbackColor: GargantuaColors.ink4
                        )

                        Text("Snapshot running processes")
                            .font(GargantuaFonts.heading)
                            .foregroundStyle(GargantuaColors.ink)

                        Text("Takes two samples 500 ms apart. Stop actions require confirmation after the snapshot.")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)

                        HStack(spacing: GargantuaSpacing.space5) {
                            processPreviewMetric(icon: "cpu", label: "CPU", value: "Usage")
                            processPreviewMetric(icon: "memorychip", label: "Memory", value: "Resident")
                            processPreviewMetric(icon: "signature", label: "Identity", value: "Signatures")
                        }
                        .padding(.vertical, GargantuaSpacing.space2)

                        GargantuaButton("Take Snapshot", tone: .primary, action: startSnapshot)
                            .padding(.top, GargantuaSpacing.space2)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            AccretionDiskView(activityRate: 18, size: 36, color: GargantuaColors.accretion)
            Text("Reading libproc, parent PIDs, signatures…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Filter the captured snapshot. The scanner already applies the top-N
    /// cap before expensive identity/signature resolution, but this keeps the
    /// view correct if a custom scanner returns an uncapped list.
    private func visibleItems(_ scan: ProcessInventoryScan) -> [ProcessItem] {
        let filtered = safetyFilter.apply(scan.items)
        if let topN = scan.topN, topN > 0 {
            return Array(filtered.prefix(topN))
        }
        return filtered
    }

    @ViewBuilder
    private func resultsState(_ scan: ProcessInventoryScan) -> some View {
        let visible = visibleItems(scan)

        VStack(spacing: 0) {
            controlBar(scan: scan, visibleCount: visible.count)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: GargantuaSpacing.space2) {
                        ForEach(visible) { item in
                            ProcessInventoryRow(
                                item: item,
                                isExpanded: expandedID == item.id,
                                isBusy: session.busyItemIDs.contains(item.id),
                                onToggleExpand: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        expandedID = expandedID == item.id ? nil : item.id
                                    }
                                },
                                onRevealBinary: { revealBinary(item) },
                                onRevealPlist: { revealPlist(item) },
                                onExplain: onExplain != nil ? { explain(item) } : nil,
                                onAction: { action in
                                    pendingAction = PendingProcessAction(item: item, action: action)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space3)
                }
            }

            footer(scan: scan)
        }
    }

    private func controlBar(scan: ProcessInventoryScan, visibleCount: Int) -> some View {
        let triageResults = suspiciousTriageResults(scan)
        return HStack(spacing: GargantuaSpacing.space3) {
            sortToggle
            Divider()
                .frame(height: 14)
                .overlay(GargantuaColors.border)
            ForEach(ProcessSafetyFilter.allCases, id: \.self) { option in
                filterButton(option, scan: scan)
            }
            Spacer()
            if let onTriage, !triageResults.isEmpty {
                aiTriageButton {
                    onTriage(triageResults)
                }
            }
            Text("\(visibleCount) shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private func aiTriageButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .medium))
                Text("Suspicious Triage")
                    .font(GargantuaFonts.caption)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .help("Analyze the top suspicious process candidates with the active AI engine")
    }

    private func suspiciousTriageResults(_ scan: ProcessInventoryScan) -> [ScanResult] {
        scan.items.compactMap { item -> (score: Int, result: ScanResult)? in
            let triage = processTriageSignals(for: item)
            guard triage.score >= 40 else { return nil }
            return (triage.score, processTriageResult(for: item, signals: triage.signals))
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.result.name.localizedCaseInsensitiveCompare(rhs.result.name) == .orderedAscending
        }
        .prefix(6)
        .map(\.result)
    }

    private func processTriageSignals(for item: ProcessItem) -> (score: Int, signals: [String]) {
        guard item.safety != .protected_ else { return (0, []) }
        let contributions = Self.triageReasonContributions(for: item)
            + Self.triageLaunchContributions(for: item)
            + Self.triagePathContributions(for: item)
            + Self.triageUsageContributions(for: item)
        return (contributions.reduce(0) { $0 + $1.points }, contributions.map(\.signal))
    }

    private static func triageReasonContributions(for item: ProcessItem) -> [(points: Int, signal: String)] {
        var out: [(Int, String)] = []
        if item.reasons.contains(.unsigned) { out.append((90, "unsigned binary")) }
        if item.reasons.contains(.orphaned) { out.append((80, "orphaned launch source")) }
        if item.reasons.contains(.rootProcess) { out.append((55, "runs as root")) }
        return out
    }

    private static func triageLaunchContributions(for item: ProcessItem) -> [(points: Int, signal: String)] {
        var out: [(Int, String)] = []
        switch item.launchSource {
        case .unknown: out.append((45, "unknown launch source"))
        case .childProcess: out.append((20, "child process"))
        case .userSession: out.append((15, "user-session process"))
        case .foregroundApp, .launchd: break
        }
        switch item.launchConfidence {
        case .heuristic: out.append((35, "weak launchd match"))
        case .unknown: out.append((25, "unmatched launch source"))
        case .exact, .path: break
        }
        return out
    }

    private static func triagePathContributions(for item: ProcessItem) -> [(points: Int, signal: String)] {
        guard let path = item.executablePath else { return [] }
        var out: [(Int, String)] = []
        let lower = path.lowercased()
        if lower.hasPrefix("/tmp/") || lower.hasPrefix("/private/tmp/") || lower.contains("/var/folders/") {
            out.append((35, "temporary-path executable"))
        }
        if lower.contains("/downloads/") {
            out.append((20, "runs from downloads"))
        }
        return out
    }

    private static func triageUsageContributions(for item: ProcessItem) -> [(points: Int, signal: String)] {
        var out: [(Int, String)] = []
        if item.cpuFraction >= 0.4 { out.append((12, "high CPU")) }
        if item.residentBytes >= 512 * 1_024 * 1_024 { out.append((8, "high memory")) }
        return out
    }

    private func processTriageResult(for item: ProcessItem, signals: [String]) -> ScanResult {
        let base = item.toScanResult()
        let readableSignals = signals.joined(separator: ", ")
        return ScanResult(
            id: "triage:\(base.id)",
            name: base.name,
            path: base.path,
            size: base.size,
            safety: base.safety,
            confidence: base.confidence,
            explanation: "Triage signals: \(readableSignals). \(base.explanation)",
            source: base.source,
            lastAccessed: base.lastAccessed,
            category: "process_triage",
            tags: base.tags + signals.map { "triage_signal:\($0.replacingOccurrences(of: " ", with: "_"))" },
            regenerates: base.regenerates,
            regenerateCommand: base.regenerateCommand
        )
    }

    private var sortToggle: some View {
        HStack(spacing: 4) {
            Text("Sort:")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
            ForEach(ProcessSortMetric.allCases, id: \.self) { metric in
                Button {
                    guard sortMetric != metric else { return }
                    sortMetric = metric
                    startSnapshot()
                } label: {
                    Text(metric.displayLabel)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(sortMetric == metric ? GargantuaColors.ink : GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space2)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(sortMetric == metric ? GargantuaColors.surface2 : .clear)
                        }
                }
                .buttonStyle(.plain)
                .disabled(session.isScanning)
            }
        }
    }

    private func filterButton(_ option: ProcessSafetyFilter, scan: ProcessInventoryScan) -> some View {
        let count = option.apply(scan.items).count
        let isActive = safetyFilter == option
        return Button {
            safetyFilter = option
        } label: {
            HStack(spacing: 4) {
                Text(option.displayLabel)
                    .font(GargantuaFonts.caption)
                Text("\(count)")
                    .font(GargantuaFonts.caption.monospacedDigit())
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .foregroundStyle(isActive ? GargantuaColors.ink : GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isActive ? GargantuaColors.surface2 : .clear)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink3)
            Text("No processes match the current filter.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(scan: ProcessInventoryScan) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
            HStack(spacing: GargantuaSpacing.space2) {
                Text("Stop and Remove Source actions are recorded to the audit log.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                Spacer()
                Text("Last sampled " + Self.timestampFormatter.localizedString(for: scan.scannedAt, relativeTo: Date()))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
        }
    }

    // MARK: - Actions

    private func revealBinary(_ item: ProcessItem) {
        guard let exe = item.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)])
    }

    private func revealPlist(_ item: ProcessItem) {
        guard let plist = item.launchSource.plistPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)])
    }

    private func explain(_ item: ProcessItem) {
        guard let onExplain else { return }
        onExplain(item.toScanResult())
    }

    private func startSnapshot() {
        Task { await session.scan(metric: sortMetric, topN: Self.defaultTopN) }
    }

    private func clearSnapshot() {
        expandedID = nil
        session.clearSnapshot()
    }

    private func runAction(_ pending: PendingProcessAction) async {
        let outcome = await session.perform(
            pending.action,
            on: pending.item,
            metric: sortMetric,
            topN: Self.defaultTopN
        )
        if outcome.succeeded {
            // Successful `.removeSource` carries the plist path the receiver
            // pane should pre-select; navigation happens after the sheet has
            // already dismissed so the destination view animates in cleanly.
            if let path = outcome.routedPlistPath {
                if let onNavigateToBackgroundItems {
                    onNavigateToBackgroundItems(path)
                } else {
                    // No nav handler wired — surface a clear message so the
                    // user isn't left wondering why the sheet just dismissed.
                    lastError = "Background Items navigation is not configured. Open the Background Items pane manually to act on this source."
                }
            }
            return
        }
        if let error = outcome.error {
            lastError = error
        }
    }

    private static let timestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Identifies a pending action awaiting user confirmation. Stored on the view
/// rather than the session so dismissing the sheet doesn't have to round-trip
/// through `@Observable`.
public struct PendingProcessAction: Identifiable, Equatable {
    public let item: ProcessItem
    public let action: ProcessAction
    public var id: String { "\(item.id)|\(action.rawValue)" }

    public init(item: ProcessItem, action: ProcessAction) {
        self.item = item
        self.action = action
    }
}

// MARK: - Filter

public enum ProcessSafetyFilter: CaseIterable, Equatable {
    case all
    case review
    case safe
    case protected_
    case sensitive
    case orphaned

    var displayLabel: String {
        switch self {
        case .all: "All"
        case .review: "Review"
        case .safe: "Safe"
        case .protected_: "Protected"
        case .sensitive: "Sensitive"
        case .orphaned: "Orphaned"
        }
    }

    func apply(_ items: [ProcessItem]) -> [ProcessItem] {
        switch self {
        case .all: items
        case .review: items.filter { $0.safety == .review }
        case .safe: items.filter { $0.safety == .safe }
        case .protected_: items.filter { $0.safety == .protected_ }
        case .sensitive: items.filter { $0.reasons.contains(.sensitiveVendor) }
        case .orphaned: items.filter { $0.reasons.contains(.orphaned) }
        }
    }
}
