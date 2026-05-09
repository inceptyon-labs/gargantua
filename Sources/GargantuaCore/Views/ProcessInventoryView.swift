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
    private let onNavigateToBackgroundItems: ((_ plistPath: String) -> Void)?

    /// Default top-N cap. Snapshot views shouldn't fight Activity Monitor for
    /// completeness — surfacing the top 50 keeps cognitive load low and lets
    /// the user re-rank by toggling the metric.
    public static let defaultTopN: Int = 50

    public init(
        onExplain: ((ScanResult) -> Void)? = nil,
        onNavigateToBackgroundItems: ((_ plistPath: String) -> Void)? = nil,
        actionExecutor: (any ProcessActionExecuting)? = nil
    ) {
        self.onExplain = onExplain
        self.onNavigateToBackgroundItems = onNavigateToBackgroundItems
        self._session = State(
            initialValue: ProcessInventorySession(actionExecutor: actionExecutor ?? DefaultProcessActionExecutor())
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Processes",
                subtitle: subtitleText,
                subtitleStyle: .voice,
                onRescan: { Task { await session.scan(metric: sortMetric, topN: Self.defaultTopN) } },
                isBusy: session.isScanning
            )

            if session.scan == nil, !session.isScanning {
                idleState
            } else if session.isScanning {
                scanningState
            } else if let scan = session.scan {
                resultsState(scan)
            }
        }
        .background(GargantuaColors.void_)
        .task {
            if session.scan == nil {
                await session.scan(metric: sortMetric, topN: Self.defaultTopN)
            }
        }
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

    private var idleState: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundStyle(GargantuaColors.ink3)
            Text("Snapshot running processes")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text("Read-only. Two samples 500 ms apart for CPU.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Button {
                Task { await session.scan(metric: sortMetric, topN: Self.defaultTopN) }
            } label: {
                Text("Take Snapshot")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .padding(.top, GargantuaSpacing.space2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Filter first, then apply the top-N cap. The scanner returns the full
    /// ranked population so the UI can re-rank between CPU and Memory
    /// without losing items that fall outside one ranking but would have
    /// been near the top of the other.
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
        HStack(spacing: GargantuaSpacing.space3) {
            sortToggle
            Divider()
                .frame(height: 14)
                .overlay(GargantuaColors.border)
            ForEach(ProcessSafetyFilter.allCases, id: \.self) { option in
                filterButton(option, scan: scan)
            }
            Spacer()
            Text("\(visibleCount) shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    private var sortToggle: some View {
        HStack(spacing: 4) {
            Text("Sort:")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
            ForEach(ProcessSortMetric.allCases, id: \.self) { metric in
                Button {
                    // Re-sort the existing snapshot in place rather than
                    // re-running a 500 ms scan — toggling between CPU and
                    // Memory should feel instant.
                    sortMetric = metric
                    session.resort(by: metric)
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
