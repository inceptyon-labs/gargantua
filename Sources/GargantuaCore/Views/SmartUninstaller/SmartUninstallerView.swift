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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var errorRetryFocused: Bool

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
                case .failed(let message):
                    errorState(message: message)
                        .transition(phaseTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.30), value: phaseKey)

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

    private func errorState(message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Text("SIGNAL FAILED")
                .font(GargantuaFonts.sectionLabel)
                .tracking(3)
                .foregroundStyle(GargantuaColors.protected_)
                // Tracking + all-caps makes VoiceOver read "S I G N A L…";
                // override with a natural-language label.
                .accessibilityLabel("Signal failed — uninstall error")

            Text("Transmission aborted. The operation could not complete.")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            Button { viewModel.reset() } label: {
                Text("Back to apps")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay {
                        if errorRetryFocused {
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .stroke(GargantuaColors.borderFocus, lineWidth: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($errorRetryFocused)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }

    // MARK: - Phase animation plumbing

    /// Stable key for the phase bucket. `.scanning(app)` and
    /// `.scanning(otherApp)` share a key so SwiftUI doesn't crossfade when
    /// only the associated value changes; only real phase transitions do.
    private var phaseKey: String {
        switch viewModel.phase {
        case .idle: "idle"
        case .loadingApps: "loadingApps"
        case .pickingApp: "pickingApp"
        case .scanning: "scanning"
        case .reviewingPlan: "reviewingPlan"
        case .executing: "executing"
        case .summary: "summary"
        case .failed: "failed"
        }
    }

    /// Crossfade between phase screens. Reduce-motion collapses to a cut so
    /// users who have the OS preference set don't get the half-second fade
    /// every time they click.
    private var phaseTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
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
