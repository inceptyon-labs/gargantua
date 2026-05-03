import SwiftUI

/// Top-of-page header bar shared across destination views.
///
/// Leading-aligned title with optional subtitle, optional trailing action slot,
/// followed by a 1pt `border` rule that separates the header from page content.
/// Pads `space4` horizontally and vertically to match the canonical pattern
/// established in DiskExplorerIdleView, DeepCleanView, AIModelsView, and
/// DevArtifactScanView.
public struct PageHeaderView<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: () -> Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(2)
                    }
                }

                Spacer()

                trailing()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }
}

extension PageHeaderView where Trailing == EmptyView {
    public init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}
