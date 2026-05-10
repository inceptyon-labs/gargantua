import SwiftUI

struct DevArtifactToolNativeBridge: View {
    let onOpenDeveloperTools: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            DevArtifactToolNativeLogoStrip()

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("Run tool-native cleanup first")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text("Let Homebrew, Docker, Xcode, pnpm, Go, and Cargo prune themselves before this raw folder scan.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(2)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            Button(action: onOpenDeveloperTools) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Developer Tools")
                        .font(GargantuaFonts.caption)
                }
                .foregroundStyle(GargantuaColors.accent)
                .padding(.horizontal, GargantuaSpacing.space2)
                .padding(.vertical, GargantuaSpacing.space1)
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.borderSoft, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
        }
    }
}

private struct DevArtifactToolNativeLogoStrip: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(DeveloperTool.allCases) { tool in
                DeveloperToolLogoBadge(
                    tool: tool,
                    size: 16,
                    showsBackground: true
                )
            }
        }
        .frame(width: 112, alignment: .leading)
        .accessibilityHidden(true)
    }
}

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
