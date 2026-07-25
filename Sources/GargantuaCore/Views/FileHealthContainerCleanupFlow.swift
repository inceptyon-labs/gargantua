import GargantuaLicensing
import OSLog
import SwiftUI

private let cleanupLogger = Logger(subsystem: "com.gargantua.core", category: "FileHealth")

extension FileHealthContainerView {
    var cleanupProgressView: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                HStack {
                    Text("ENDURANCE · FILE HEALTH CLEANUP")
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(2)
                        .foregroundStyle(GargantuaColors.ink2)
                    Spacer()
                    AccretionDiskView(activityRate: 20)
                }

                Text("TARGET: Trash")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)

                Text("[CASE] Humor: 30% · Honesty: 100% · Discretion: 100%")
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
                AccretionDiskView(activityRate: 20, size: 11)
                Text("Relocating selected items to Trash")
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
            }

            Spacer()
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func summaryState() -> some View {
        guard let result = state.cleanupResult else {
            return AnyView(EmptyView())
        }
        let outcome = SingularityCloseMessage.Outcome.from(result: result)
        let accent = outcomeAccentColor(outcome.accent)
        return AnyView(
            VStack(spacing: GargantuaSpacing.space2) {
                Spacer()
                VStack(spacing: GargantuaSpacing.space2) {
                    Text(SingularityCloseMessage.heading(for: result))
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(3)
                        .foregroundStyle(accent)

                    Text(SingularityCloseMessage.line(for: result))
                        .font(GargantuaFonts.body.italic())
                        .foregroundStyle(GargantuaColors.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                CleanupSummaryView(result: result, outcomeAccent: accent) {
                    state.dismissSummary()
                }
                Spacer()
            }
            .padding(GargantuaSpacing.space6)
        )
    }

    func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }

    func confirmCleanup(_ items: [ScanResult], method _: CleanupMethod) {
        guard state.phase == .results else {
            state.showConfirmation = false
            return
        }

        let currentResults = state.scanResults
        let currentWarnings = state.scanWarnings
        let confirmationMethod = confirmationTier(for: items)

        // Dismiss the confirmation modal synchronously so a double-tap can't
        // schedule a second cleanup while the async license gate is in flight.
        state.showConfirmation = false

        Task { @MainActor in
            // License gate fronts the send-to-trash. On blocked, stay on the
            // results phase and present the Unlock sheet instead.
            let authorization: DestructiveActionAuthorization
            switch await LicenseGate.shared.authorize(.fileHealthContainers) {
            case .failure(let reason):
                blockedReason = reason
                return
            case .success(let granted):
                authorization = granted
            }
            state.beginCleanup()

            let result = await CleanupEngine(privilegedHelper: XPCPrivilegedUninstallHelper())
                .clean(items, method: .trash, authorization: authorization)
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

            let remaining = FileHealthCleanupFlow.remainingResults(
                after: result,
                from: currentResults
            )
            let warnings = currentWarnings + FileHealthCleanupFlow.failureWarnings(from: result)
            state.session.selectedResultIDs = FileHealthCleanupFlow.remainingSelection(
                after: result,
                from: state.session.selectedResultIDs
            )
            state.finishCleanup(result: result, remaining: remaining, warnings: warnings)
        }
    }
}
