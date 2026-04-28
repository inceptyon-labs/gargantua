import SwiftUI

// File contains the Disk Explorer view plus its three private sub-views
// (DisplayModeToggle, DirectoryTreemapCellView, DirectoryRowView). They're
// kept in one file because they're tightly coupled to the explorer's layout
// model and this file is under active iteration; splitting now would churn
// alongside in-flight UI fixes. Revisit once treemap layout stabilizes.
// swiftlint:disable file_length

/// Disk Explorer with native treemap and sorted list views for disk consumers.
///
/// Mirrors the idle → results phase pattern used by Deep Clean, File Health,
/// Dev Purge, and Duplicate Finder: starts at an idle CTA, transitions to the
/// `ScanResultsHeader`-fronted results view once the user kicks off a scan.
/// Within results, clicking a tile drills down (pushes onto the breadcrumb
/// stack); Refresh re-scans the current directory; Rescan resets to home and
/// re-runs from scratch; Back returns to the idle CTA.
// Type body covers idle CTA, results header chrome, treemap layout entry, and
// list mode in one struct — splitting risks tearing the active scan-state
// wiring while UI iterations are landing.
// swiftlint:disable:next type_body_length
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
                idleView
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

    // MARK: - Idle CTA

    private var idleView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disk Explorer")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 36))
                    .foregroundStyle(GargantuaColors.ink3)

                Text("Disk Map")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Visualize what's eating your home directory. Click any folder to drill in.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button(action: startScan) {
                    Text("Start Disk Scan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)
            }

            Spacer()
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

    /// Alternate layout for folders where one child is so large the treemap
    /// would just show a giant rectangle with sliver-thin neighbors. Renders
    /// the dominant child as a hero card with a Drill In affordance and the
    /// remaining children as a compact size-bar list below.
    private func dominantChildView(dominant: DirectoryItem) -> some View {
        let total = state.items.reduce(0) { $0 + max($1.size, 0) }
        let fraction = total > 0 ? Double(dominant.size) / Double(total) : 0
        let percent = Int((fraction * 100).rounded())
        let remaining = state.items.filter { $0.id != dominant.id }
        let canDrillIn = !dominant.isPermissionDenied
            && !dominant.isFilesAggregate
            && !dominant.isSizing

        return VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "scope")
                    .font(.system(size: 14))
                    .foregroundStyle(GargantuaColors.review)
                Text("One folder dominates this directory")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
            }

            Button {
                if canDrillIn { drillDown(into: dominant) }
            } label: {
                HStack(spacing: GargantuaSpacing.space4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(GargantuaColors.accent)

                    VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                        Text(dominant.name)
                            .font(GargantuaFonts.heading)
                            .foregroundStyle(GargantuaColors.ink)
                            .lineLimit(2)
                        HStack(spacing: GargantuaSpacing.space2) {
                            Text(AlertItem.formatBytes(dominant.size))
                                .font(GargantuaFonts.monoData)
                                .foregroundStyle(GargantuaColors.ink2)
                            Text("•")
                                .foregroundStyle(GargantuaColors.ink4)
                            Text("\(percent)% of folder")
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink2)
                        }
                    }

                    Spacer()

                    if canDrillIn {
                        HStack(spacing: GargantuaSpacing.space1) {
                            Text("Drill in")
                                .font(GargantuaFonts.label)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(GargantuaColors.accent)
                    }
                }
                .padding(GargantuaSpacing.space4)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                        .strokeBorder(GargantuaColors.accent.opacity(0.5), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canDrillIn)

            if !remaining.isEmpty {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                    Text("Other items")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .textCase(.uppercase)

                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(remaining) { item in
                                DirectoryRowView(
                                    item: item,
                                    maxSize: state.maxSize,
                                    isExpanded: false,
                                    onExpand: nil,
                                    onDrillDown: { drillDown(into: item) }
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space6)
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

    /// Bundle directories whose size is < 1% of the largest into a single
    /// synthetic "Others" tile. Avoids the ant-farm of unidentifiable
    /// 60×60-pixel icons that plague treemaps of skewed distributions.
    static func collapseSmall(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let sized = items.filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
        guard let largest = sized.map(\.size).max(), largest > 0 else { return items }

        let threshold = max(largest / 100, 1)
        var kept: [DirectoryItem] = []
        var aggregated: [DirectoryItem] = []

        for item in items {
            if item.isPermissionDenied || item.isSizing || item.isFilesAggregate {
                kept.append(item)
                continue
            }
            if item.size < threshold {
                aggregated.append(item)
            } else {
                kept.append(item)
            }
        }

        // Only collapse when it's worth it — a single small item gets a normal
        // tile rather than a misleading "Others (1)" wrapper.
        guard aggregated.count >= 2 else { return items }

        let totalSize = aggregated.reduce(0) { $0 + $1.size }
        let aggregateName = "Others (\(aggregated.count))"
        let parentPath = aggregated.first?.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/") ?? ""
        let aggregatePath = "/\(parentPath)#others"
        kept.append(DirectoryItem(
            name: aggregateName,
            path: aggregatePath,
            size: totalSize,
            isOthersAggregate: true
        ))
        return kept
    }
}

private enum DiskExplorerContentMode: Equatable {
    case scanning
    case empty
    case treemap
    case list
    case dominant(DirectoryItem)

    static func == (lhs: DiskExplorerContentMode, rhs: DiskExplorerContentMode) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning),
             (.empty, .empty),
             (.treemap, .treemap),
             (.list, .list):
            return true
        case let (.dominant(l), .dominant(r)):
            return l.id == r.id
        default:
            return false
        }
    }
}

// MARK: - Display Mode Toggle

/// Two-button toggle for treemap / list view, hand-rolled so it stays legible
/// against the dark `void_` background. The native segmented `Picker` renders
/// the unselected segment as dark-on-dark in this theme and is effectively
/// invisible, so we draw both segments explicitly with theme colors.
private struct DisplayModeToggle: View {
    @Binding var selection: DiskExplorerDisplayMode

    var body: some View {
        HStack(spacing: 0) {
            segment(
                mode: .treemap,
                label: "Treemap",
                systemImage: "square.grid.2x2"
            )
            segment(
                mode: .list,
                label: "List",
                systemImage: "list.bullet"
            )
        }
        .background(GargantuaColors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .strokeBorder(GargantuaColors.border, lineWidth: 1)
        )
    }

    private func segment(mode: DiskExplorerDisplayMode, label: String, systemImage: String) -> some View {
        let isSelected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(isSelected ? Color.white : GargantuaColors.ink)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .frame(minWidth: 92)
            .background(isSelected ? GargantuaColors.accent : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Treemap Cell

private struct DirectoryTreemapCellView: View {
    let item: DirectoryItem
    let totalSiblingSize: Int64
    let onDrillDown: () -> Void

    @State private var isHovered = false
    @State private var sizingPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canDrillDown: Bool {
        !item.isPermissionDenied
            && !item.isFilesAggregate
            && !item.isOthersAggregate
            && !item.isSizing
    }

    var body: some View {
        Group {
            if canDrillDown {
                Button {
                    onDrillDown()
                } label: {
                    cellBody
                }
                .buttonStyle(.plain)
            } else {
                cellBody
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private enum LayoutTier {
        /// Roughly < 88×58 — only space for an icon.
        case tiny
        /// Roughly 88–240 wide or 58–160 tall — top-left icon + name + size.
        case compact
        /// ≥ 240×160 — centered icon + heading-sized name + large size + share.
        case spacious
    }

    private func tier(for size: CGSize) -> LayoutTier {
        if size.width < 88 || size.height < 58 { return .tiny }
        if size.width < 240 || size.height < 160 { return .compact }
        return .spacious
    }

    private var cellBody: some View {
        GeometryReader { geometry in
            let layout = tier(for: geometry.size)
            ZStack {
                background
                border

                switch layout {
                case .tiny:
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .compact:
                    compactContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(GargantuaSpacing.space3)
                case .spacious:
                    spaciousContent(in: geometry.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(GargantuaSpacing.space4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    // MARK: Layers

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(canDrillDown && isHovered ? GargantuaColors.surface4 : GargantuaColors.surface3)

            if item.isPermissionDenied {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.protectedDim)
            } else if item.isPartial {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.reviewDim)
            } else if item.isSizing {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.accent)
                    .opacity(reduceMotion ? 0.18 : (sizingPulse ? 0.28 : 0.10))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: sizingPulse
                    )
                    .onAppear {
                        guard !reduceMotion else { return }
                        sizingPulse = true
                    }
            }
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: GargantuaRadius.medium)
            .strokeBorder(borderColor, lineWidth: emphasized ? 2 : 1)
    }

    // MARK: Compact (top-left) layout

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16, alignment: .center)

                Text(item.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink3 : GargantuaColors.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            HStack(spacing: GargantuaSpacing.space2) {
                statusView
                Spacer(minLength: GargantuaSpacing.space1)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Spacious (centered) layout

    private func spaciousContent(in size: CGSize) -> some View {
        // Scale icon and primary number with available area so a 600×900 tile
        // doesn't render the same 13pt icon as a 240×160 one.
        let scale = min(size.width / 320, size.height / 220, 2.4)
        let iconSize = max(28, 28 * scale)
        let nameSize = max(20, 20 * min(scale, 1.6))
        let sizeFontSize = max(28, 28 * min(scale, 1.7))

        return VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: iconName)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(iconColor)

            Text(item.name)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink3 : GargantuaColors.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)

            spaciousStatus(fontSize: sizeFontSize)

            if let percentLabel, !item.isPermissionDenied, !item.isSizing {
                Text(percentLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    @ViewBuilder
    private func spaciousStatus(fontSize: CGFloat) -> some View {
        if item.isSizing {
            ProgressView()
                .controlSize(.regular)
        } else if item.isPermissionDenied {
            Text("Requires Full Disk Access")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.protected_)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
        } else {
            Text(sizeLabel)
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.isPartial ? GargantuaColors.review : GargantuaColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    // MARK: Status used in compact layout

    @ViewBuilder
    private var statusView: some View {
        if item.isSizing {
            ProgressView()
                .controlSize(.small)
        } else if item.isPermissionDenied {
            Text("Full Disk Access")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.protected_)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text(sizeLabel)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(item.isPartial ? GargantuaColors.review : GargantuaColors.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: Helpers

    private var emphasized: Bool {
        item.isPermissionDenied || item.isPartial || item.isSizing
    }

    private var borderColor: Color {
        if item.isPermissionDenied { return GargantuaColors.protected_ }
        if item.isPartial { return GargantuaColors.review }
        if item.isSizing { return GargantuaColors.accent }
        return GargantuaColors.borderEm
    }

    private var iconColor: Color {
        if item.isPermissionDenied { return GargantuaColors.protected_ }
        if item.isPartial { return GargantuaColors.review }
        if item.isSizing { return GargantuaColors.accent }
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        return GargantuaColors.ink2
    }

    private var sizeLabel: String {
        let prefix = item.isPartial ? "~" : ""
        return "\(prefix)\(AlertItem.formatBytes(item.size))"
    }

    private var percentLabel: String? {
        guard totalSiblingSize > 0, item.size > 0 else { return nil }
        let fraction = Double(item.size) / Double(totalSiblingSize)
        let percent = fraction * 100
        if percent >= 10 {
            return "\(Int(percent.rounded()))% of folder"
        }
        if percent >= 1 {
            return String(format: "%.1f%% of folder", percent)
        }
        return "<1% of folder"
    }

    private var accessibilityLabel: Text {
        if item.isPermissionDenied {
            return Text("\(item.name), requires Full Disk Access")
        }
        if item.isPartial {
            return Text("\(item.name), partial size, \(AlertItem.formatBytes(item.size))")
        }
        return Text("\(item.name), \(AlertItem.formatBytes(item.size))")
    }

    private var iconName: String {
        if item.isOthersAggregate { return "ellipsis.circle" }
        if item.isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        if item.isSizing { return "hourglass" }
        return "folder.fill"
    }
}

// MARK: - Directory Row

private struct DirectoryRowView: View {
    let item: DirectoryItem
    let maxSize: Int64
    let isExpanded: Bool
    let onExpand: (() async -> Void)?
    let onDrillDown: () -> Void
    var indentLevel: Int = 0

    @State private var isHovered = false
    @State private var isLoadingChildren = false

    private var sizeBarFraction: CGFloat {
        guard maxSize > 0, item.size > 0 else { return 0 }
        return CGFloat(item.size) / CGFloat(maxSize)
    }

    private var isFilesAggregate: Bool {
        item.isFilesAggregate
    }

    var body: some View {
        Button {
            if !item.isPermissionDenied && !isFilesAggregate {
                onDrillDown()
            }
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                // Expand/collapse chevron (directories only, not aggregated files)
                if !isFilesAggregate && !item.isPermissionDenied {
                    expandButton
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }

                // Icon
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink4 : GargantuaColors.ink2)
                    .frame(width: 18, alignment: .center)

                // Name + permission message
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink4 : GargantuaColors.ink)
                        .lineLimit(1)

                    if item.isPermissionDenied {
                        Text("Requires Full Disk Access")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }
                }

                Spacer()

                // Size bar + size label
                HStack(spacing: GargantuaSpacing.space3) {
                    if !item.isPermissionDenied && !item.isSizing {
                        sizeBar
                    } else if item.isSizing {
                        Color.clear.frame(width: 100, height: 6)
                    }

                    if item.isSizing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 70, alignment: .trailing)
                    } else {
                        sizeLabelView
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.leading, CGFloat(indentLevel) * GargantuaSpacing.space5)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var expandButton: some View {
        Button {
            guard let onExpand else { return }
            Task {
                isLoadingChildren = true
                await onExpand()
                isLoadingChildren = false
            }
        } label: {
            Group {
                if isLoadingChildren {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }

    private var sizeBar: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(GargantuaColors.accent.opacity(0.2))
                .frame(width: geo.size.width)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.accent)
                        .frame(width: max(2, geo.size.width * sizeBarFraction))
                }
        }
        .frame(width: 100, height: 6)
    }

    @ViewBuilder
    private var sizeLabelView: some View {
        if item.isPartial {
            formattedSizeLabel
                .help("Partial size. This directory hit the sizing time limit.")
        } else {
            formattedSizeLabel
        }
    }

    private var formattedSizeLabel: some View {
        Text(sizeLabel)
            .font(GargantuaFonts.monoData)
            .foregroundStyle(sizeLabelColor)
            .frame(width: 70, alignment: .trailing)
    }

    private var sizeLabel: String {
        guard !item.isPermissionDenied else { return "—" }
        let prefix = item.isPartial ? "~" : ""
        return "\(prefix)\(AlertItem.formatBytes(item.size))"
    }

    private var sizeLabelColor: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isPartial { return GargantuaColors.ink2 }
        return GargantuaColors.ink
    }

    private var iconName: String {
        if isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        return "folder.fill"
    }
}
