import SwiftUI

// MARK: - Tier 1: Single Button

/// All-safe selection — simplified inline button, no modal.
///
/// Displays: "Clean 45 items (18.2 GB) · Move to Trash" as a single action.
struct SingleButtonConfirmation: View {
    let itemCount: Int
    let totalSize: Int64
    let onConfirm: () -> Void

    var body: some View {
        Button(action: onConfirm) {
            let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
            let sizeText = AlertItem.formatBytes(totalSize)

            Text("Clean \(countText) (\(sizeText)) · Move to Trash")
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.vertical, GargantuaSpacing.space2)
                .padding(.horizontal, GargantuaSpacing.space4)
                .background(GargantuaColors.safe)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
    }
}
