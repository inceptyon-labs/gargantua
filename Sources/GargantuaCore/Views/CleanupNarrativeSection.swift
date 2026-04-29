import SwiftUI

/// One-row narrative panel rendered inside `CleanupSummaryView` when a
/// `\.cleanupNarrator` environment value is wired. The label and accessibility
/// description reflect the narrative's `source` so the user can always tell
/// whether the text came from a model, a rule-based template, or a raw YAML
/// fallback.
struct CleanupNarrativeSection: View {
    let narrative: CleanupNarrative
    @Environment(\.openAIModelSettings) private var openAIModelSettings
    @Environment(\.preferredAIEngineKind) private var preferredAIEngineKind

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(headingText)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.accent)
                    .accessibilityLabel(accessibilityHeading)

                Text(narrative.text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if narrative.source == .template,
                   preferredAIEngineKind == .template,
                   let openSettings = openAIModelSettings {
                    enableAIFooterNote(openSettings: openSettings)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(GargantuaSpacing.space4)
    }

    private var headingText: String {
        switch narrative.source {
        case .ai: return "AI summary"
        case .template: return "Summary"
        case .rule: return "Summary"
        }
    }

    private var accessibilityHeading: String {
        switch narrative.source {
        case .ai: return "AI-generated summary"
        case .template: return "Rule-based summary"
        case .rule: return "Template summary"
        }
    }

    private func enableAIFooterNote(openSettings: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink3)
            Text("This is rule-based.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
            Button("Enable local AI") { openSettings() }
                .font(GargantuaFonts.caption)
                .buttonStyle(.plain)
                .foregroundStyle(GargantuaColors.accent)
        }
        .padding(.top, GargantuaSpacing.space1)
    }
}
