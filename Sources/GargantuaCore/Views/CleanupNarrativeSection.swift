import SwiftUI

/// One-row narrative panel rendered inside `CleanupSummaryView` when a
/// `\.cleanupNarrator` environment value is wired. The label switches between
/// "AI summary" and "Summary" based on the narrative's `source` so the user
/// can always tell whether the text came from a model or a deterministic
/// template.
struct CleanupNarrativeSection: View {
    let narrative: CleanupNarrative

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(narrative.source == .ai ? "AI summary" : "Summary")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.accent)
                    .accessibilityLabel(narrative.source == .ai
                        ? "AI-generated summary"
                        : "Template summary")

                Text(narrative.text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(GargantuaSpacing.space4)
    }
}
