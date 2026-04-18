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
                case .idle, .loadingApps:
                    loadingState
                case .pickingApp:
                    UninstallAppPickerView(viewModel: viewModel)
                case .scanning(let app):
                    scanningState(for: app)
                case .reviewingPlan:
                    UninstallPlanReviewView(
                        viewModel: viewModel,
                        onUninstallTapped: { showingConfirmation = true },
                        onBack: { viewModel.reset() }
                    )
                case .executing:
                    executingState
                case .summary(_, let result):
                    summaryState(result: result)
                case .failed(let message):
                    errorState(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingConfirmation, viewModel.currentPlan != nil {
                ConfirmationModalView(
                    items: viewModel.selectedScanResults,
                    onConfirm: { method in
                        viewModel.cleanupMethod = method
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

    private var loadingState: some View {
        centeredStatus(
            icon: "hourglass",
            title: "Scanning installed apps",
            detail: "Reading /Applications and Launch Services…"
        )
    }

    private func scanningState(for app: AppInfo) -> some View {
        centeredStatus(
            icon: "magnifyingglass",
            title: "Analyzing \(app.displayName ?? app.name)",
            detail: "Matching remnant rules against the filesystem…"
        )
    }

    private var executingState: some View {
        centeredStatus(
            icon: "trash",
            title: "Uninstalling…",
            detail: "Moving items to Trash and writing audit entries.",
            tint: GargantuaColors.accent
        )
    }

    private func summaryState(result: UninstallExecutionResult) -> some View {
        VStack {
            Spacer()
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

    private func centeredStatus(
        icon: String,
        title: String,
        detail: String,
        tint: Color = GargantuaColors.ink3
    ) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(tint)

            Text(title)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(detail)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Default wiring

    @MainActor
    private static func makeDefaultViewModel() -> SmartUninstallerViewModel {
        let scanner = DefaultAppScanner()
        let planner: any UninstallPlanning
        do {
            planner = try RemnantScanner.loadDefaults()
        } catch {
            // Falling back to an empty rule set means the picker still works
            // but plans will only contain the app bundle. Better than a hard
            // crash when the bundled resource is missing in a dev build.
            planner = RemnantScanner(rules: [])
        }
        return SmartUninstallerViewModel(
            appScanner: scanner,
            planner: planner,
            executor: UninstallExecutor()
        )
    }
}
