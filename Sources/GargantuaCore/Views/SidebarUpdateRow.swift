import SwiftUI

/// Sidebar footer row shown while Sparkle has a valid update pending.
/// Clicking it re-presents Sparkle's install flow.
struct SidebarUpdateRow: View {
    @ObservedObject var model: AppUpdateSettingsViewModel
    let isCollapsed: Bool

    @State private var isHovered = false

    private var title: String {
        model.updateVersion.map { "Update to \($0)" } ?? "Update available"
    }

    var body: some View {
        if model.updateAvailable {
            Button(action: { model.userInstallUpdate() }, label: {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 20, alignment: .center)
                        .frame(maxWidth: isCollapsed ? .infinity : nil, alignment: .center)

                    if !isCollapsed {
                        Text(title)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                            .lineLimit(1)
                            .transition(.opacity)

                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, GargantuaSpacing.space2)
                .padding(.horizontal, isCollapsed ? GargantuaSpacing.space2 : GargantuaSpacing.space4)
                .background {
                    RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                        .fill(GargantuaColors.accent.opacity(isHovered ? 0.2 : 0.12))
                        .padding(.horizontal, GargantuaSpacing.space2)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .nativeToolTip(title, isEnabled: isCollapsed)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .padding(.bottom, GargantuaSpacing.space2)
            .accessibilityLabel(model.updateVersion.map { "Install update, version \($0)" } ?? "Install update")
        }
    }
}
