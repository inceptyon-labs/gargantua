import SwiftUI

// MARK: - Tier Determination

/// Determines the required confirmation tier from a set of selected scan results.
///
/// The tier scales with the highest-risk item in the selection:
/// - All safe → `.singleButton` (skip modal entirely)
/// - Any review items → `.summaryDialog` (list review items explicitly)
/// - Any protected items → `.fullModal` (item-by-item acknowledgment)
public func confirmationTier(for items: [ScanResult]) -> ConfirmationTier {
    if items.contains(where: { $0.safety == .protected_ }) { return .fullModal }
    if items.contains(where: { $0.safety == .review }) { return .summaryDialog }
    return .singleButton
}

// MARK: - Confirmation Modal

/// Three-tier confirmation view that scales UX complexity with cleanup risk.
///
/// Routes to the appropriate confirmation variant based on the safety levels
/// of the selected items. Designed as a modal overlay (`.fullModal`, `.summaryDialog`)
/// or an inline action (`.singleButton`).
public struct ConfirmationModalView: View {
    let items: [ScanResult]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(
        items: [ScanResult],
        onConfirm: @escaping () -> Void,
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
            SingleButtonConfirmation(
                itemCount: items.count,
                totalSize: totalSize,
                onConfirm: onConfirm
            )
        case .summaryDialog:
            ModalChrome(onCancel: onCancel) {
                SummaryDialogContent(
                    items: items,
                    totalSize: totalSize,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
        case .fullModal:
            ModalChrome(onCancel: onCancel) {
                FullModalContent(
                    items: items,
                    totalSize: totalSize,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
        }
    }
}

// MARK: - Shared: Total Line

/// Formats the total line: "Clean 45 items (18.2 GB) · Move to Trash"
struct TotalLine: View {
    let itemCount: Int
    let totalSize: Int64

    var body: some View {
        let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
        let sizeText = AlertItem.formatBytes(totalSize)

        Text("Clean \(countText) (\(sizeText)) · Move to Trash")
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

                Text("Clean \(countText) (\(sizeText))")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        isEnabled ? GargantuaColors.protected_ : GargantuaColors.protected_.opacity(0.4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }
}

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

// MARK: - Tier 2: Summary Dialog

/// Mixed safe + review selection — lists review items explicitly.
struct SummaryDialogContent: View {
    let items: [ScanResult]
    let totalSize: Int64
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
                TotalLine(itemCount: items.count, totalSize: totalSize)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ConfirmationButtons(
                    itemCount: items.count,
                    totalSize: totalSize,
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

// MARK: - Tier 3: Full Modal

/// Protected items present — item-by-item acknowledgment required.
struct FullModalContent: View {
    let items: [ScanResult]
    let totalSize: Int64
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
                TotalLine(itemCount: items.count, totalSize: totalSize)
                    .frame(maxWidth: .infinity, alignment: .leading)

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

// MARK: - Item Rows

/// Standard item row: safety bar + name + path + size.
struct ConfirmationItemRow: View {
    let item: ScanResult

    var body: some View {
        HStack(spacing: 0) {
            // Safety classification bar (3px left accent)
            Rectangle()
                .fill(safetyColor)
                .frame(width: 3)

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
        }
        .background(safetyDimColor)
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
        HStack(spacing: 0) {
            // Safety classification bar
            Rectangle()
                .fill(GargantuaColors.protected_)
                .frame(width: 3)

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
                }

                Spacer()

                Text(AlertItem.formatBytes(item.size))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, GargantuaSpacing.space3)
        }
        .background(GargantuaColors.protected_.opacity(0.12))
    }
}
