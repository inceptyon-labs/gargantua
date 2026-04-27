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
    /// Stack of (path, displayName) representing the drill-down breadcrumb trail.
    @State private var pathStack: [(path: String, name: String)] = [
        (path: NSHomeDirectory(), name: "Home")
    ]
    @State private var items: [DirectoryItem] = []
    @State private var expandedItems: [String: [DirectoryItem]] = [:]
    @State private var isLoading = false
    @State private var maxSize: Int64 = 1
    @State private var displayMode: DiskExplorerDisplayMode = .treemap
    @State private var phase: DiskExplorerPhase = .idle
    @State private var scanGeneration = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    private var currentPath: String { pathStack.last?.path ?? NSHomeDirectory() }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            switch phase {
            case .idle:
                idleView
                    .transition(.opacity)
            case .results:
                resultsView
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: phase)
        .task(id: scanLoadKey) {
            guard phase == .results else { return }
            await loadDirectory(currentPath)
        }
    }

    /// Bumped on every navigation/rescan so `.task(id:)` re-runs the scan
    /// even when the path hasn't changed (e.g. Refresh on the same dir).
    private var scanLoadKey: String { "\(scanGeneration)|\(currentPath)" }

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
                isBusy: isLoading
            )

            controlsBar
            breadcrumbView
            contentView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scanSubtitle: String? {
        let total = items.filter { !$0.isPermissionDenied && !$0.isFilesAggregate }.count
        let pending = items.filter { $0.isSizing }.count
        let done = max(total - pending, 0)
        if isLoading {
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
            if isLoading {
                AccretionDiskView(activityRate: 14, size: 18, color: GargantuaColors.accent)
                    .accessibilityHidden(true)
            }
            Spacer()
            DisplayModeToggle(selection: $displayMode)
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space3)
        .padding(.bottom, GargantuaSpacing.space2)
    }

    // MARK: - Breadcrumb

    private var breadcrumbView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GargantuaSpacing.space1) {
                ForEach(Array(pathStack.enumerated()), id: \.offset) { index, crumb in
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
                                index == pathStack.count - 1
                                    ? GargantuaColors.ink
                                    : GargantuaColors.accent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(index == pathStack.count - 1)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space3)
        }
    }

    // MARK: - Content

    private var contentView: some View {
        Group {
            if !isLoading, items.isEmpty {
                emptyState
            } else {
                switch displayMode {
                case .treemap:
                    treemapView
                case .list:
                    listView
                }
            }
        }
    }

    private var displayItems: [DirectoryItem] {
        DiskExplorerView.collapseSmall(items)
    }

    private var treemapView: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - GargantuaSpacing.space6 * 2, 1)
            let height = max(geometry.size.height - GargantuaSpacing.space6, 1)
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let tiles = DiskTreemapLayout.tiles(for: displayItems, in: bounds)

            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    DirectoryTreemapCellView(
                        item: tile.item,
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
                ForEach(items) { item in
                    DirectoryRowView(
                        item: item,
                        maxSize: maxSize,
                        isExpanded: expandedItems[item.path] != nil,
                        onExpand: { await toggleExpand(item) },
                        onDrillDown: { drillDown(into: item) }
                    )

                    if let children = expandedItems[item.path] {
                        ForEach(children) { child in
                            DirectoryRowView(
                                item: child,
                                maxSize: maxSize,
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

    private func startScan() {
        pathStack = [(path: NSHomeDirectory(), name: "Home")]
        items = []
        expandedItems = [:]
        maxSize = 1
        scanGeneration += 1
        phase = .results
    }

    private func refreshCurrent() {
        items = []
        expandedItems = [:]
        maxSize = 1
        scanGeneration += 1
    }

    private func rescanFromHome() {
        pathStack = [(path: NSHomeDirectory(), name: "Home")]
        items = []
        expandedItems = [:]
        maxSize = 1
        scanGeneration += 1
    }

    private func exitToIdle() {
        items = []
        expandedItems = [:]
        maxSize = 1
        pathStack = [(path: NSHomeDirectory(), name: "Home")]
        phase = .idle
    }

    private func loadDirectory(_ path: String) async {
        isLoading = true
        expandedItems = [:]
        items = []
        maxSize = 1

        for await item in DirectorySizeScanner.streamChildren(of: path) {
            if Task.isCancelled { return }
            upsert(item)
        }

        if !Task.isCancelled {
            isLoading = false
        }
    }

    /// Insert or replace `item` (keyed by `item.id`), then keep `items` sorted
    /// largest-first with permission-denied rows pushed to the bottom.
    private func upsert(_ item: DirectoryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        items.sort { lhs, rhs in
            if lhs.isPermissionDenied != rhs.isPermissionDenied {
                return !lhs.isPermissionDenied
            }
            return lhs.size > rhs.size
        }
        maxSize = items.first(where: { !$0.isPermissionDenied && !$0.isSizing })?.size ?? 1
    }

    private func toggleExpand(_ item: DirectoryItem) async {
        if expandedItems[item.path] != nil {
            expandedItems.removeValue(forKey: item.path)
        } else {
            let children = await DirectorySizeScanner.scanChildren(of: item.path)
            expandedItems[item.path] = children
        }
    }

    private func drillDown(into item: DirectoryItem) {
        guard !item.isPermissionDenied,
              !item.isFilesAggregate,
              !item.isOthersAggregate,
              !item.isSizing else { return }
        pathStack.append((path: item.path, name: item.name))
    }

    private func navigateTo(index: Int) {
        guard index < pathStack.count - 1 else { return }
        pathStack = Array(pathStack.prefix(index + 1))
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

private enum DiskExplorerDisplayMode {
    case treemap
    case list
}

private enum DiskExplorerPhase {
    case idle
    case results
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

    private var cellBody: some View {
        GeometryReader { geometry in
            let isTiny = geometry.size.width < 88 || geometry.size.height < 58
            let isCompact = geometry.size.width < 150 || geometry.size.height < 92

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(canDrillDown && isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2)

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

                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .strokeBorder(borderColor, lineWidth: emphasized ? 2 : 1)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Image(systemName: iconName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(iconColor)
                            .frame(width: 16, alignment: .center)

                        if !isTiny {
                            Text(item.name)
                                .font(GargantuaFonts.label)
                                .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink3 : GargantuaColors.ink)
                                .lineLimit(isCompact ? 1 : 2)
                                .minimumScaleFactor(0.82)
                        }
                    }

                    if !isTiny {
                        HStack(spacing: GargantuaSpacing.space2) {
                            statusView
                            Spacer(minLength: GargantuaSpacing.space1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(GargantuaSpacing.space3)
            }
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

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
