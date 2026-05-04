import Foundation
import SwiftUI

struct ScanRootErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.protected_)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.protected_)
        }
    }
}

var scanRootDivider: some View {
    SettingsHairlineDivider()
}

func abbreviatedScanRootPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

extension View {
    func scanRootRowStyle() -> some View {
        padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, GargantuaSpacing.space2)
    }
}
