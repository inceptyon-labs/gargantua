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
                header(plan: plan)

                if plan.app.isRunning {
                    runningBanner(app: plan.app)
                }

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                        if let bundle = plan.appBundle {
                            bundleSection(bundle: bundle)
                        }

                        ForEach(orderedCategories(in: plan), id: \.self) { category in
                            categorySection(category: category, plan: plan)
                        }

                        protectedToggle(plan: plan)
                    }
                    .padding(GargantuaSpacing.space5)
                }

                footer(plan: plan)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Header

    private func header(plan: UninstallPlan) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink2)
                    .padding(GargantuaSpacing.space2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to apps")

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.app.displayName ?? plan.app.name)
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(plan.app.bundleID)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(AlertItem.formatBytes(plan.totalBytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Text("across \(plan.allItems.count) item\(plan.allItems.count == 1 ? "" : "s")")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    // MARK: - Running banner

    private func runningBanner(app: AppInfo) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.review)

            Text("\(app.displayName ?? app.name) is running — Gargantua will quit it before removing the bundle.")
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

    private func bundleSection(bundle: RemnantItem) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("Application Bundle")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .textCase(.uppercase)
                .tracking(0.8)

            RemnantRow(
                item: bundle,
                isSelected: viewModel.selectedIDs.contains(bundle.id),
                isLocked: bundle.safety == .protected_ && !viewModel.includeProtected,
                onToggle: { viewModel.toggleSelection(bundle) }
            )
        }
    }

    // MARK: - Category section

    private func categorySection(category: RemnantCategory, plan: UninstallPlan) -> some View {
        let items = plan.remnantsByCategory[category] ?? []
        let isCollapsed = collapsedCategories.contains(category)
        let selectedCount = items.filter { viewModel.selectedIDs.contains($0.id) }.count
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }

        return VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
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

                    categoryBulkAction(items: items, selectedCount: selectedCount)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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

    // MARK: - Protected toggle

    private func protectedToggle(plan: UninstallPlan) -> some View {
        let protectedItems = plan.allItems.filter { $0.safety == .protected_ }
        return Group {
            if !protectedItems.isEmpty {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: viewModel.includeProtected ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.protected_)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(protectedItems.count) protected item\(protectedItems.count == 1 ? "" : "s")")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)

                        Text("System-level files (launch daemons, helpers). Unlock to select them — you'll acknowledge each one before uninstall.")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { viewModel.includeProtected },
                            set: { viewModel.setIncludeProtected($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(GargantuaSpacing.space3)
                .background(GargantuaColors.protected_.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.protected_.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Footer

    private func footer(plan: UninstallPlan) -> some View {
        let selectedCount = viewModel.selectedIDs.count
        return VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            HStack(spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedCount) selected")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    Text(AlertItem.formatBytes(viewModel.selectedTotalBytes))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                }

                Spacer()

                Button(action: onBack) {
                    Text("Cancel")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .overlay(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .stroke(GargantuaColors.borderEm, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onUninstallTapped) {
                    Text(selectedCount == 1
                         ? "Uninstall 1 item"
                         : "Uninstall \(selectedCount) items")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .background(viewModel.canProceed ? GargantuaColors.protected_ : GargantuaColors.protected_.opacity(0.4))
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
}
