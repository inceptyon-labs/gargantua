import AppKit
import SwiftUI

/// Pre-scan landing for Disk Explorer. Renders the title bar, the brand
/// icon, and the scan-root picker (Home, the boot volume, or a chosen
/// folder). Lifted out of `DiskExplorerView` so the host struct stays under
/// the SwiftLint type-body-length budget.
struct DiskExplorerIdleView: View {
    let onStart: (DiskExplorerCrumb) -> Void

    private var bootVolumeName: String {
        DiskExplorerState.crumb(forRootPath: "/").name
    }

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

                Text("Visualize what's eating your disk. Click any folder to drill in.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Text("treemap + list")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)

                rootPicker
                    .padding(.top, GargantuaSpacing.space2)
            }

            Spacer()
        }
    }

    private var rootPicker: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            GargantuaButton("Scan Home", tone: .primary) { onStart(.home) }

            HStack(spacing: GargantuaSpacing.space2) {
                GargantuaButton("Scan \(bootVolumeName)", tone: .neutral) {
                    onStart(DiskExplorerState.crumb(forRootPath: "/"))
                }
                GargantuaButton("Choose Folder…", tone: .neutral, action: chooseFolder)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onStart(DiskExplorerState.crumb(forRootPath: url.path))
    }
}
