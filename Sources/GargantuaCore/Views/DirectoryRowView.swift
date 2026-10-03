import AppKit
import GargantuaLicensing
import SwiftUI

struct DirectoryRowView: View {
    let item: DirectoryItem
    let maxSize: Int64
    let isExpanded: Bool
    let onExpand: (() async -> Void)?
    let onDrillDown: () -> Void
    let onItemTrashed: (() -> Void)?
    let onLicenseBlocked: (BlockReason) -> Void
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

    private var mountRootCaption: String {
        item.isNetworkVolume ? "Network volume — open to size" : "Separate volume — open to size"
    }

    var body: some View {
        Button {
            if item.isOthersAggregate || item.isFile {
                // Aggregate row is informational; matches treemap behavior.
                // A file has nothing to open; its menu reveals or trashes it.
            } else if item.isPermissionDenied {
                openURL(Self.fullDiskAccessURL)
            } else if isFilesAggregate, onExpand != nil {
                toggleExpansion()
            } else {
                onDrillDown()
            }
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                // Expand/collapse chevron: directories, and "(Files)", which
                // expands into its files. Not "Others", files, or
                // permission-denied rows.
                if onExpand != nil && !item.isPermissionDenied && !item.isOthersAggregate && !item.isFile {
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
                    } else if item.isMountRoot {
                        Text(mountRootCaption)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    } else if item.sharedCloneBytes > 0 {
                        Text("up to \(AlertItem.formatBytes(item.sharedCloneBytes)) shared with clones")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }
                }

                Spacer()

                HStack(spacing: GargantuaSpacing.space3) {
                    if item.isPermissionDenied {
                        grantAccessAffordance
                    } else if item.isMountRoot {
                        Text("—")
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink4)
                            .frame(width: 70, alignment: .trailing)
                    } else if item.isSizing {
                        Color.clear.frame(width: 100, height: 6)
                        AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
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
        .modifier(DiskExplorerItemMenu(item: item, onItemTrashed: onItemTrashed, onLicenseBlocked: onLicenseBlocked))
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
        if let sizeHelpText {
            formattedSizeLabel.help(sizeHelpText)
        } else {
            formattedSizeLabel
        }
    }

    /// Combines the partial-size caveat with the APFS clone-sharing caveat when both apply,
    /// so trashing this row doesn't surprise the user on either count.
    private var sizeHelpText: String? {
        var parts: [String] = []
        if item.isPartial {
            parts.append("Partial size — some items couldn't be read or sizing hit its time limit.")
        }
        if item.sharedCloneBytes > 0 {
            parts.append(
                "Includes up to \(AlertItem.formatBytes(item.sharedCloneBytes)) that may be shared with APFS clones — " +
                    "deleting it may free less than shown."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
        if isFilesAggregate { return "doc.on.doc" }
        if item.isFile { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        if item.isMountRoot {
            return item.isNetworkVolume ? "externaldrive.connected.to.line.below" : "externaldrive"
        }
        return "folder.fill"
    }
}

extension DirectoryRowView {
    private func toggleExpansion() {
        guard let onExpand, !isLoadingChildren else { return }
        Task {
            isLoadingChildren = true
            await onExpand()
            isLoadingChildren = false
        }
    }

    private var expandButton: some View {
        Button {
            toggleExpansion()
        } label: {
            Group {
                if isLoadingChildren {
                    AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
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
}
