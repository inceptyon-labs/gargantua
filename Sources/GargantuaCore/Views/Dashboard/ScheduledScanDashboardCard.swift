import SwiftUI

struct ScheduledScanDashboardCard: View {
    let summary: ScheduledScanSummary
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            Image(systemName: summary.errorMessage == nil ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tone)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(summary.headline)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("\(summary.detail) · \(summary.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            if summary.errorMessage == nil {
                Button(action: onReview) {
                    Text("Review")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 24, height: 24)
                    .background(GargantuaColors.surface3)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss scheduled scan summary")
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(tone.opacity(0.65), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var tone: Color {
        summary.errorMessage == nil ? GargantuaColors.safe : GargantuaColors.review
    }
}
