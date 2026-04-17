import SwiftUI

/// Disk Explorer — sorted expandable list of disk consumers with size bars.
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

    public init() {}

    private var currentPath: String { pathStack.last?.path ?? NSHomeDirectory() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            breadcrumbView
            listView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task(id: currentPath) {
            await loadDirectory(currentPath)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Disk Explorer")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space3)
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

    // MARK: - List

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

                    // Expanded children
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
                        Text(item.isPermissionDenied ? "—" : AlertItem.formatBytes(item.size))
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(item.isPermissionDenied ? GargantuaColors.ink4 : GargantuaColors.ink)
                            .frame(width: 70, alignment: .trailing)
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

    private var iconName: String {
        if isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        return "folder.fill"
    }
}
