import SwiftUI

/// Root view for the Smart Uninstaller surface.
///
/// Drives the phase machine on ``SmartUninstallerViewModel`` and routes
/// between the app picker, plan review, execution spinner, and post-uninstall
/// summary. Uses the stock `DefaultAppScanner`, `RemnantScanner`, and
/// `UninstallExecutor` by default; callers can inject alternatives for tests
/// or previews.
public struct SmartUninstallerView: View {
    private let viewModel: SmartUninstallerViewModel
    @State private var showingConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var errorRetryFocused: Bool

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

    // MARK: - Phase subviews

    private var idleView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Smart Uninstaller",
                subtitle: "Pull an app apart, root and remnants.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "smart-uninstaller-gargantua-gpt2",
                    fallbackSystemName: "trash.slash"
                )

                Text("Finds installed apps and surfaces their support files, caches, and login items so you can review what gets removed.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Button {
                    viewModel.runTracked { await viewModel.loadApps() }
                } label: {
                    Text("Scan Installed Apps")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        case .batchScanning: "batchScanning"
        case .batchExecuting: "batchExecuting"
        case .batchSummary: "batchSummary"
        case .failed: "failed"
        }
    }

    private func batchSummaryState(results: [UninstallExecutionResult]) -> some View {
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

    /// Transition between phase screens. Incoming view fades + rises up from
    /// 12pt below with a scale bump from 0.92; outgoing fades and drops away.
    /// The substantial motion + offset make the executing → summary swap feel
    /// like a deliberate transition against the dark background, where the
    /// two screens are so visually different that a subtle opacity fade reads
    /// as a hard cut. Reduce-motion collapses to a cut so users with the OS
    /// preference set don't get the animation every time they click.
    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92))
                .combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -16))
        )
    }

    // MARK: - Default wiring

    /// Build the production view model with the default scanner, planner, and
    /// executor wired through the same `PathStreamViewModel`. Public so the
    /// app shell can hoist the instance and let it survive sidebar navigation.
    @MainActor
    public static func makeDefaultViewModel() -> SmartUninstallerViewModel {
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
            executor: UninstallExecutor(
                privilegedHelper: XPCPrivilegedUninstallHelper(),
                observer: stream
            ),
            authorizationProvider: { .privilegedHelperApproved },
            pathStream: stream
        )
    }
}
