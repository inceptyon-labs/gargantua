import AppKit
import SwiftUI

private let communityRulesRepositoryURL = URL(string: "https://github.com/inceptyon-labs/gargantua-rules")!

/// Rule Viewer — browse cleanup rules by category with YAML display and exclusion management.
///
/// Three-column layout: category list (browser/developer/system) → rule list → rule detail.
/// Detail pane shows safety level, confidence, explanation, source, and raw YAML.
/// Bottom section manages the path exclusions persisted via SwiftData.
public struct RuleViewerView: View {
    let persistence: PersistenceController
    /// Supplied by the app so the Rules screen can trigger the same Sparkle
    /// update check that ships new rules. `nil` in previews/standalone use.
    let updateSettingsViewModel: AppUpdateSettingsViewModel?

    @State var categories: [RuleCategory] = []
    @State var selectedCategory: String?
    @State var selectedRuleID: String?
    @State private var isLoading = true
    @State private var userRuleErrors: [String] = []
    /// Non-nil when the *bundled* rule set failed to load, as opposed to the
    /// per-file `userRuleErrors` from custom rules.
    @State private var bundledRuleLoadError: String?
    @State private var customRuleCount = 0

    public init(
        persistence: PersistenceController,
        updateSettingsViewModel: AppUpdateSettingsViewModel? = nil
    ) {
        self.persistence = persistence
        self.updateSettingsViewModel = updateSettingsViewModel
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
                AccretionDiskView(activityRate: 12, size: 36, color: GargantuaColors.accretion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let bundledRuleLoadError {
                ruleLoadFailureView(message: bundledRuleLoadError)
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

    private func ruleLoadFailureView(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(GargantuaColors.review)

            Text("Rules could not be loaded")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            GargantuaButton("Try Again", tone: .primary) {
                Task { await loadRules() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("Rules")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Button {
                    revealCustomRulesFolder()
                } label: {
                    Label("Custom Rules", systemImage: "folder.badge.plus")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.ink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .help("Open your user rules folder. Rules you add here load alongside the bundled set and survive updates.")

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
                    AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
                }
            }

            rulesCurrencyLine

            if customRuleCount > 0 || !userRuleErrors.isEmpty {
                customRulesStatusLine
            }
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    /// Passive provenance line: rules are bundled and reviewed per release, so
    /// new rules arrive with app updates. Wired to the same Sparkle check as the
    /// menu command rather than implying a live rule fetch.
    private var rulesCurrencyLine: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.safe)

            Text("Reviewed and bundled with this release. New rules arrive with app updates.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            if let updateSettingsViewModel {
                Button("Check for Updates") {
                    updateSettingsViewModel.userCheckForUpdates()
                }
                .buttonStyle(.plain)
                .font(GargantuaFonts.caption.weight(.semibold))
                .foregroundStyle(GargantuaColors.accent)
                .help("Check for a Gargantua update, which includes the latest reviewed rules")
            }
        }
    }

    /// Status line for user-authored rules: how many loaded, plus any parse
    /// errors so a malformed custom rule isn't silently swallowed.
    private var customRulesStatusLine: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if userRuleErrors.isEmpty {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(GargantuaColors.accent)
                Text("\(customRuleCount) custom rule\(customRuleCount == 1 ? "" : "s") loaded (clamped to review).")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(GargantuaColors.review)
                Text(userRuleErrors.first ?? "A custom rule failed to parse.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.review)
                    .help(userRuleErrors.joined(separator: "\n"))
                if userRuleErrors.count > 1 {
                    Text("(+\(userRuleErrors.count - 1) more)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }

    private func revealCustomRulesFolder() {
        let root = UserRuleDirectory.ensureScaffold()
        NSWorkspace.shared.open(root)
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
        bundledRuleLoadError = nil
        let loader = RuleLoader()
        guard let rulesURL = RuleDirectoryResolver.resolve() else {
            bundledRuleLoadError = "Gargantua could not locate its bundled rules directory."
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

            var built: [RuleCategory] = ["browser", "apps", "developer", "system"].compactMap { name in
                guard let rules = grouped[name], !rules.isEmpty else { return nil }
                return RuleCategory(name: name, rules: rules.sorted { $0.name < $1.name })
            }

            // User-authored cleanup rules — sanitized and shown as a distinct
            // category so they're visually separate from the reviewed bundle.
            let userLoad = (try? loader.loadRules(from: UserRuleDirectory.directory(for: .cleanup)))
                ?? RuleLoadResult(rules: [], errors: [], filesLoaded: 0)
            userRuleErrors = userLoad.errors.map(\.localizedDescription)
            if !userLoad.rules.isEmpty {
                let merged = UserRuleSanitizer.merge(
                    bundled: result.rules,
                    user: userLoad.rules,
                    sanitizing: UserRuleSanitizer.sanitize
                )
                let customRules = Array(merged.rules.suffix(merged.rules.count - result.rules.count))
                customRuleCount = customRules.count
                if !customRules.isEmpty {
                    built.append(RuleCategory(name: "custom", rules: customRules.sorted { $0.name < $1.name }))
                }
                if !merged.droppedIDs.isEmpty {
                    userRuleErrors.append(
                        "\(merged.droppedIDs.count) custom rule(s) ignored — id collides with a bundled rule."
                    )
                }
            } else {
                customRuleCount = 0
            }

            categories = built

            if selectedCategory == nil {
                selectedCategory = categories.first?.name
            }
        } catch {
            // An empty category list is how "no rules exist" renders, so a
            // load failure must say so explicitly — otherwise a broken bundle
            // looks like a product that simply ships no rules.
            categories = []
            bundledRuleLoadError = error.localizedDescription
        }
        isLoading = false
    }
}
