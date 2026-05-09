import SwiftUI

/// Confirmation sheet for a Background Item mutation.
///
/// Single-button (`.safe`), summary dialog (`.review`), and full modal
/// (`.protected_`) UX collapse into one view because the visual primitives are
/// the same — the title weight, the secondary copy, and the destructive-tier
/// styling differ but the form factor stays consistent. The view is a leaf;
/// state lives in `BackgroundItemsView`.
public struct BackgroundItemActionConfirmation: View {
    public let item: BackgroundItem
    public let action: BackgroundItemAction
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    public init(
        item: BackgroundItem,
        action: BackgroundItemAction,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.action = action
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            header

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text(item.displayName)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(item.label)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
                Text(item.source.displayLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(GargantuaSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.surface2)
            }

            if let secondary = secondaryCopy {
                Text(secondary)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }

            HStack(spacing: GargantuaSpacing.space2) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .tint(actionTint)
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(width: 420)
        .background(GargantuaColors.surface1)
    }

    // MARK: - Copy

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: actionSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(actionTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text(subtitle)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
        }
    }

    private var title: String {
        switch action {
        case .disable: "Disable this background item?"
        case .enable: "Re-enable this background item?"
        case .delete: "Move this background item's plist to the Trash?"
        }
    }

    private var subtitle: String {
        switch action {
        case .disable, .enable: "Recorded to the audit log."
        case .delete: "Recoverable from Trash and the audit log."
        }
    }

    private var secondaryCopy: String? {
        switch action {
        case .disable:
            "It will stop running and won't load again until you re-enable it."
        case .enable:
            "It will be allowed to run and reloaded from its plist."
        case .delete:
            "Disable must run first. The plist goes to the Trash, not deleted permanently."
        }
    }

    private var actionLabel: String {
        switch action {
        case .disable: "Disable"
        case .enable: "Re-enable"
        case .delete: "Move to Trash"
        }
    }

    private var actionSymbol: String {
        switch action {
        case .disable: "pause.circle.fill"
        case .enable: "play.circle.fill"
        case .delete: "trash.fill"
        }
    }

    private var actionTint: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}
