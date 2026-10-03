import SwiftUI

extension RuleViewerView {
    var categoryAndRuleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneSearchField(placeholder: "Search rules", text: $ruleSearchQuery)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space3)

            if let matches = searchMatches {
                searchResultList(matches)
            } else {
                categoryBrowser
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

    private func searchResultList(_ matches: [ScanRule]) -> some View {
        ScrollView {
            if matches.isEmpty {
                Text("No rules match.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .padding(GargantuaSpacing.space4)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches, id: \.id) { rule in
                        RuleRow(
                            rule: rule,
                            isSelected: selectedRuleID == rule.id,
                            onSelect: {
                                selectedCategory = rule.category
                                selectedRuleID = rule.id
                            }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space4)
            }
        }
    }

    private var categoryBrowser: some View {
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
}
