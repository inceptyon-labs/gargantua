import SwiftUI

/// Compact strip of separate-volume rows rendered under the treemap. Mount
/// roots stream in at size 0 and never become their own treemap tile, so
/// this strip is their entry point into being drilled into (and sized).
struct DiskExplorerMountRootStripView: View {
    let items: [DirectoryItem]
    let onDrillDown: (DirectoryItem) -> Void

    private var mountRoots: [DirectoryItem] {
        items.filter(\.isMountRoot)
    }

    var body: some View {
        if !mountRoots.isEmpty {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text("Separate volumes")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        ForEach(mountRoots) { item in
                            volumeButton(for: item)
                        }
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space4)
        }
    }

    private func volumeButton(for item: DirectoryItem) -> some View {
        Button {
            onDrillDown(item)
        } label: {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: item.isNetworkVolume
                    ? "externaldrive.connected.to.line.below"
                    : "externaldrive")
                    .font(.system(size: 12))
                Text(item.isNetworkVolume ? "\(item.name) (network)" : item.name)
                    .font(GargantuaFonts.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.borderEm, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Separate volume — click to size it")
        .accessibilityLabel(item.isNetworkVolume ? "\(item.name), network volume" : "\(item.name), separate volume")
    }
}
