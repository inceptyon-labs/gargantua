import Foundation
import SwiftUI

extension DeveloperToolsView {
    var idleView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            GargantuaBrandIcon(
                resourceName: "developer-tools-gargantua-gpt2",
                fallbackSystemName: "hammer",
                fallbackColor: GargantuaColors.ink4
            )

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Scan developer tools")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(
                    "Checks Homebrew, Docker, Xcode Simulator, pnpm, Go, and Cargo for cleanup opportunities. "
                        + "Read-only previews — nothing runs without an explicit Run click."
                )
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }

            Button(action: startScan) {
                Text("Scan tools")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var loadingView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)
            Text("Checking installed tools…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func emptyView(availabilities: [DeveloperToolAvailability]) -> some View {
        VStack(spacing: GargantuaSpacing.space4) {
            Image(systemName: "hammer")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("No developer tools detected")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text(
                    "Gargantua looks for Homebrew, Docker, Xcode, pnpm, Go, and Cargo in standard install locations. "
                        + "Install one to see dry-run cleanup previews here."
                )
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }

            if availabilities.contains(where: { !$0.isInstalled && $0.error != nil }) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    ForEach(availabilities.filter { !$0.isInstalled }, id: \.tool) { availability in
                        HStack(spacing: GargantuaSpacing.space2) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(GargantuaColors.ink4)
                            Text(availability.tool.displayName)
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink3)
                            Text(availability.error ?? "not found")
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink4)
                        }
                    }
                }
                .padding(.top, GargantuaSpacing.space2)
            }
        }
        .padding(GargantuaSpacing.space5)
    }
}
