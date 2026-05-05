import SwiftUI

/// Plan review step of the Smart Uninstaller flow.
///
/// Shows the app bundle first, then remnants grouped by category. Each item
/// row has a safety-colored left border, checkbox, path, size, and a short
/// explanation. Running apps surface a warning banner at the top; protected
/// items are locked behind an explicit "Show protected" toggle that the user
/// must opt into before they can be selected.
struct UninstallPlanReviewView: View {
    @Bindable var viewModel: SmartUninstallerViewModel
    let onUninstallTapped: () -> Void
    let onBack: () -> Void

    @State private var collapsedCategories: Set<RemnantCategory> = []

    private var plan: UninstallPlan? { viewModel.currentPlan }

    var body: some View {
        if let plan {
            VStack(spacing: 0) {
                ScanResultsHeader(
                    title: plan.app.displayName ?? plan.app.name,
                    subtitle: headerSubtitle(plan: plan),
                    onBack: onBack
                )

                if plan.app.isRunning, isAppBundleSelected(plan: plan) {
                    runningBanner(app: plan.app)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                        if let bundle = plan.appBundle {
                            bundleSection(bundle: bundle)
                        }

                        ForEach(orderedCategories(in: plan), id: \.self) { category in
                            categorySection(category: category, plan: plan)
                        }

                        ProtectedItemsTogglePanel(viewModel: viewModel, plan: plan)
                    }
                    .padding(GargantuaSpacing.space5)
                }

                footer(plan: plan)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Header subtitle

    /// Bundle ID with the plan totals folded in. Replaces the standalone stats
    /// bar — the subtitle slot already exists, and the totals are scaffolding,
    /// not a primary metric.
    private func headerSubtitle(plan: UninstallPlan) -> String {
        let bytes = AlertItem.formatBytes(plan.totalBytes)
        let count = plan.allItems.count
        let items = "\(count) item\(count == 1 ? "" : "s")"
        let bundleID = plan.app.bundleID
        if !bundleID.isEmpty {
            return "\(bundleID)  ·  \(bytes) across \(items)"
        }
        return "\(bytes) across \(items)"
    }

    // MARK: - Running banner

    private func runningBanner(app: AppInfo) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.review)

            Text("\(app.displayName ?? app.name) is running. Gargantua will quit it before removing the bundle.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.review)

            Spacer()
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space5)
        .background(GargantuaColors.review.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(app.displayName ?? app.name) is running and will be quit.")
    }

    // MARK: - Bundle section

    /// The application bundle row sits at the top of the scroll, before any
    /// remnant categories. A trailing hairline divider separates it from the
    /// first category section so the bundle reads as primary, not as a stray
    /// row in some unnamed group.
    private func bundleSection(bundle: RemnantItem) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            RemnantRow(
                item: bundle,
                isSelected: viewModel.selectedIDs.contains(bundle.id),
                isLocked: bundle.safety == .protected_ && !viewModel.includeProtected,
                onToggle: { viewModel.toggleSelection(bundle) }
            )

            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
        }
    }

    // MARK: - Category section

    private func categorySection(category: RemnantCategory, plan: UninstallPlan) -> some View {
        let items = plan.remnantsByCategory[category] ?? []
        let isCollapsed = collapsedCategories.contains(category)
        let selectedCount = items.filter { viewModel.selectedIDs.contains($0.id) }.count
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }

        return VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Button {
                    if isCollapsed {
                        collapsedCategories.remove(category)
                    } else {
                        collapsedCategories.insert(category)
                    }
                } label: {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(GargantuaColors.ink3)
                            .frame(width: 10)

                        Text(category.displayLabel)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text("\(selectedCount) of \(items.count) · \(AlertItem.formatBytes(totalBytes))")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                categoryBulkAction(items: items, selectedCount: selectedCount)
            }

            if !isCollapsed {
                VStack(spacing: GargantuaSpacing.space1) {
                    ForEach(items) { item in
                        RemnantRow(
                            item: item,
                            isSelected: viewModel.selectedIDs.contains(item.id),
                            isLocked: item.safety == .protected_ && !viewModel.includeProtected,
                            onToggle: { viewModel.toggleSelection(item) }
                        )
                    }
                }
            }
        }
    }

    private func categoryBulkAction(items: [RemnantItem], selectedCount: Int) -> some View {
        let actionable = items.filter { $0.safety.isActionable || ($0.safety == .protected_ && viewModel.includeProtected) }
        let allSelected = !actionable.isEmpty && actionable.allSatisfy { viewModel.selectedIDs.contains($0.id) }

        return Button {
            if allSelected {
                viewModel.deselectAll(in: items)
            } else {
                viewModel.selectAll(in: items)
            }
        } label: {
            Text(allSelected ? "Deselect all" : "Select all")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .disabled(actionable.isEmpty)
    }

    // MARK: - Footer

    private func footer(plan: UninstallPlan) -> some View {
        let selectedCount = viewModel.selectedIDs.count
        return VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack(spacing: GargantuaSpacing.space3) {
                Text("\(AlertItem.formatBytes(viewModel.selectedTotalBytes)) selected")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                Button(action: onBack) {
                    Text("Cancel")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .background(GargantuaColors.surface3)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)

                Button(action: onUninstallTapped) {
                    Text(selectedCount == 1
                        ? "Uninstall 1 item"
                        : "Uninstall \(selectedCount) items")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .background(viewModel.canProceed ? GargantuaColors.accent : GargantuaColors.accent.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canProceed)
            }
            .padding(.horizontal, GargantuaSpacing.space5)
            .padding(.vertical, GargantuaSpacing.space3)
        }
    }

    // MARK: - Helpers

    /// Category order matches `RemnantCategory.allCases` so the UI stays
    /// deterministic between scans.
    private func orderedCategories(in plan: UninstallPlan) -> [RemnantCategory] {
        let present = Set(plan.remnants.map(\.category))
        return RemnantCategory.allCases.filter { present.contains($0) }
    }

    /// True when the app bundle itself is selected — i.e. we'll actually
    /// need to quit the running process before uninstall.
    private func isAppBundleSelected(plan: UninstallPlan) -> Bool {
        guard let bundleID = plan.appBundle?.id else { return false }
        return viewModel.selectedIDs.contains(bundleID)
    }
}
