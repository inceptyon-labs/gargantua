import SwiftUI

struct SidebarFooter: View {
    @ObservedObject var mcpStatusModel: MCPServerStatusViewModel
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
                .padding(.horizontal, GargantuaSpacing.space3)

            if !isCollapsed {
                SystemInfoBar(mcpStatusModel: mcpStatusModel)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if isCollapsed {
                    Spacer(minLength: 0)
                    CollapseToggle(
                        isCollapsed: isCollapsed,
                        onTap: onToggleCollapse
                    )
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    CollapseToggle(
                        isCollapsed: isCollapsed,
                        onTap: onToggleCollapse
                    )
                    .padding(.trailing, GargantuaSpacing.space3)
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
        }
    }
}

private struct CollapseToggle: View {
    let isCollapsed: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Image(
                systemName: isCollapsed
                    ? "sidebar.left"
                    : "sidebar.leading"
            )
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isHovered ? GargantuaColors.ink : GargantuaColors.ink3)
            .frame(width: 28, height: 22)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                    .fill(isHovered ? GargantuaColors.surface2 : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .nativeToolTip(isCollapsed ? "Expand sidebar (⌥⌘S)" : "Collapse sidebar (⌥⌘S)")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }
}
