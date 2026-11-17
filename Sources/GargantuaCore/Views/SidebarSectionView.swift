import SwiftUI

struct SidebarSectionView: View {
    let section: SidebarSection
    @Binding var selection: String?
    let isCollapsed: Bool
    var badges: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            if !isCollapsed {
                Text(section.label)
                    .font(GargantuaFonts.sectionLabel)
                    .foregroundStyle(GargantuaColors.ink4)
                    .tracking(0.8) // 0.08em × 10px = 0.8pt
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.bottom, GargantuaSpacing.space1)
                    .transition(.opacity)
            }

            ForEach(section.items) { item in
                SidebarItemRow(
                    item: item,
                    isSelected: selection == item.id,
                    isCollapsed: isCollapsed,
                    badgeCount: badges[item.id] ?? 0,
                    onSelect: { selection = item.id }
                )
            }
        }
    }
}

private struct SidebarItemRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let isCollapsed: Bool
    let badgeCount: Int
    let onSelect: () -> Void

    @State private var isHovered = false

    private static let transitionDuration: Double = 0.12

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink3)
                    .frame(width: 20, alignment: .center)
                    .frame(maxWidth: isCollapsed ? .infinity : nil, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if isCollapsed, badgeCount > 0 {
                            Circle()
                                .fill(GargantuaColors.accent)
                                .frame(width: 8, height: 8)
                                .offset(x: 3, y: -2)
                        }
                    }

                if !isCollapsed {
                    Text(item.label)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)
                        .lineLimit(1)
                        .transition(.opacity)

                    Spacer(minLength: 0)

                    if badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(GargantuaFonts.sectionLabel.monospacedDigit())
                            .foregroundStyle(GargantuaColors.void_)
                            .padding(.horizontal, GargantuaSpacing.space1)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule(style: .continuous).fill(GargantuaColors.accent))
                            .fixedSize()
                    }
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, isCollapsed ? GargantuaSpacing.space2 : GargantuaSpacing.space4)
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                    .fill(rowBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                            .stroke(isSelected ? GargantuaColors.borderEm : .clear, lineWidth: 1)
                    }
                    .padding(.horizontal, GargantuaSpacing.space2)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(GargantuaColors.accent)
                        .frame(width: 3, height: 22)
                        .padding(.leading, GargantuaSpacing.space1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .nativeToolTip(item.label, isEnabled: isCollapsed)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: Self.transitionDuration), value: isSelected)
        .animation(.easeOut(duration: Self.transitionDuration), value: isHovered)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard badgeCount > 0 else { return item.label }
        return "\(item.label), \(badgeCount) \(badgeCount == 1 ? "update" : "updates") available"
    }

    private var rowBackground: Color {
        if isSelected {
            return GargantuaColors.surface2
        } else if isHovered {
            return GargantuaColors.surface1
        }
        return .clear
    }
}
