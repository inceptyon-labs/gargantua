import SwiftUI

// MARK: - Group Header

/// Collapsible header for a `ScanGroup`. Icon and any subtitle are driven by
/// `group.kind`, so safety-mode groups get a colored dot while folder/category
/// modes get an SF Symbol.
struct ScanGroupHeader: View {
    let group: ScanGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 12)

                leadingIcon

                Text(group.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)

                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("·")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink3)

                Text("\(group.count) items")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)

                Text("·")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink3)

                Text(AlertItem.formatBytes(group.totalSize))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch group.kind {
        case .safety(let level):
            Circle()
                .fill(safetyColor(level))
                .frame(width: 8, height: 8)
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 12)
        case .category:
            Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 12)
        }
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe:       return GargantuaColors.safe
        case .review:     return GargantuaColors.review
        case .protected_: return GargantuaColors.protected_
        }
    }
}

// MARK: - Grouping Mode Picker

/// Segmented-style picker used in the results toolbar to switch grouping.
struct ScanGroupingPicker: View {
    @Binding var mode: ScanGroupingMode

    var body: some View {
        Picker("Group by", selection: $mode) {
            ForEach(ScanGroupingMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 240)
    }
}
