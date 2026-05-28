import SwiftUI

extension SmartUninstallerView {
    // MARK: - Idle / Landing State

    private func uninstallerPreviewItem(icon: String, label: String) -> some View {
        VStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.ink3)
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    var idleView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Smart Uninstaller",
                subtitle: "Pull an app apart, root and remnants.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "smart-uninstaller-gargantua-gpt2",
                    fallbackSystemName: "trash.slash"
                )

                Text("Finds installed apps and surfaces their support files, caches, and login items so you can review what gets removed.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                HStack(spacing: GargantuaSpacing.space4) {
                    uninstallerPreviewItem(icon: "doc.badge.gearshape", label: "Support Files")
                    uninstallerPreviewItem(icon: "internaldrive", label: "Caches")
                    uninstallerPreviewItem(icon: "person.badge.clock", label: "Login Items")
                    uninstallerPreviewItem(icon: "slider.horizontal.3", label: "Preferences")
                }

                GargantuaButton("Scan Installed Apps", tone: .primary) {
                    viewModel.runTracked { await viewModel.loadApps() }
                }
                .padding(.top, GargantuaSpacing.space2)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
