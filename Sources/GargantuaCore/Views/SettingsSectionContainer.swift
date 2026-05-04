import SwiftUI

/// Standard settings-section wrapper. Title-tier heading (15px 600, ink) above
/// a Surface-2 card with a 1px Border evidence stroke. Sub-groupings inside the
/// card use `SettingsSubsectionHeader` (Section-Label tier).
///
/// Implements DESIGN.md §6 ("Don't make cards inside cards") and gives each
/// section a heading bright enough to anchor a stack of 3-4 of them per tab.
struct SettingsSectionContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let trailingCount: Int?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        subtitle: String? = nil,
        count: Int? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingCount = count
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(title)
                        .font(GargantuaFonts.title)
                        .foregroundStyle(GargantuaColors.ink)

                    if let trailingCount {
                        Text("\(trailingCount)")
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                content()
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
        }
    }
}
