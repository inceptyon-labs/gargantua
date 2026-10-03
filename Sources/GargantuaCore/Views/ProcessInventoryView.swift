import AppKit
import SwiftUI

// Top-level view for the Process Inventory pane.
//
// Stop and Remove Source mutations route through `ProcessInventorySession` →
// `ProcessActionExecutor`. Remove Source is a navigation handoff to the
// Background Items pane (which owns the disable/delete pipeline).
//
// Helpers are split across peer files (`ProcessInventoryView+Controls`,
// `+Triage`, `+Actions`, `+Types`); stored properties are internal rather than
// private so those cross-file extensions can reach them.
public struct ProcessInventoryView: View {
    @State var session: ProcessInventorySession
    @State var expandedID: String?
    @State var safetyFilter: ProcessSafetyFilter = .all
    @State var searchQuery: String = ""
    @FocusState var isSearchFocused: Bool
    @State var pendingAction: PendingProcessAction?
    @State var lastError: String?
    let onExplain: ((ScanResult) -> Void)?
    let onTriage: (([ScanResult]) -> Void)?
    let onNavigateToBackgroundItems: ((_ plistPath: String) -> Void)?

    var sortMetric: ProcessSortMetric {
        get { session.sortMetric }
        nonmutating set { session.sortMetric = newValue }
    }

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

                if session.isScanning, !session.isRefreshingInPlace {
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

    func processPreviewMetric(icon: String, label: String, value: String) -> some View {
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

    var subtitleText: String {
        if isSearchActive { return searchSubtitle }
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

    private var searchSubtitle: String {
        if session.isSearching, session.searchResults == nil { return "Searching all processes…" }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = session.searchResults?.items.count ?? 0
        if count >= ProcessInventorySession.searchResultLimit {
            return "First \(count) matches for “\(query)”"
        }
        let noun = count == 1 ? "match" : "matches"
        return "\(count) \(noun) for “\(query)”"
    }

    var startView: some View {
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

    var scanningState: some View {
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
    func visibleItems(_ scan: ProcessInventoryScan) -> [ProcessItem] {
        let filtered = safetyFilter.apply(scan.items)
        if let topN = scan.topN, topN > 0 {
            return Array(filtered.prefix(topN))
        }
        return filtered
    }

    @ViewBuilder
    func resultsState(_ scan: ProcessInventoryScan) -> some View {
        // Search results replace the snapshot list while a query is active;
        // clearing the query restores the snapshot with no re-sample.
        let activeScan = isSearchActive ? (session.searchResults ?? scan) : scan
        let visible = visibleItems(activeScan)
        // PID → row id for the displayed rows, so a child can deep-link to its
        // parent's row when the parent is on screen.
        let parentIDsByPID = parentRowIDsByPID(visible)

        VStack(spacing: 0) {
            searchBar
            controlBar(scan: activeScan, visibleCount: visible.count)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
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
                                    },
                                    onJumpToParent: jumpToParentAction(
                                        for: item,
                                        parentIDsByPID: parentIDsByPID,
                                        proxy: proxy
                                    )
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space3)
                    }
                }
            }

            footer(scan: activeScan)
        }
        // Debounced full-table search: re-runs whenever the query OR sort
        // metric changes (so results re-rank on a metric toggle), auto-
        // cancelling the prior pass so only the latest request lands.
        .task(id: "\(sortMetric.rawValue)\u{1}\(searchQuery)") {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                session.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await session.search(query: query, metric: sortMetric)
        }
    }

    /// Whether a non-blank search query is active.
    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Index the displayed rows by PID so a child can resolve its parent's row.
    func parentRowIDsByPID(_ items: [ProcessItem]) -> [Int32: String] {
        var map: [Int32: String] = [:]
        map.reserveCapacity(items.count)
        for item in items { map[item.pid] = item.id }
        return map
    }

    /// Closure that scrolls to + expands the parent's row, or `nil` when the
    /// parent isn't in the displayed list (so the row shows plain parent text).
    func jumpToParentAction(
        for item: ProcessItem,
        parentIDsByPID: [Int32: String],
        proxy: ScrollViewProxy
    ) -> (() -> Void)? {
        guard let parentID = parentIDsByPID[item.parentPID], parentID != item.id else {
            return nil
        }
        return {
            withAnimation(.easeOut(duration: 0.2)) {
                expandedID = parentID
                proxy.scrollTo(parentID, anchor: .center)
            }
        }
    }
}
