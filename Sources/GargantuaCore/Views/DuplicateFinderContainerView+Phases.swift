import Foundation
import SwiftUI

extension DuplicateFinderContainerView {
    var idleView: some View {
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

                    Text(idleSubtitle)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: GargantuaSpacing.space3) {
                    if state.cachedResults != nil {
                        Button(action: showCachedResults) {
                            Text("View previous results")
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink)
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.vertical, GargantuaSpacing.space2)
                                .background(
                                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                        .fill(GargantuaColors.accent)
                                )
                        }
                        .buttonStyle(.plain)

                        Button(action: startScan) {
                            Text("Scan again")
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink)
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.vertical, GargantuaSpacing.space2)
                                .background(
                                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                        .fill(GargantuaColors.surface3)
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: startScan) {
                            Text("Scan for duplicates")
                                .font(GargantuaFonts.label)
                                .foregroundStyle(GargantuaColors.ink)
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.vertical, GargantuaSpacing.space2)
                                .background(
                                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                        .fill(GargantuaColors.accent)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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

    var scanningView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Scanning for duplicates…")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if state.scanProgress.itemsFound > 0 {
                    Text("\(state.scanProgress.itemsFound) duplicate file\(state.scanProgress.itemsFound == 1 ? "" : "s") found so far")
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

    func errorView(_ message: String) -> some View {
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

            Button(action: startScan) {
                Text("Try again")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.surface3)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}
