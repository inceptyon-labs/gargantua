import SwiftUI

// MARK: - Tier 2: Summary Dialog

/// Mixed safe + review selection — lists review items explicitly.
struct SummaryDialogContent: View {
    let items: [ScanResult]
    let totalSize: Int64
    let allowsPermanentDelete: Bool
    @Binding var cleanupMethod: CleanupMethod
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var reviewItems: [ScanResult] {
        items.filter { $0.safety == .review }
    }

    private var safeItems: [ScanResult] {
        items.filter { $0.safety == .safe }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Confirm Cleanup")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.top, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space3)

            // Safe items summary
            if !safeItems.isEmpty {
                let safeSize = safeItems.reduce(Int64(0)) { $0 + $1.size }
                let safeCount = safeItems.count == 1 ? "1 safe item" : "\(safeItems.count) safe items"

                HStack(spacing: GargantuaSpacing.space2) {
                    Circle()
                        .fill(GargantuaColors.safe)
                        .frame(width: 6, height: 6)
                    Text("\(safeCount) (\(AlertItem.formatBytes(safeSize)))")
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space3)
            }

            // Review items — listed explicitly
            if !reviewItems.isEmpty {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Circle()
                            .fill(GargantuaColors.review)
                            .frame(width: 6, height: 6)
                        Text(reviewItems.count == 1 ? "1 item needs review:" : "\(reviewItems.count) items need review:")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.review)
                    }
                    .padding(.horizontal, GargantuaSpacing.space4)

                    reviewItemList
                }
                .padding(.bottom, GargantuaSpacing.space3)
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Total + buttons
            VStack(spacing: GargantuaSpacing.space3) {
                TotalLine(
                    itemCount: items.count,
                    totalSize: totalSize,
                    cleanupMethod: cleanupMethod
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if allowsPermanentDelete {
                    CleanupMethodPicker(selection: $cleanupMethod)
                }

                ConfirmationButtons(
                    itemCount: items.count,
                    totalSize: totalSize,
                    cleanupMethod: cleanupMethod,
                    isEnabled: true,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
            .padding(GargantuaSpacing.space4)
        }
    }

    @ViewBuilder
    private var reviewItemList: some View {
        let listContent = VStack(spacing: 0) {
            ForEach(reviewItems) { item in
                ConfirmationItemRow(item: item)
                if item.id != reviewItems.last?.id {
                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(height: 1)
                }
            }
        }

        if reviewItems.count > 10 {
            ScrollView {
                listContent
            }
            .frame(maxHeight: 300)
        } else {
            listContent
        }
    }
}
