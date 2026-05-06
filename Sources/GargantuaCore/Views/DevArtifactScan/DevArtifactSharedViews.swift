import SwiftUI

struct DevArtifactProfileOverrideBanner: View {
    let profile: CleanupProfile

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.ink2)

                Text("Profile: \(profile.name)")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }

            ForEach(Array(profile.safetyOverrides.enumerated()), id: \.offset) { _, override_ in
                HStack(spacing: GargantuaSpacing.space1) {
                    Circle()
                        .fill(safetyColor(override_.safety))
                        .frame(width: 6, height: 6)

                    Text("Auto-classified as \(override_.safety.displayName): \(override_.explanationSuffix ?? override_.condition)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .padding(.leading, GargantuaSpacing.space4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

struct DevArtifactScanWarningsBanner: View {
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            ForEach(Array(errors.enumerated()), id: \.offset) { _, message in
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)
                    Text(message)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }
}
