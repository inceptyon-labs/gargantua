import SwiftUI

/// Disk Explorer with native treemap and sorted list views for disk consumers.
///
/// Mirrors the idle → results phase pattern used by Deep Clean, File Health,
/// Dev Purge, and Duplicate Finder: starts at an idle CTA, transitions to the
/// `ScanResultsHeader`-fronted results view once the user kicks off a scan.
/// Within results, clicking a tile drills down (pushes onto the breadcrumb
/// stack); Refresh re-scans the current directory; Rescan resets to home and
/// re-runs from scratch; Back returns to the idle CTA.
public struct DiskExplorerView: View {
    @Bindable public var state: DiskExplorerState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: DiskExplorerState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            switch state.phase {
            case .idle:
                DiskExplorerIdleView(onStart: startScan)
                    .transition(.opacity)
            case .results:
                resultsView
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state.phase)
        .task(id: state.scanLoadKey) {
            guard state.phase == .results else { return }
            await loadDirectory(state.currentPath)
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScanResultsHeader(
                title: "Disk Explorer",
                subtitle: scanSubtitle,
                onBack: { exitToIdle() },
                onRefresh: { refreshCurrent() },
                onRescan: { rescanFromHome() },
                isBusy: state.isLoading
            )

            controlsBar
            breadcrumbView
            permissionBanner
            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var permissionBanner: some View {
        if state.items.contains(where: { $0.isPermissionDenied }) {
            PermissionBannerView.fullDiskAccess
                .padding(.horizontal, GargantuaSpacing.space6)
                .padding(.bottom, GargantuaSpacing.space3)
        }
    }

    private var scanSubtitle: String? {
        if state.isLoading { return loadingMessage }
        let total = countableItems
        if total > 0 {
            return "\(total) item\(total == 1 ? "" : "s")"
        }
        return nil
    }

    /// Single source of truth for the in-flight scan copy. Used by both the
    /// `ScanResultsHeader` subtitle and the full-screen `scanningView` so the
    /// two cannot drift out of sync. Internal (not private) so the extension
    /// in `DiskExplorerView+Layout` that owns `scanningView` can reach it.
    var loadingMessage: String {
        let total = countableItems
        let pending = state.items.filter { $0.isSizing }.count
        if total == 0 { return "Probing gravitational pull…" }
        if pending == 0 { return "Finishing up…" }
        let done = max(total - pending, 0)
        return "Sizing \(done) of \(total) folders…"
    }

    var countableItems: Int {
        state.items.filter { !$0.isPermissionDenied && !$0.isFilesAggregate }.count
    }

    private var controlsBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            if state.isLoading {
                AccretionDiskView(activityRate: 14, size: 18, color: GargantuaColors.accent)
                    .accessibilityHidden(true)
            }
            Spacer()
            // Bridged binding: writes go through `setDisplayMode` so the
            // explicit-pick flag flips, suppressing future auto-promotions
            // for this directory. Auto-promote (state-driven) writes
            // `displayMode` directly without the flag.
            DisplayModeToggle(selection: Binding(
                get: { state.displayMode },
                set: { state.setDisplayMode($0) }
            ))
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space3)
        .padding(.bottom, GargantuaSpacing.space2)
    }

    // MARK: - Breadcrumb

    private var breadcrumbView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GargantuaSpacing.space1) {
                ForEach(Array(state.pathStack.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(GargantuaColors.ink4)
                    }

                    Button {
                        navigateTo(index: index)
                    } label: {
                        Text(crumb.name)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(
                                index == state.pathStack.count - 1
                                    ? GargantuaColors.ink
                                    : GargantuaColors.accent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(index == state.pathStack.count - 1)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space3)
        }
    }

    // MARK: - Content

    private var contentView: some View {
        ZStack {
            switch contentMode {
            case .scanning:
                scanningView
                    .transition(.opacity)
            case .empty:
                emptyState
                    .transition(.opacity)
            case .dominant(let dominant):
                dominantChildView(dominant: dominant)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .focusUnavailable:
                DiskExplorerFocusUnavailableView(
                    onPickTreemap: { state.setDisplayMode(.treemap) },
                    onPickList: { state.setDisplayMode(.list) }
                )
                .transition(.opacity)
            case .treemap:
                treemapView
                    .transition(.opacity)
            case .list:
                listView
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: contentMode)
    }

    /// Coalesces the various render branches into one Equatable value so
    /// `.animation(_:value:)` can drive cross-fades between them.
    ///
    /// While `isLoading` is true we deliberately do NOT render a partial
    /// treemap. Watching tiles bounce around as sizes resolve and the
    /// squarify layout re-runs is jarring, and worse, on a folder destined
    /// for the dominant-child fallback the user sees the full ant-farm
    /// before the card resolves. Show a clean scanning view instead and
    /// cross-fade into the result once it's stable.
    ///
    /// `.treemap` no longer auto-substitutes the dominant card — that
    /// substitution now happens at the state level via `applyAutoPromoteIfNeeded`,
    /// which flips `displayMode` to `.focus` so the toggle reflects what's
    /// actually on screen. Picking `.treemap` explicitly always renders the
    /// squarified treemap, even on degenerate distributions.
    private var contentMode: DiskExplorerContentMode {
        if state.isLoading { return .scanning }
        if state.items.isEmpty { return .empty }
        switch state.displayMode {
        case .focus:
            if let dominant = state.dominantChild { return .dominant(dominant) }
            return .focusUnavailable
        case .list:
            return .list
        case .treemap:
            return .treemap
        }
    }

    private var displayItems: [DirectoryItem] {
        DiskExplorerView.collapseSmall(state.items)
    }

    private var treemapView: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - GargantuaSpacing.space6 * 2, 1)
            let height = max(geometry.size.height - GargantuaSpacing.space6, 1)
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let displayed = displayItems
            let totalSize = displayed.reduce(0) { $0 + max($1.size, 0) }
            let tiles = DiskTreemapLayout.tiles(for: displayed, in: bounds)

            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    DirectoryTreemapCellView(
                        item: tile.item,
                        totalSiblingSize: totalSize,
                        onDrillDown: { drillDown(into: tile.item) }
                    )
                    .frame(width: max(tile.rect.width, 1), height: max(tile.rect.height, 1))
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space6)
        }
        .frame(minHeight: 320)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(state.items) { item in
                    DirectoryRowView(
                        item: item,
                        maxSize: state.maxSize,
                        isExpanded: state.expandedItems[item.path] != nil,
                        onExpand: { await toggleExpand(item) },
                        onDrillDown: { drillDown(into: item) }
                    )

                    if let children = state.expandedItems[item.path] {
                        ForEach(children) { child in
                            DirectoryRowView(
                                item: child,
                                maxSize: state.maxSize,
                                isExpanded: false,
                                onExpand: nil,
                                onDrillDown: { drillDown(into: child) },
                                indentLevel: 1
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space6)
        }
    }

    private func dominantChildView(dominant: DirectoryItem) -> some View {
        DiskExplorerDominantChildView(
            dominant: dominant,
            items: state.items,
            maxSize: state.maxSize,
            onDrillDown: { drillDown(into: $0) }
        )
    }

    // MARK: - Actions

    private func startScan() { state.startScan() }
    private func refreshCurrent() { state.refreshCurrent() }
    private func rescanFromHome() { state.rescanFromHome() }
    private func exitToIdle() { state.exitToIdle() }
    private func drillDown(into item: DirectoryItem) { state.drillDown(into: item) }
    private func navigateTo(index: Int) { state.navigateTo(index: index) }

    private func loadDirectory(_ path: String) async {
        // The matching navigation handler (or scanGeneration bump) already set
        // up state synchronously: `applyCachedItemsIfPresent` will have either
        // populated `items` from cache and cleared `isLoading`, or cleared
        // `items` and set `isLoading = true`. So if we got here without
        // `isLoading`, there's nothing to scan.
        guard state.isLoading else { return }

        for await item in DirectorySizeScanner.streamChildren(of: path) {
            if Task.isCancelled { return }
            state.upsert(item)
        }

        if !Task.isCancelled {
            state.completeLoad(for: path)
        }
    }

    private func toggleExpand(_ item: DirectoryItem) async {
        if state.expandedItems[item.path] != nil {
            state.expandedItems.removeValue(forKey: item.path)
        } else {
            let children = await DirectorySizeScanner.scanChildren(of: item.path)
            state.expandedItems[item.path] = children
        }
    }
}
