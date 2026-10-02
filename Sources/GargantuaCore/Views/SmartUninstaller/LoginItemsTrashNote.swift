import AppKit
import SwiftUI

/// macOS keeps an app's Login Items and Allow in the Background entries
/// pointed at its bundle after the bundle moves to the Trash, and no public
/// API removes another app's entries. Reading that list needs an admin
/// prompt, so the summary notes it for every trashed app instead of checking.
struct LoginItemsTrashNote: View {
    let message: String

    nonisolated static func message(for results: [UninstallExecutionResult]) -> String? {
        let names = results.filter { !$0.dryRun }.compactMap { result in
            result.cleanupResult.itemResults
                .first { $0.succeeded && $0.item.tags.contains("app_bundle") }?
                .item.source.name
        }
        switch names.count {
        case 0:
            return nil
        case 1:
            return "If \(names[0]) was in Login Items or Allow in the Background, "
                + "macOS keeps listing it while the app is in the Trash."
        default:
            return "If any of these apps were in Login Items or Allow in the Background, "
                + "macOS keeps listing them while the apps are in the Trash."
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Login Items")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.accent)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .frame(maxWidth: 480)
    }
}
