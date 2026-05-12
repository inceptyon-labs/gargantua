import SwiftUI

extension SmartUninstallerView {
    // MARK: - Error State

    func errorState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Text("SIGNAL FAILED")
                .font(GargantuaFonts.sectionLabel)
                .tracking(3)
                .foregroundStyle(GargantuaColors.protected_)
                // Tracking + all-caps makes VoiceOver read "S I G N A L…";
                // override with a natural-language label.
                .accessibilityLabel("Signal failed — uninstall error")

            Text("Transmission aborted. The operation could not complete.")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            Button { viewModel.reset() } label: {
                Text("Back to apps")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay {
                        if errorRetryFocused {
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .stroke(GargantuaColors.borderFocus, lineWidth: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($errorRetryFocused)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
