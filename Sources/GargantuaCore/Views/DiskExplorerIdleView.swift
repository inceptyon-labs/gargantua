import SwiftUI

/// Pre-scan landing for Disk Explorer. Renders the title bar, the brand
/// icon, and the "Start Disk Scan" CTA. Lifted out of `DiskExplorerView`
/// so the host struct stays under the SwiftLint type-body-length budget.
struct DiskExplorerIdleView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Disk Explorer",
                subtitle: "Trace where bytes accrete in your filesystem.",
                subtitleStyle: .voice
            )

            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                GargantuaBrandIcon(
                    resourceName: "disk-explorer-gargantua-gpt2-v2",
                    fallbackSystemName: "externaldrive"
                )

                Text("Folder Sizes")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Visualize what's eating your home directory. Click any folder to drill in.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "house")
                        .font(.system(size: 11))
                        .foregroundStyle(GargantuaColors.ink4)
                    Text("~")
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(GargantuaColors.ink4)
                    Text("treemap + list")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                }

                GargantuaButton("Start Disk Scan", tone: .primary, action: onStart)
                    .padding(.top, GargantuaSpacing.space2)
            }

            Spacer()
        }
    }
}
