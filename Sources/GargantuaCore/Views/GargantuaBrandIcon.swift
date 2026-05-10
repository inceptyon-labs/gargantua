import AppKit
import SwiftUI

struct GargantuaBrandIcon: View {
    let resourceName: String
    let fallbackSystemName: String

    var size: CGFloat = 160
    var fallbackSize: CGFloat = 72
    var fallbackColor: Color = GargantuaColors.ink3

    @State private var image: NSImage?

    @MainActor private static var imageCache: [String: NSImage] = [:]

    var body: some View {
        Group {
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
        .task(id: resourceName) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        if let cached = Self.imageCache[resourceName] {
            image = cached
            return
        }

        guard let data = await Self.loadImageData(resourceName: resourceName),
              let loaded = NSImage(data: data) else {
            return
        }
        Self.imageCache[resourceName] = loaded
        image = loaded
    }

    private static func loadImageData(resourceName: String) async -> Data? {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "Brand/generated"
        ) else {
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }
}
