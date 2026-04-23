import SwiftUI

enum AIModalButtonTone {
    case accent
    case secondary
}

struct AIModalButtonStyle: ButtonStyle {
    let tone: AIModalButtonTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GargantuaFonts.label)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                    .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous))
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent:
            return GargantuaColors.accent
        case .secondary:
            return GargantuaColors.ink2
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch tone {
        case .accent:
            return GargantuaColors.accent.opacity(isPressed ? 0.12 : 0.08)
        case .secondary:
            return GargantuaColors.surface2.opacity(isPressed ? 0.92 : 0.72)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        switch tone {
        case .accent:
            return GargantuaColors.accent.opacity(isPressed ? 0.45 : 0.26)
        case .secondary:
            return isPressed ? GargantuaColors.borderEm : GargantuaColors.border
        }
    }
}
