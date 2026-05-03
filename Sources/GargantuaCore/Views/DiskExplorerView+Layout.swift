import Foundation
import SwiftUI

extension DiskExplorerView {
    /// Invisible Buttons that carry `.keyboardShortcut` for Disk Explorer
    /// internal navigation. Placed in `.background` of the resultsView so
    /// they fire only while the resultsView is in the active focus context.
    /// All actions route through `state` directly so this can live in an
    /// extension across files without bumping access on the view's private
    /// helpers.
    @ViewBuilder
    var keyboardShortcutLayer: some View {
        HStack(spacing: 0) {
            Button("Back") { state.exitToIdle() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Up") {
                guard state.pathStack.count > 1 else { return }
                state.navigateTo(index: state.pathStack.count - 2)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state.pathStack.count <= 1)
            Button("Refresh") { state.refreshCurrent() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isLoading)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    var permissionBanner: some View {
        if state.items.contains(where: { $0.isPermissionDenied }) {
            PermissionBannerView.fullDiskAccess
                .padding(.horizontal, GargantuaSpacing.space6)
                .padding(.bottom, GargantuaSpacing.space3)
        }
    }

    /// Skip the Rescan confirmation when the user is already at home — the
    /// only thing Rescan does in that case is re-run the scan, which Refresh
    /// already does without ceremony.
    func requestRescan() {
        if state.pathStack.count > 1 {
            state.showRescanConfirmation = true
        } else {
            state.rescanFromHome()
        }
    }

    var scanningView: some View {
        let primary = loadingMessage
        let folderName = state.pathStack.last?.name ?? "Home"
        return VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Mapping \(folderName)")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(primary)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, GargantuaSpacing.space6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning \(folderName), \(primary)")
    }

    var emptyState: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: 0, size: 28, color: GargantuaColors.ink3)
                .opacity(0.4)

            Text("Empty orbit")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("No bodies detected at this radius.")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, GargantuaSpacing.space6)
    }
}

extension DiskExplorerView {
    /// Bundle directories whose size is < 1% of the largest into a single
    /// synthetic "Others" tile. Avoids the ant-farm of unidentifiable
    /// 60×60-pixel icons that plague treemaps of skewed distributions.
    ///
    /// Skipped entirely for small directories — when fewer than 12 sized
    /// items would land in the treemap, every folder gets a legible tile
    /// without the rollup. The threshold matches the rule of thumb that
    /// 12 squarified tiles in a typical viewport stay above ~80×60pt
    /// where labels remain readable.
    static func collapseSmall(_ items: [DirectoryItem]) -> [DirectoryItem] {
        let sized = items.filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
        guard sized.count >= 12 else { return items }
        guard let largest = sized.map(\.size).max(), largest > 0 else { return items }

        let threshold = max(largest / 100, 1)
        var kept: [DirectoryItem] = []
        var aggregated: [DirectoryItem] = []

        for item in items {
            if item.isPermissionDenied || item.isSizing || item.isFilesAggregate {
                kept.append(item)
                continue
            }
            if item.size < threshold {
                aggregated.append(item)
            } else {
                kept.append(item)
            }
        }

        // Only collapse when it's worth it — a single small item gets a normal
        // tile rather than a misleading "Others (1)" wrapper.
        guard aggregated.count >= 2 else { return items }

        let totalSize = aggregated.reduce(0) { $0 + $1.size }
        let aggregateName = "Others (\(aggregated.count))"
        let parentPath = aggregated.first?.path
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/") ?? ""
        let aggregatePath = "/\(parentPath)#others"
        kept.append(DirectoryItem(
            name: aggregateName,
            path: aggregatePath,
            size: totalSize,
            isOthersAggregate: true
        ))
        return kept
    }
}
