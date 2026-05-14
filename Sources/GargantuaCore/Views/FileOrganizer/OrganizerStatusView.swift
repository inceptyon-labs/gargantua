import SwiftUI

/// Working-state surface for the organizer: AccretionDiskView spinner +
/// caller-supplied message + elapsed-time readout + Cancel button.
/// Separate file so the parent view stays under SwiftLint's body-length
/// threshold and so the elapsed timer's `TimelineView` doesn't pin the
/// parent view's redraw cadence.
struct OrganizerStatusView: View {
    let message: String
    let onCancel: () -> Void

    @State private var startedAt = Date()

    var body: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            AccretionDiskView(activityRate: 2, size: 56)

            Text(message)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text(elapsedLabel(seconds: elapsed))
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .padding(.top, GargantuaSpacing.space2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startedAt = Date() }
    }

    private func elapsedLabel(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s elapsed" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes)m \(remainder)s elapsed"
    }
}
