import SwiftUI

/// Two-tab row sitting between the Deep Clean header and the results
/// content. Lets the user pivot from the existing Clean view (bucketed
/// scan results) to the AI Organize view (file-organization proposals)
/// without leaving DeepClean.
public enum DeepCleanResultsTab: String, CaseIterable, Identifiable, Sendable {
    case clean
    case organize

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .clean: "Clean"
        case .organize: "Organize"
        }
    }

    public var systemImage: String {
        switch self {
        case .clean: "bubbles.and.sparkles"
        case .organize: "folder.badge.gearshape"
        }
    }
}

struct DeepCleanResultsTabBar: View {
    @Binding var selection: DeepCleanResultsTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: GargantuaSpacing.space1) {
                ForEach(DeepCleanResultsTab.allCases) { tab in
                    tabChip(tab)
                }
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface1)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    private func tabChip(_ tab: DeepCleanResultsTab) -> some View {
        let isSelected = selection == tab
        return Button(tab.label) { selection = tab }
            .buttonStyle(.plain)
            .font(GargantuaFonts.label)
            .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink3)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(isSelected ? GargantuaColors.surface3 : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(
                        isSelected ? GargantuaColors.border : Color.clear,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}
