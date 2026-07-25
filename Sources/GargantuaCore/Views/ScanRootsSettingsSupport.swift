import Foundation
import SwiftUI

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
