import AppKit
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
    @Environment(\.openURL) private var openURL

    private static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    private var sizeBarFraction: CGFloat {
        guard maxSize > 0, item.size > 0 else { return 0 }
        return CGFloat(item.size) / CGFloat(maxSize)
    }

    private var isFilesAggregate: Bool {
        item.isFilesAggregate
    }

    var body: some View {
        Button {
            if item.isOthersAggregate {
                // Aggregate row is informational; matches treemap behavior.
            } else if item.isPermissionDenied {
                openURL(Self.fullDiskAccessURL)
            } else if !isFilesAggregate {
                onDrillDown()
            }
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                // Expand/collapse chevron (directories only — not aggregates,
                // not permission-denied).
                if !isFilesAggregate && !item.isPermissionDenied && !item.isOthersAggregate {
                    expandButton
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }

                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconTint)
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(nameTint)
                        .lineLimit(1)

                    if item.isPermissionDenied {
                        Text("Requires Full Disk Access")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }
                }

                Spacer()

                HStack(spacing: GargantuaSpacing.space3) {
                    if item.isPermissionDenied {
                        grantAccessAffordance
                    } else if item.isSizing {
                        Color.clear.frame(width: 100, height: 6)
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 70, alignment: .trailing)
                    } else if item.isOthersAggregate {
                        sizeLabelView
                    } else {
                        sizeBar
                        sizeLabelView
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.leading, CGFloat(indentLevel) * GargantuaSpacing.space5)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if canRevealInFinder {
                Button("Reveal in Finder") { revealInFinder() }
            }
        }
    }

    /// Aggregate rows render flat against `surface1` to read as informational;
    /// regular rows lift to `surface3` on hover, matching the treemap's
    /// hover-lift convention.
    private var rowBackground: Color {
        if item.isOthersAggregate { return GargantuaColors.surface1 }
        return isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
    }

    private var nameTint: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        return GargantuaColors.ink
    }

    /// Icon stays one tonal step dimmer than the name across all states.
    private var iconTint: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isOthersAggregate { return GargantuaColors.ink4 }
        return GargantuaColors.ink2
    }

    private var canRevealInFinder: Bool {
        !item.isPermissionDenied
            && !item.isSizing
            && !item.isFilesAggregate
            && !item.isOthersAggregate
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: item.path)]
        )
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

    private var grantAccessAffordance: some View {
        // Pure label — the surrounding row Button already routes
        // permission-denied taps to the Full Disk Access settings pane.
        // Rendering this as another Button would nest tap targets and
        // produce different hit regions for the same action.
        HStack(spacing: GargantuaSpacing.space1) {
            Text("Grant Access")
                .font(GargantuaFonts.caption)
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(GargantuaColors.review)
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
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        if item.isPartial { return GargantuaColors.ink2 }
        return GargantuaColors.ink
    }

    private var iconName: String {
        if item.isOthersAggregate { return "ellipsis.circle" }
        if isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        return "folder.fill"
    }
}
