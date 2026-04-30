import SwiftUI

struct DirectoryTreemapCellView: View {
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
