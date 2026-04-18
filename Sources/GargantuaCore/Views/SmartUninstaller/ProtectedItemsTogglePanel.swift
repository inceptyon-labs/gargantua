import SwiftUI

/// Lock/unlock card shown at the bottom of the plan review when the plan
/// contains any protected items. Unlocking lets the user select them for
/// uninstall; they'll still have to acknowledge each one in the final modal.
struct ProtectedItemsTogglePanel: View {
    @Bindable var viewModel: SmartUninstallerViewModel
    let plan: UninstallPlan

    var body: some View {
        let protectedItems = plan.allItems.filter { $0.safety == .protected_ }
        if !protectedItems.isEmpty {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: viewModel.includeProtected ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.protected_)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(protectedItems.count) protected item\(protectedItems.count == 1 ? "" : "s")")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text("System-level files (launch daemons, helpers). Unlock to select them — you'll acknowledge each one before uninstall.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.includeProtected },
                        set: { viewModel.setIncludeProtected($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Include protected items")
                .accessibilityHint(
                    "Unlock to allow selecting system-level files such as launch daemons and helpers"
                )
            }
            .padding(GargantuaSpacing.space3)
            .background(GargantuaColors.protected_.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.protected_.opacity(0.3), lineWidth: 1)
            )
        }
    }
}
