import SwiftUI

// MARK: - Tier 1: Single Button

/// All-safe selection - compact confirmation modal with cleanup method choice.
struct SafeCleanupConfirmationContent: View {
    let itemCount: Int
    let totalSize: Int64
    @Binding var cleanupMethod: CleanupMethod
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(GargantuaColors.safe)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to Clean")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text("Selected items are classified as safe.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                }

                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.top, GargantuaSpacing.space4)
            .padding(.bottom, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                TotalLine(
                    itemCount: itemCount,
                    totalSize: totalSize,
                    cleanupMethod: cleanupMethod
                )

                CleanupMethodPicker(selection: $cleanupMethod)

                ConfirmationButtons(
                    itemCount: itemCount,
                    totalSize: totalSize,
                    cleanupMethod: cleanupMethod,
                    isEnabled: itemCount > 0,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
            .padding(GargantuaSpacing.space4)
        }
    }
}

// MARK: - Cleanup Method Picker

struct CleanupMethodPicker: View {
    @Binding var selection: CleanupMethod

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("Cleanup Method")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .textCase(.uppercase)

            HStack(spacing: GargantuaSpacing.space2) {
                CleanupMethodOption(
                    method: .trash,
                    isSelected: selection == .trash,
                    onSelect: { selection = .trash }
                )

                CleanupMethodOption(
                    method: .delete,
                    isSelected: selection == .delete,
                    onSelect: { selection = .delete }
                )
            }

            if selection == .delete {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(GargantuaColors.protected_)

                    Text("Permanent deletion cannot be restored from Trash.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.protected_)
                }
            }
        }
    }
}

private struct CleanupMethodOption: View {
    let method: CleanupMethod
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                Image(systemName: method.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? method.accentColor : GargantuaColors.ink3)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayTitle)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(method.displayDetail)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(GargantuaSpacing.space3)
            .background(isSelected ? method.accentColor.opacity(0.12) : GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(isSelected ? method.accentColor : GargantuaColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
