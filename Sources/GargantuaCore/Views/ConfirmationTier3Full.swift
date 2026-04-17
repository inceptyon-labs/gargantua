import SwiftUI

// MARK: - Tier 3: Full Modal

/// Protected items present — item-by-item acknowledgment required.
struct FullModalContent: View {
    let items: [ScanResult]
    let totalSize: Int64
    @Binding var cleanupMethod: CleanupMethod
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledgedIDs: Set<String> = []

    private var protectedItems: [ScanResult] {
        items.filter { $0.safety == .protected_ }
    }

    private var allProtectedAcknowledged: Bool {
        protectedItems.allSatisfy { acknowledgedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Confirm Cleanup")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Protected items require individual acknowledgment")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.protected_)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.top, GargantuaSpacing.space4)
            .padding(.bottom, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Scrollable item list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if item.safety == .protected_ {
                            AcknowledgeableItemRow(
                                item: item,
                                isAcknowledged: acknowledgedIDs.contains(item.id),
                                onToggle: { toggleAcknowledgment(item.id) }
                            )
                        } else {
                            ConfirmationItemRow(item: item)
                        }
                        if item.id != items.last?.id {
                            Rectangle()
                                .fill(GargantuaColors.borderSoft)
                                .frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)

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

                CleanupMethodPicker(selection: $cleanupMethod)

                if !allProtectedAcknowledged {
                    let remaining = protectedItems.count - acknowledgedIDs.count
                    Text("Acknowledge \(remaining) protected item\(remaining == 1 ? "" : "s") to continue")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ConfirmationButtons(
                    itemCount: items.count,
                    totalSize: totalSize,
                    cleanupMethod: cleanupMethod,
                    isEnabled: allProtectedAcknowledged,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
            .padding(GargantuaSpacing.space4)
        }
    }

    private func toggleAcknowledgment(_ id: String) {
        if acknowledgedIDs.contains(id) {
            acknowledgedIDs.remove(id)
        } else {
            acknowledgedIDs.insert(id)
        }
    }
}
