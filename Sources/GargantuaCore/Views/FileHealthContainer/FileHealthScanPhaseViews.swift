import Foundation
import SwiftUI

private let fileHealthSubtitlePool: [String] = [
    "Tracing duplicate file signatures",
    "Scanning for broken symlinks",
    "Cataloguing empty directories",
    "Comparing visual fingerprints",
    "Probing extension anomalies",
    "Measuring oversized file mass",
    "Detecting corrupted archives",
    "Mapping file health topology",
    "Cross-referencing checksum manifests",
    "Surveying orphaned fragments",
    "Analyzing entropy distributions",
    "Charting the debris field",
]

struct FileHealthIdleView: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "File Health",
                subtitle: "Cluster the redundancies. Surface what's broken.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "file-health-gargantua-gpt2",
                    fallbackSystemName: "stethoscope",
                    fallbackColor: GargantuaColors.ink4
                )

                VStack(spacing: GargantuaSpacing.space2) {
                    Text("Audit file health")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(
                        "Runs czkawka across your scan roots to surface empty, broken, temporary, oversized, "
                            + "and visually similar files. Review-by-default: nothing is selected automatically."
                    )
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                }

                Button(action: onScan) {
                    Text("Scan file health")
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

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FileHealthScanningView: View {
    let progress: ScanProgress
    let scanRootCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            consoleHeader
            consoleSubtitle

            if progress.fractionCompleted > 0 {
                progressBar
            }

            if let path = progress.currentPath {
                Text(abbreviatedPath(path))
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            Spacer()

            HStack(spacing: GargantuaSpacing.space5) {
                Text("SCAN ROOTS: \(scanRootCount)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Text("CATEGORIES: \(CzkawkaCategory.allCases.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: progress.currentPath)
        .animation(.easeInOut(duration: 0.3), value: progress.fractionCompleted > 0)
    }

    private var consoleHeader: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("ENDURANCE · FILE HEALTH AUDIT")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(2)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
                AccretionDiskView(activityRate: 20)
            }

            HStack(spacing: GargantuaSpacing.space5) {
                if let cat = progress.currentCategory {
                    Text("CATEGORY: \(prettifiedCategory(cat))")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)
                        .animation(.none, value: cat)
                } else {
                    Text("CATEGORY: initializing")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                }

                if progress.itemsFound > 0 {
                    Text("ITEMS FOUND: \(progress.itemsFound)")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.accretion)
                        .transition(.opacity)
                }
            }

            Text("[TARS] Humor: 75% · Honesty: 90% · Pragmatism: 100%")
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private var consoleSubtitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: 20, size: 11)
            rotatingSubtitle
            scanEllipsis
        }
    }

    @ViewBuilder
    private var rotatingSubtitle: some View {
        if reduceMotion {
            Text(fileHealthSubtitlePool[0])
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
        } else {
            TimelineView(.periodic(from: .now, by: 4.0)) { tlContext in
                let step = Int(tlContext.date.timeIntervalSinceReferenceDate / 4.0) % fileHealthSubtitlePool.count
                Text(fileHealthSubtitlePool[step])
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .id(step)
                    .animation(.easeInOut(duration: 0.5), value: step)
            }
        }
    }

    @ViewBuilder
    private var scanEllipsis: some View {
        if reduceMotion {
            Text("…")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.45)) { tlContext in
                let step = Int(tlContext.date.timeIntervalSinceReferenceDate / 0.45) % 3
                Text(String(repeating: ".", count: step + 1))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GargantuaColors.surface3)
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(GargantuaColors.accretion)
                    .frame(width: max(0, geo.size.width * progress.fractionCompleted), height: 3)
                    .animation(.linear(duration: 0.3), value: progress.fractionCompleted)
            }
        }
        .frame(height: 3)
    }
}

struct FileHealthErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.review)

            Text("File Health scan unavailable")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(action: onRetry) {
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

private func prettifiedCategory(_ raw: String) -> String {
    raw.split(separator: "_")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
    if path == home { return "~" }
    return path
}
