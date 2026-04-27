import SwiftUI

/// Disk Explorer with native treemap and sorted list views for disk consumers.
///
/// Shows the largest directories at the current path, sorted by size.
/// Click to expand loads child directories on demand.
/// Breadcrumb trail tracks drill-down navigation.
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

    public init() {}

    private var currentPath: String { pathStack.last?.path ?? NSHomeDirectory() }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                headerView
                breadcrumbView
                contentView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: currentPath) {
            await loadDirectory(currentPath)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text("Disk Explorer")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            if isLoading {
                scanStatusPill
            }

            Spacer()

            Picker("Display mode", selection: $displayMode) {
                Label("Treemap", systemImage: "square.grid.2x2")
                    .tag(DiskExplorerDisplayMode.treemap)
                Label("List", systemImage: "list.bullet")
                    .tag(DiskExplorerDisplayMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    private var scanStatusPill: some View {
        let total = items.filter { !$0.isPermissionDenied && !$0.isFilesAggregate }.count
        let pending = items.filter { $0.isSizing }.count
        let done = max(total - pending, 0)
        let label: String = {
            if total == 0 { return "Probing gravitational pull…" }
            if pending == 0 { return "Finishing up…" }
            return "Sizing \(done) of \(total) folders…"
        }()
        let activityRate: Double = pending > 0 ? 12 : 4
        return HStack(spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: activityRate, size: 22, color: GargantuaColors.accent)
            Text(label)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
                .monospacedDigit()
                .accessibilityLabel(label)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(
            Capsule().fill(GargantuaColors.surface2)
        )
        .overlay(
            Capsule().strokeBorder(GargantuaColors.accent.opacity(0.4), lineWidth: 1)
        )
        .transition(.opacity)
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
            .padding(.bottom, GargantuaSpacing.space4)
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

    private var treemapView: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - GargantuaSpacing.space6 * 2, 1)
            let height = max(geometry.size.height - GargantuaSpacing.space6, 1)
            let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let tiles = DiskTreemapLayout.tiles(for: items, in: bounds)

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
        guard !item.isPermissionDenied, !item.isFilesAggregate else { return }
        pathStack.append((path: item.path, name: item.name))
    }

    private func navigateTo(index: Int) {
        guard index < pathStack.count - 1 else { return }
        pathStack = Array(pathStack.prefix(index + 1))
    }
}

private enum DiskExplorerDisplayMode {
    case treemap
    case list
}

// MARK: - Treemap Cell

private struct DirectoryTreemapCellView: View {
    let item: DirectoryItem
    let onDrillDown: () -> Void

    @State private var isHovered = false
    @State private var sizingPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canDrillDown: Bool {
        !item.isPermissionDenied && !item.isFilesAggregate && !item.isSizing
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
