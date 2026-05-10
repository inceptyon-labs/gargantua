import AppKit
import SwiftUI

struct DirectoryTreemapCellView: View {
    let item: DirectoryItem
    let totalSiblingSize: Int64
    let onDrillDown: () -> Void

    @State private var isHovered = false
    @State private var sizingPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

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
            } else if item.isPermissionDenied {
                Button {
                    openURL(Self.fullDiskAccessURL)
                } label: {
                    cellBody
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Full Disk Access in System Settings")
            } else {
                cellBody
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if canRevealInFinder {
                Button("Reveal in Finder") { revealInFinder() }
            }
        }
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
                .fill(fillForHoverState)

            if item.isPermissionDenied {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.protectedDim)
            } else if item.isPartial {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.reviewDim)
            } else if item.isSizing {
                // Neutral tonal pulse — sizing is a state, not interactivity,
                // so we don't use Hawking Blue here. The breathing animation
                // still conveys "this is computing" alongside the hourglass
                // icon and `ProgressView`.
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.ink2)
                    .opacity(reduceMotion ? 0.10 : (sizingPulse ? 0.16 : 0.04))
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

    @ViewBuilder
    private var border: some View {
        // Aggregate "Others" tiles use a dashed stroke at lower opacity so
        // they read as informational, not interactive. They aren't drillable
        // and shouldn't compete with sibling tiles for click attention.
        if item.isOthersAggregate {
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .strokeBorder(
                    GargantuaColors.borderEm.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        } else {
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .strokeBorder(borderColor, lineWidth: emphasized ? 2 : 1)
        }
    }

    /// Tile background fill, including hover lift. Hover lifts when the tile
    /// is actually clickable — drillable folders, and permission-denied
    /// folders that route taps to the Full Disk Access pane. Aggregate tiles
    /// stay flat (recessed surface2) to underline their non-interactive role.
    private var fillForHoverState: Color {
        if item.isOthersAggregate { return GargantuaColors.surface2 }
        let interactive = canDrillDown || item.isPermissionDenied
        if interactive && isHovered { return GargantuaColors.surface4 }
        return GargantuaColors.surface3
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
            VStack(spacing: GargantuaSpacing.space1) {
                Text("Requires Full Disk Access")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.protected_)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                HStack(spacing: GargantuaSpacing.space1) {
                    Text("Grant Access")
                        .font(GargantuaFonts.caption)
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(GargantuaColors.review)
            }
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
            HStack(spacing: GargantuaSpacing.space2) {
                Text(sizeLabel)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(item.isPartial ? GargantuaColors.review : GargantuaColors.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let percentLabel {
                    Text(percentLabel)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

// MARK: - Helper computed properties

//
// Hoisted into an extension so the view's struct body stays under SwiftLint's
// type-body-length budget. These are all pure derivations from `item` /
// `totalSiblingSize` and don't touch view state.

extension DirectoryTreemapCellView {
    var emphasized: Bool {
        item.isPermissionDenied || item.isPartial || item.isSizing
    }

    var borderColor: Color {
        if item.isPermissionDenied { return GargantuaColors.protected_ }
        if item.isPartial { return GargantuaColors.review }
        if item.isSizing { return GargantuaColors.borderEm }
        return GargantuaColors.borderEm
    }

    var iconColor: Color {
        if item.isPermissionDenied { return GargantuaColors.protected_ }
        if item.isPartial { return GargantuaColors.review }
        if item.isSizing { return GargantuaColors.ink3 }
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        return GargantuaColors.ink2
    }

    var sizeLabel: String {
        let prefix = item.isPartial ? "~" : ""
        return "\(prefix)\(AlertItem.formatBytes(item.size))"
    }

    var percentLabel: String? {
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

    var accessibilityLabel: Text {
        if item.isPermissionDenied {
            return Text("\(item.name), requires Full Disk Access")
        }
        if item.isPartial {
            return Text("\(item.name), partial size, \(AlertItem.formatBytes(item.size))")
        }
        return Text("\(item.name), \(AlertItem.formatBytes(item.size))")
    }

    var iconName: String {
        if item.isOthersAggregate { return "ellipsis.circle" }
        if item.isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        if item.isSizing { return "hourglass" }
        return "folder.fill"
    }
}
