import AppKit
import SwiftUI

struct GargantuaBrandIcon: View {
    let resourceName: String
    let fallbackSystemName: String

    var size: CGFloat = 160
    var fallbackSize: CGFloat = 72
    var fallbackColor: Color = GargantuaColors.ink3

    private var image: NSImage? {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "Brand/generated"
        ) else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: fallbackSize))
                .foregroundStyle(fallbackColor)
                .accessibilityHidden(true)
        }
    }
}
