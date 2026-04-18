import SwiftUI

/// Root view for the Smart Uninstaller surface.
///
/// Drives the phase machine on ``SmartUninstallerViewModel`` and routes
/// between the app picker, plan review, execution spinner, and post-uninstall
/// summary. Uses the stock `DefaultAppScanner`, `RemnantScanner`, and
/// `UninstallExecutor` by default; callers can inject alternatives for tests
/// or previews.
public struct SmartUninstallerView: View {
    @State private var viewModel: SmartUninstallerViewModel
    @State private var showingConfirmation = false

    public init(viewModel: SmartUninstallerViewModel? = nil) {
        if let viewModel {
            _viewModel = State(initialValue: viewModel)
        } else {
            _viewModel = State(initialValue: SmartUninstallerView.makeDefaultViewModel())
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch viewModel.phase {
                case .idle, .loadingApps, .scanning, .executing:
                    EventHorizonConsoleView(
                        phase: viewModel.phase,
                        stream: viewModel.pathStream
                    )
                case .pickingApp:
                    UninstallAppPickerView(viewModel: viewModel)
                case .reviewingPlan:
                    UninstallPlanReviewView(
                        viewModel: viewModel,
                        onUninstallTapped: { showingConfirmation = true },
                        onBack: { viewModel.reset() }
                    )
                case .summary(_, let result):
                    summaryState(result: result)
                case .failed(let message):
                    errorState(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingConfirmation, viewModel.currentPlan != nil {
                // Cleanup method is ignored: UninstallExecutor is Trash-only.
                // Picking "Delete" in the modal would otherwise surface as a
                // failed uninstall after final confirmation.
                ConfirmationModalView(
                    items: viewModel.selectedScanResults,
                    onConfirm: { _ in
                        showingConfirmation = false
                        Task { await viewModel.execute() }
                    },
                    onCancel: { showingConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showingConfirmation)
        .task {
            if case .idle = viewModel.phase {
                await viewModel.loadApps()
            }
        }
    }

    // MARK: - Phase subviews

    private func summaryState(result: UninstallExecutionResult) -> some View {
        VStack(spacing: GargantuaSpacing.space4) {
            Spacer()
            VStack(spacing: GargantuaSpacing.space2) {
                Text("SIGNAL RECOVERED")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(3)
                    .foregroundStyle(GargantuaColors.accretion)

                Text(SingularityCloseMessage.line(for: result.cleanupResult))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            CleanupSummaryView(result: result.cleanupResult) {
                viewModel.reset()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.protected_)

            Text("Uninstall failed")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(message)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, GargantuaSpacing.space6)

            Button { viewModel.reset() } label: {
                Text("Back to apps")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Default wiring

    @MainActor
    private static func makeDefaultViewModel() -> SmartUninstallerViewModel {
        let stream = PathStreamViewModel()
        let scanner = DefaultAppScanner(observer: stream)
        let planner: any UninstallPlanning
        do {
            planner = try RemnantScanner.loadDefaults(observer: stream)
        } catch {
            // Falling back to an empty rule set means the picker still works
            // but plans will only contain the app bundle. Better than a hard
            // crash when the bundled resource is missing in a dev build.
            planner = RemnantScanner(rules: [], observer: stream)
        }
        return SmartUninstallerViewModel(
            appScanner: scanner,
            planner: planner,
            executor: UninstallExecutor(observer: stream),
            pathStream: stream
        )
    }
}
