import AppKit
import SwiftUI

struct GargantuaBrandIcon: View {
    let resourceName: String
    let fallbackSystemName: String

    var size: CGFloat = 160
    var fallbackSize: CGFloat = 72
    var fallbackColor: Color = GargantuaColors.ink3

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

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
        .task(id: "\(resourceName)|\(colorScheme == .light)") {
            await loadImage()
        }
    }

    /// The base renders are dark metal lit for the void background and read
    /// as heavy blobs on light paper, so light mode loads the `-light` render
    /// (white ceramic, same composition) when one is bundled.
    @MainActor
    private func loadImage() async {
        if colorScheme == .light, let light = await Self.cachedImage(named: "\(resourceName)-light") {
            image = light
        } else if let dark = await Self.cachedImage(named: resourceName) {
            image = dark
        }
    }

    @MainActor
    private static func cachedImage(named name: String) async -> NSImage? {
        if let cached = imageCache[name] { return cached }
        guard let data = await loadImageData(resourceName: name),
              let loaded = NSImage(data: data) else {
            return nil
        }
        imageCache[name] = loaded
        return loaded
    }

    private static func loadImageData(resourceName: String) async -> Data? {
        guard let url = Bundle.gargantuaCoreResources.url(
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
