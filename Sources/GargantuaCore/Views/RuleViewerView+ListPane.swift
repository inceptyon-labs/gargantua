import SwiftUI

extension RuleViewerView {
    var categoryAndRuleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(categories) { cat in
                        CategoryRow(
                            category: cat,
                            isSelected: selectedCategory == cat.name,
                            onSelect: {
                                selectedCategory = cat.name
                                selectedRuleID = nil
                            }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space4)

                if !selectedCategoryRules.isEmpty {
                    Rectangle()
                        .fill(GargantuaColors.border)
                        .frame(height: 1)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.bottom, GargantuaSpacing.space3)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(selectedCategoryRules, id: \.id) { rule in
                            RuleRow(
                                rule: rule,
                                isSelected: selectedRuleID == rule.id,
                                onSelect: { selectedRuleID = rule.id }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.bottom, GargantuaSpacing.space4)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(width: 1)
        }
    }
}
