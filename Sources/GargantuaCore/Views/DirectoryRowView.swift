import SwiftUI

struct DirectoryRowView: View {
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
