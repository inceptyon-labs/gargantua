import Foundation
import SwiftUI

// MARK: - Idle

struct DuplicateFinderIdleView: View {
    let subtitle: String
    let hasCachedResults: Bool
    let onShowCachedResults: () -> Void
    let onStartScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Duplicate Finder",
                subtitle: "Group duplicate bytes across your filesystem.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "duplicates-gargantua-gpt2",
                    fallbackSystemName: "doc.on.doc",
                    fallbackColor: GargantuaColors.ink4
                )

                VStack(spacing: GargantuaSpacing.space2) {
                    Text("Find duplicate files")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(subtitle)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: GargantuaSpacing.space4) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "number")
                            .font(.system(size: 11))
                            .foregroundStyle(GargantuaColors.ink4)
                        Text("Hash-grouped")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(GargantuaColors.ink4)
                        Text("fclones engine")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                }

                HStack(spacing: GargantuaSpacing.space3) {
                    if hasCachedResults {
                        GargantuaButton("View previous results", tone: .primary, action: onShowCachedResults)
                        GargantuaButton("Scan again", tone: .neutral, action: onStartScan)
                    } else {
                        GargantuaButton("Scan for duplicates", tone: .primary, action: onStartScan)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Scanning

struct DuplicateFinderScanningView: View {
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Scanning for duplicates…")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if progress.itemsFound > 0 {
                    Text("\(progress.itemsFound) duplicate file\(progress.itemsFound == 1 ? "" : "s") found so far")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                } else {
                    Text("fclones is walking your scan roots. Large trees can take a few minutes.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }
}

// MARK: - Error

struct DuplicateFinderErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.review)

            Text("Scan unavailable")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            GargantuaButton("Try again", tone: .neutral, action: onRetry)
        }
    }
}

// MARK: - Helpers

extension DuplicateFinderContainerView {
    var idleSubtitle: String {
        guard let cached = state.cachedResults, let when = state.cachedAt else {
            return "Runs `fclones group` across your scan roots. Review-by-default — nothing is selected automatically."
        }
        let groups = DuplicateGrouper.group(cached).count
        let files = cached.count
        return "Last scan \(relativeTime(since: when)): \(groups) group\(groups == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")."
    }

    func relativeTime(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
