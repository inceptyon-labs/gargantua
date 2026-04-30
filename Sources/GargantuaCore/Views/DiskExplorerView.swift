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
            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scanSubtitle: String? {
        let total = state.items.filter { !$0.isPermissionDenied && !$0.isFilesAggregate }.count
        let pending = state.items.filter { $0.isSizing }.count
        let done = max(total - pending, 0)
        if state.isLoading {
            if total == 0 { return "Probing gravitational pull…" }
            if pending == 0 { return "Finishing up…" }
            return "Sizing \(done) of \(total) folders…"
        }
        if total > 0 {
            return "\(total) item\(total == 1 ? "" : "s")"
        }
        return nil
    }

    private var controlsBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            if state.isLoading {
                AccretionDiskView(activityRate: 14, size: 18, color: GargantuaColors.accent)
                    .accessibilityHidden(true)
            }
            Spacer()
            DisplayModeToggle(selection: $state.displayMode)
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
    /// `.animation(_:value:)` can drive cross-fades between them. Without
    /// this, swapping treemap → dominant card on `isLoading` flipping false
    /// is an abrupt view-tree replacement with no transition window.
    ///
    /// While `isLoading` is true we deliberately do NOT render a partial
    /// treemap. Watching tiles bounce around as sizes resolve and the
    /// squarify layout re-runs is jarring, and worse, on a folder destined
    /// for the dominant-child fallback the user sees the full ant-farm
    /// before the card resolves. Show a clean scanning view instead and
    /// cross-fade into the result once it's stable.
    private var contentMode: DiskExplorerContentMode {
        if state.isLoading { return .scanning }
        if state.items.isEmpty { return .empty }
        if state.displayMode == .treemap, let dominant = dominantChild {
            return .dominant(dominant)
        }
        return state.displayMode == .list ? .list : .treemap
    }

    private var displayItems: [DirectoryItem] {
        DiskExplorerView.collapseSmall(state.items)
    }

    /// If the largest child dwarfs everything else, the treemap degenerates
    /// into one giant tile next to a thin strip of unreadable slivers. Detect
    /// that case so we can render a more useful layout.
    ///
    /// Only computed once the scan completes — otherwise the answer flickers
    /// as sizes resolve in arbitrary order: the first small folder to finish
    /// sizing would briefly be "dominant" against zero, get swept aside as
    /// the real heavyweight resolves, and then potentially flip again as
    /// medium peers join the picture.
    ///
    /// The heuristic looks at the ratio between the largest and second-largest
    /// child rather than the largest's share of the total — that's what
    /// actually determines whether the treemap will produce visible non-largest
    /// tiles or just slivers crammed against the edge.
    private var dominantChild: DirectoryItem? {
        guard !state.isLoading else { return nil }
        let sized = state.items
            .filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
            .sorted { $0.size > $1.size }
        guard let largest = sized.first else { return nil }
        guard sized.count > 1 else { return largest }
        let second = sized[1]
        // Second-largest below ~15% of largest means it'd render as a sliver.
        if Double(second.size) / Double(largest.size) < 0.15 {
            return largest
        }
        return nil
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

    private var scanningView: some View {
        let total = state.items.filter { !$0.isPermissionDenied && !$0.isFilesAggregate }.count
        let pending = state.items.filter { $0.isSizing }.count
        let done = max(total - pending, 0)
        let primary: String = {
            if total == 0 { return "Probing gravitational pull…" }
            if pending == 0 { return "Finishing up…" }
            return "Sizing \(done) of \(total) folders…"
        }()
        let folderName = state.pathStack.last?.name ?? "Home"
        return VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Mapping \(folderName)")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(primary)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, GargantuaSpacing.space6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning \(folderName), \(primary)")
    }

    private var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: 0, size: 28, color: GargantuaColors.ink3)
                .opacity(0.4)

            Text("Empty orbit")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("No bodies detected at this radius.")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, GargantuaSpacing.space6)
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
