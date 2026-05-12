import SwiftUI

extension SmartUninstallerView {
    // MARK: - Idle / Landing State

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

                Button {
                    viewModel.runTracked { await viewModel.loadApps() }
                } label: {
                    Text("Scan Installed Apps")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
