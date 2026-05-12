import SwiftUI

/// Root view for the Smart Uninstaller surface.
///
/// Drives the phase machine on ``SmartUninstallerViewModel`` and routes
/// between the app picker, plan review, execution spinner, and post-uninstall
/// summary. Uses the stock `DefaultAppScanner`, `RemnantScanner`, and
/// `UninstallExecutor` by default; callers can inject alternatives for tests
/// or previews.
public struct SmartUninstallerView: View {
    let viewModel: SmartUninstallerViewModel
    @State private var showingConfirmation = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @FocusState var errorRetryFocused: Bool

    public init(viewModel: SmartUninstallerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch viewModel.phase {
                case .idle:
                    idleView
                        .transition(phaseTransition)
                case .loadingApps, .scanning, .executing,
                     .batchScanning, .batchExecuting:
                    EventHorizonConsoleView(
                        context: .uninstaller(phase: viewModel.phase),
                        stream: viewModel.pathStream,
                        onAbort: { viewModel.severTether() }
                    )
                    .transition(phaseTransition)
                case .pickingApp:
                    UninstallAppPickerView(viewModel: viewModel)
                        .transition(phaseTransition)
                case .reviewingPlan:
                    UninstallPlanReviewView(
                        viewModel: viewModel,
                        onUninstallTapped: { showingConfirmation = true },
                        onBack: { viewModel.reset() }
                    )
                    .transition(phaseTransition)
                case .summary(_, let result):
                    summaryState(result: result)
                        .transition(phaseTransition)
                case .batchSummary(let results):
                    batchSummaryState(results: results)
                        .transition(phaseTransition)
                case .failed(let message):
                    errorState(message: message)
                        .transition(phaseTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: phaseKey)

            if showingConfirmation || viewModel.quickConfirmActive,
               viewModel.currentPlan != nil {
                // Cleanup method is ignored: UninstallExecutor is Trash-only.
                // Picking "Delete" in the modal would otherwise surface as a
                // failed uninstall after final confirmation.
                ConfirmationModalView(
                    items: viewModel.selectedScanResults,
                    onConfirm: { _ in
                        showingConfirmation = false
                        viewModel.quickConfirmActive = false
                        viewModel.runTracked { await viewModel.execute() }
                    },
                    onCancel: {
                        showingConfirmation = false
                        // Quick-uninstall cancel returns the user to the
                        // picker — they didn't ask for the plan-review
                        // detour. Plan-review uninstall keeps the review
                        // open in case they want to re-tweak selections.
                        if viewModel.quickConfirmActive {
                            viewModel.quickConfirmActive = false
                            viewModel.reset()
                        }
                    }
                )
                .transition(.opacity)
            }

            if !viewModel.batchPlans.isEmpty,
               case .batchScanning(let completed, let total) = viewModel.phase,
               completed == total {
                ConfirmationModalView(
                    items: viewModel.batchSelectedScanResults,
                    onConfirm: { _ in
                        viewModel.runTracked { await viewModel.executeBatch() }
                    },
                    onCancel: { viewModel.cancelBatch() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showingConfirmation)
    }
}
