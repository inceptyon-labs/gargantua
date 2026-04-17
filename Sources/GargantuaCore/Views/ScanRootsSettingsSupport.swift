import Foundation
import SwiftUI

struct ScanRootErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.review)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.review)
        }
    }
}

var scanRootDivider: some View {
    Rectangle()
        .fill(GargantuaColors.borderSoft)
        .frame(height: 1)
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
        padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(GargantuaColors.surface2)
    }
}
