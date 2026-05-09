import SwiftUI

// MARK: - Item Rows

/// Standard item row: safety bar + name + path + size.
struct ConfirmationItemRow: View {
    let item: ScanResult

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.leading, 3)
        .background(safetyDimColor)
        // Safety bar overlays the leading edge so the row stays
        // intrinsic-height. As a sibling of the content HStack the bar's
        // greedy Rectangle would force the row to take any vertical space
        // the parent proposed, which made unscrolled lists divide the
        // modal height equally between rows.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(safetyColor)
                .frame(width: 3)
        }
    }

    private var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private var safetyDimColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe.opacity(0.12)
        case .review: GargantuaColors.review.opacity(0.12)
        case .protected_: GargantuaColors.protected_.opacity(0.12)
        }
    }
}

/// Protected item row with acknowledgment checkbox.
struct AcknowledgeableItemRow: View {
    let item: ScanResult
    let isAcknowledged: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            // Acknowledgment checkbox
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isAcknowledged ? GargantuaColors.protected_ : GargantuaColors.borderEm,
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                        .background(
                            isAcknowledged
                                ? GargantuaColors.protected_
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if isAcknowledged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.safety == .protected_, !item.explanation.isEmpty {
                    Text(item.explanation)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.protected_)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.leading, 3)
        .background(GargantuaColors.protected_.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(GargantuaColors.protected_)
                .frame(width: 3)
        }
    }
}
