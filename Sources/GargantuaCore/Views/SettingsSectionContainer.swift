import SwiftUI

/// Standard settings-section wrapper. Section-Label tier title (10px 600 uppercase
/// 0.8px tracking, ink-3) above a Surface-2 card with a 1px Border evidence stroke.
///
/// Implements DESIGN.md §6 ("Don't make cards inside cards") and the Section-Label
/// type tier so every settings section uses the same hierarchy break.
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
                    Text(title.uppercased())
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(GargantuaColors.ink3)

                    if let trailingCount {
                        Text("\(trailingCount)")
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink4)
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
