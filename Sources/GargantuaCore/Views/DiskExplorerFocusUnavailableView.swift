import SwiftUI

/// Shown when the user picks the Focus display mode for a directory whose
/// children are sized similarly enough that no folder dominates. Explains
/// why Focus has no hero card to render and offers shortcuts back to the
/// Treemap or List modes. Lifted out of `DiskExplorerView` to keep that
/// struct under the SwiftLint type-body-length budget.
struct DiskExplorerFocusUnavailableView: View {
    let onPickTreemap: () -> Void
    let onPickList: () -> Void

    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "scope")
                .font(.system(size: 22))
                .foregroundStyle(GargantuaColors.ink3)

            Text("No dominant folder")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("Sizes are spread across multiple folders here. Focus mode highlights one outlier when one exists.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: GargantuaSpacing.space2) {
                Button(action: onPickTreemap) {
                    Text("View as Treemap")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)

                Button(action: onPickList) {
                    Text("View as List")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.surface3)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, GargantuaSpacing.space6)
    }
}
