import SwiftUI

/// One-time onboarding caption shown above the treemap until the user
/// dismisses it. Teaches the rectangle-size-equals-folder-size convention
/// that the visualization assumes the viewer already knows. Persists the
/// dismissed state via `@AppStorage`, so once seen it never reappears.
///
/// Renders nothing once dismissed — the caller doesn't need to gate.
struct DiskExplorerTreemapHintView: View {
    @AppStorage("disk-explorer.has-seen-treemap-hint")
    private var hasSeenHint: Bool = false

    var body: some View {
        if !hasSeenHint {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                Text("Bigger rectangles are bigger folders. Click any tile to drill in.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        hasSeenHint = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss hint")
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .strokeBorder(GargantuaColors.borderSoft, lineWidth: 1)
            )
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space2)
            .transition(.opacity)
        }
    }
}
