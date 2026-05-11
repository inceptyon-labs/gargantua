import SwiftUI

// MARK: - Duplicate File Row

/// Row tuned for the duplicate finder: differentiating path slice up front,
/// original filename + tilde-collapsed full path as secondary context. We skip
/// the per-row size badge (every file in a group is identical) and the per-row
/// explanation (the group header carries one explainer for the whole pile).
struct DuplicateFileRow: View {
    let item: ScanResult
    let differentiator: String
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onExplain: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

            Button(action: onToggleSelection) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? safetyColor : GargantuaColors.borderEm,
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                        .background(isSelected ? safetyColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(differentiator)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: GargantuaSpacing.space1) {
                    if differentiator != item.name {
                        Text(item.name)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("·")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }

                    Text(tildeCollapsed(item.path))
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isHovered, onExplain != nil {
                Button(action: onExplain ?? {}) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Show explanation")
            } else if onExplain != nil {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
            }
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(safetyDimColor)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .onHover { isHovered = $0 }
        .help(item.path)
    }

    private var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private var safetyDimColor: Color {
        // Halved from 0.12 so the header's `surface1` wins the contrast
        // competition; the safety hint is still legible on the row.
        switch item.safety {
        case .safe: GargantuaColors.safe.opacity(0.06)
        case .review: GargantuaColors.review.opacity(0.06)
        case .protected_: GargantuaColors.protected_.opacity(0.06)
        }
    }

    private func tildeCollapsed(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
