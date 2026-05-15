import SwiftUI

extension OrganizerStagedPreviewView {
    @ViewBuilder
    func appliedState(summary: OrganizerExecutionResult) -> some View {
        OrganizerPostApplyView(session: session, summary: summary)
    }

    @ViewBuilder
    func undoneState(summary: OrganizerUndoResult) -> some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(GargantuaColors.ink2)
            Text("Reversed \(summary.reversed.count) move\(summary.reversed.count == 1 ? "" : "s")")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Button("Back") { session.reset() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func failedState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(GargantuaColors.review)
            Text("Couldn't complete")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Back") { session.reset() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GargantuaSpacing.space5)
    }
}
