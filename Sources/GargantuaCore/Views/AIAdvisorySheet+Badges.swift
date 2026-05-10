import SwiftUI

extension AIAdvisorySheet {
    @ViewBuilder
    func sourceBadge(_ source: ExplanationSource) -> some View {
        switch source {
        case .ai:
            badge(label: "AI", icon: "sparkles", color: GargantuaColors.accent)
        case .template:
            badge(label: "Rule-based", icon: "doc.text", color: GargantuaColors.ink3)
        case .rule:
            badge(label: "YAML", icon: "doc.text.magnifyingglass", color: GargantuaColors.ink3)
        }
    }

    func suggestedClassificationLabel(for source: ExplanationSource) -> String {
        switch source {
        case .ai: return "AI suggests:"
        case .template, .rule: return "Suggested:"
        }
    }

    @ViewBuilder
    func suggestedSafetyBadge(_ level: SafetyLevel) -> some View {
        switch level {
        case .safe:
            badge(label: "safe", icon: "circle.fill", color: GargantuaColors.safe)
        case .review:
            badge(label: "review", icon: "circle.fill", color: GargantuaColors.review)
        case .protected_:
            badge(label: "protected", icon: "circle.fill", color: GargantuaColors.protected_)
        }
    }

    private func badge(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(GargantuaFonts.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}
