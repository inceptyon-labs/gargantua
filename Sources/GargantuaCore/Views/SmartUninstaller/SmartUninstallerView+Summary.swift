import SwiftUI

extension SmartUninstallerView {
    // MARK: - Single-App Summary

    func summaryState(result: UninstallExecutionResult) -> some View {
        let outcome = SingularityCloseMessage.Outcome.from(result: result.cleanupResult)
        let accent = outcomeAccentColor(outcome.accent)
        return VStack(spacing: GargantuaSpacing.space2) {
            Spacer()
            VStack(spacing: GargantuaSpacing.space2) {
                Text(SingularityCloseMessage.heading(for: result.cleanupResult))
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(3)
                    .foregroundStyle(accent)

                Text(SingularityCloseMessage.line(for: result.cleanupResult))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            CleanupSummaryView(result: result.cleanupResult, outcomeAccent: accent) {
                viewModel.reset()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

    // MARK: - Batch Summary

    func batchSummaryState(results: [UninstallExecutionResult]) -> some View {
        // Combine every per-plan CleanupResult into one CleanupResult so the
        // existing SingularityCloseMessage + CleanupSummaryView can render
        // it without needing a batch-aware variant.
        let allItemResults = results.flatMap { $0.cleanupResult.itemResults }
        let combined = CleanupResult(itemResults: allItemResults, cleanupMethod: .trash)
        let outcome = SingularityCloseMessage.Outcome.from(result: combined)
        let accent = outcomeAccentColor(outcome.accent)
        let appCount = results.count
        return VStack(spacing: GargantuaSpacing.space2) {
            Spacer()
            VStack(spacing: GargantuaSpacing.space2) {
                Text(SingularityCloseMessage.heading(for: combined))
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(3)
                    .foregroundStyle(accent)

                Text("\(appCount) apps · \(SingularityCloseMessage.line(for: combined))")
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            CleanupSummaryView(result: combined, outcomeAccent: accent) {
                viewModel.reset()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

    // MARK: - Accent Helper

    private func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }
}
