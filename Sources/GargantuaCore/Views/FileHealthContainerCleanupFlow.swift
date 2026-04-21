import OSLog
import SwiftUI

private let cleanupLogger = Logger(subsystem: "com.gargantua.core", category: "FileHealth")

extension FileHealthContainerView {
    var cleanupProgressView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Moving selected items to Trash...")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("File Health uses the same Trash-first cleanup path as Deep Clean.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    func summaryState(context: CleanupContext) -> some View {
        let outcome = SingularityCloseMessage.Outcome.from(result: context.result)
        let accent = outcomeAccentColor(outcome.accent)
        return VStack(spacing: GargantuaSpacing.space2) {
            Spacer()
            VStack(spacing: GargantuaSpacing.space2) {
                Text(SingularityCloseMessage.heading(for: context.result))
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(3)
                    .foregroundStyle(accent)

                Text(SingularityCloseMessage.line(for: context.result))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            CleanupSummaryView(result: context.result, outcomeAccent: accent) {
                dismissSummary()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

    func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }

    func confirmCleanup(_ items: [ScanResult], method _: CleanupMethod) {
        guard case .results(let currentResults, let currentWarnings) = scanState else {
            showConfirmation = false
            return
        }

        showConfirmation = false
        scanState = .cleaning
        let confirmationMethod = confirmationTier(for: items)

        Task { @MainActor in
            let cleanupMethod: CleanupMethod = .trash
            let result = await CleanupEngine().clean(items, method: cleanupMethod)
            do {
                try AuditWriter().record(
                    result: result,
                    tool: "file-health",
                    command: "send-to-trash",
                    confirmationMethod: confirmationMethod
                )
            } catch {
                cleanupLogger.warning("Failed to write File Health audit entry: \(error.localizedDescription)")
            }

            let remainingResults = FileHealthCleanupFlow.remainingResults(
                after: result,
                from: currentResults
            )
            let warnings = currentWarnings + FileHealthCleanupFlow.failureWarnings(from: result)
            session.selectedResultIDs = FileHealthCleanupFlow.remainingSelection(
                after: result,
                from: session.selectedResultIDs
            )
            cleanupContext = CleanupContext(
                result: result,
                remainingResults: remainingResults,
                warnings: warnings
            )
            scanState = .summary
        }
    }

    func dismissSummary() {
        guard let cleanupContext else {
            scanState = .idle
            return
        }
        scanState = .results(cleanupContext.remainingResults, warnings: cleanupContext.warnings)
        self.cleanupContext = nil
    }
}
