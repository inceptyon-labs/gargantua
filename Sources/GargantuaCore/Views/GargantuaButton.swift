import SwiftUI

/// Unified button for the settings pane and trust-layer surfaces.
///
/// Replaces the per-section `actionButton`, `cloudActionButton`, `agentSettingsButton`,
/// `transportActionButton`, and `ScanRootIconButton` reimplementations so primary,
/// neutral, destructive, and ghost intents have one visual contract.
struct GargantuaButton: View {
    enum Tone: Equatable {
        /// Solid Hawking Blue fill, ink text. The page's prominent CTA.
        case primary
        /// Surface-3 fill with Border-Em stroke. Inline neutral action.
        case neutral
        /// Solid Red Ember fill. Confirm-sheet primary only — never an inline list row.
        case destructive
        /// Translucent tinted fill (`color.opacity(0.12)`) with the color as text.
        /// Intended for inline list rows where the action is one of several peers.
        case ghost(Color)
    }

    let label: String
    let icon: String?
    let tone: Tone
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ label: String,
        icon: String? = nil,
        tone: Tone = .neutral,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                }
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var foregroundColor: Color {
        if isDisabled { return GargantuaColors.ink4 }
        switch tone {
        case .primary, .destructive:
            return GargantuaColors.ink
        case .neutral:
            return GargantuaColors.ink
        case .ghost(let color):
            return color
        }
    }

    private var backgroundColor: Color {
        if isDisabled { return GargantuaColors.surface2 }
        switch tone {
        case .primary:
            return GargantuaColors.accent
        case .neutral:
            return GargantuaColors.surface3
        case .destructive:
            return GargantuaColors.protected_
        case .ghost(let color):
            return color.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .neutral: return GargantuaColors.borderEm
        default: return .clear
        }
    }

    private var strokeWidth: CGFloat {
        tone == .neutral ? 1 : 0
    }
}

/// Compact icon-only ghost button used in dense list rows.
///
/// Replaces `ScanRootIconButton` and the bare `Button { Image(...) }` patterns
/// scattered across the settings sections.
struct GargantuaIconButton: View {
    let icon: String
    let help: String
    var color: Color = GargantuaColors.ink2
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDisabled ? GargantuaColors.ink4 : color)
                .frame(width: 26, height: 24)
                .background((isDisabled ? GargantuaColors.ink4 : color).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}
