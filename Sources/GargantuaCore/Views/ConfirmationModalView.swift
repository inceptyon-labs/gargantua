import SwiftUI

// MARK: - Tier Determination

/// Determines the required confirmation tier from a set of selected scan results.
///
/// The tier scales with the highest-risk item in the selection:
/// - All safe -> `.singleButton` (compact confirmation)
/// - Any review items -> `.summaryDialog` (list review items explicitly)
/// - Any protected items -> `.fullModal` (item-by-item acknowledgment)
public func confirmationTier(for items: [ScanResult]) -> ConfirmationTier {
    if items.contains(where: { $0.safety == .protected_ }) { return .fullModal }
    if items.contains(where: { $0.safety == .review }) { return .summaryDialog }
    return .singleButton
}

// MARK: - Confirmation Modal

/// Three-tier confirmation view that scales UX complexity with cleanup risk.
///
/// Routes to the appropriate confirmation variant based on the safety levels
/// of the selected items.
public struct ConfirmationModalView: View {
    let items: [ScanResult]
    let onConfirm: (CleanupMethod) -> Void
    let onCancel: () -> Void

    @State private var cleanupMethod: CleanupMethod = .trash

    public init(
        items: [ScanResult],
        onConfirm: @escaping (CleanupMethod) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.items = items
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var tier: ConfirmationTier {
        confirmationTier(for: items)
    }

    private var totalSize: Int64 {
        items.reduce(Int64(0)) { $0 + $1.size }
    }

    public var body: some View {
        switch tier {
        case .singleButton:
            ModalChrome(onCancel: onCancel) {
                SafeCleanupConfirmationContent(
                    itemCount: items.count,
                    totalSize: totalSize,
                    cleanupMethod: $cleanupMethod,
                    onConfirm: { onConfirm(cleanupMethod) },
                    onCancel: onCancel
                )
            }
        case .summaryDialog:
            ModalChrome(onCancel: onCancel) {
                SummaryDialogContent(
                    items: items,
                    totalSize: totalSize,
                    cleanupMethod: $cleanupMethod,
                    onConfirm: { onConfirm(cleanupMethod) },
                    onCancel: onCancel
                )
            }
        case .fullModal:
            ModalChrome(onCancel: onCancel) {
                FullModalContent(
                    items: items,
                    totalSize: totalSize,
                    cleanupMethod: $cleanupMethod,
                    onConfirm: { onConfirm(cleanupMethod) },
                    onCancel: onCancel
                )
            }
        }
    }
}

// MARK: - Shared: Total Line

/// Formats the total line: "Clean 45 items (18.2 GB) - Move to Trash"
struct TotalLine: View {
    let itemCount: Int
    let totalSize: Int64
    let cleanupMethod: CleanupMethod

    var body: some View {
        Text(cleanupTotalLineText(itemCount: itemCount, totalSize: totalSize, method: cleanupMethod))
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.ink2)
    }
}

// MARK: - Shared: Modal Chrome

/// Dark scrim overlay + centered surface-3 card. Wraps modal content.
struct ModalChrome<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            // Scrim — click to cancel
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            // Modal card
            content
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.large)
                        .stroke(GargantuaColors.border, lineWidth: 1)
                )
                .frame(maxWidth: 480)
                .padding(GargantuaSpacing.space6)
        }
        .onExitCommand(perform: onCancel)
    }
}

// MARK: - Shared: Action Buttons

/// Cancel (ghost) + destructive confirm button pair.
struct ConfirmationButtons: View {
    let itemCount: Int
    let totalSize: Int64
    let cleanupMethod: CleanupMethod
    let isEnabled: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            // Cancel — ghost button, visually dominant escape
            Button(action: onCancel) {
                Text("Cancel")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(GargantuaColors.borderEm, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // Destructive confirm
            Button(action: onConfirm) {
                let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
                let sizeText = AlertItem.formatBytes(totalSize)

                Text("\(cleanupMethod.actionTitle) \(countText) (\(sizeText))")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        isEnabled ? cleanupMethod.accentColor : cleanupMethod.accentColor.opacity(0.4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }
}
