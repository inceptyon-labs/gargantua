import SwiftUI

/// Pre-scan landing for Disk Explorer. Renders the title bar, the brand
/// icon, and the "Start Disk Scan" CTA. Lifted out of `DiskExplorerView`
/// so the host struct stays under the SwiftLint type-body-length budget.
struct DiskExplorerIdleView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disk Explorer")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                GargantuaBrandIcon(
                    resourceName: "disk-explorer-gargantua-gpt2-v2",
                    fallbackSystemName: "externaldrive"
                )

                Text("Disk Map")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Visualize what's eating your home directory. Click any folder to drill in.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button(action: onStart) {
                    Text("Start Disk Scan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)
            }

            Spacer()
        }
    }
}
