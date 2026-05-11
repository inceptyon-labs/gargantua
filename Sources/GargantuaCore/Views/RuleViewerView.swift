import SwiftUI

private let communityRulesRepositoryURL = URL(string: "https://github.com/inceptyon-labs/gargantua-rules")!

/// Rule Viewer — browse cleanup rules by category with YAML display and exclusion management.
///
/// Three-column layout: category list (browser/developer/system) → rule list → rule detail.
/// Detail pane shows safety level, confidence, explanation, source, and raw YAML.
/// Bottom section manages the path exclusions persisted via SwiftData.
public struct RuleViewerView: View {
    let persistence: PersistenceController

    @State var categories: [RuleCategory] = []
    @State var selectedCategory: String?
    @State var selectedRuleID: String?
    @State var isLoading = true

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    var selectedCategoryRules: [ScanRule] {
        categories.first(where: { $0.name == selectedCategory })?.rules ?? []
    }

    var selectedRule: ScanRule? {
        selectedCategoryRules.first(where: { $0.id == selectedRuleID })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    categoryAndRuleList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task {
            await loadRules()
        }
    }

    private var headerView: some View {
        HStack {
            Text("Rules")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Link(destination: communityRulesRepositoryURL) {
                Label("Contribute Rules", systemImage: "arrow.up.right.square")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.accent)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .help("Open the public gargantua-rules repository")

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private func loadRules() async {
        isLoading = true
        let loader = RuleLoader()
        guard let rulesURL = RuleDirectoryResolver.resolve() else {
            isLoading = false
            return
        }

        do {
            let result = try loader.loadRules(from: rulesURL)
            let grouped = Dictionary(grouping: result.rules) { rule -> String in
                if rule.category.hasPrefix("browser") { return "browser" }
                if rule.category.hasPrefix("app") || rule.tags.contains("app") {
                    return "apps"
                }
                if rule.tags.contains("developer") || rule.category.hasPrefix("dev")
                    || rule.category.hasPrefix("build") || rule.category.hasPrefix("package") {
                    return "developer"
                }
                return "system"
            }

            categories = ["browser", "apps", "developer", "system"].compactMap { name in
                guard let rules = grouped[name], !rules.isEmpty else { return nil }
                return RuleCategory(name: name, rules: rules.sorted { $0.name < $1.name })
            }

            if selectedCategory == nil {
                selectedCategory = categories.first?.name
            }
        } catch {
            categories = []
        }
        isLoading = false
    }
}
