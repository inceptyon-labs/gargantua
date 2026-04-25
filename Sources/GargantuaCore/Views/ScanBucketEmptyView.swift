import SwiftUI

/// Placeholder shown when the current scan bucket has no visible results.
struct ScanBucketEmptyView: View {
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "sparkle.magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(GargantuaColors.ink4)

            VStack(spacing: GargantuaSpacing.space1) {
                Text(isFiltered ? "No Matching Results" : "No Results")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)

                Text(isFiltered ? "Clear or adjust the filter to see more items." : "Run a scan to populate this list.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GargantuaSpacing.space6)
    }
}
