import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DeepCleanView")

// MARK: - Deep Clean View

/// Full-system cleanup scan view.
///
/// Runs a deep scan against the YAML rule set using the active `CleanupProfile`,
/// then presents results in the three-bucket `ScanBucketListView` pattern.
public struct DeepCleanView: View {
    private let profile: CleanupProfile
    private let adapterOverride: (any ScanAdapter)?
    private let session: DeepCleanSessionState
    private let onExplain: ((ScanResult) -> Void)?
    private let onAdvisory: (([ScanResult]) -> Void)?
    private let onResolveFilter: ((String) async -> ScanFilterSet?)?

    public init(
        profile: CleanupProfile = .deep,
        adapter: (any ScanAdapter)? = nil,
        session: DeepCleanSessionState,
        onExplain: ((ScanResult) -> Void)? = nil,
        onAdvisory: (([ScanResult]) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.profile = profile
        self.adapterOverride = adapter
        self.session = session
        self.onExplain = onExplain
        self.onAdvisory = onAdvisory
        self.onResolveFilter = onResolveFilter
    }

    @MainActor
    public init(profile: CleanupProfile = .deep, adapter: (any ScanAdapter)? = nil) {
        self.init(profile: profile, adapter: adapter, session: DeepCleanSessionState(), onExplain: nil, onAdvisory: nil)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch session.phase {
                case .idle:
                    startView
                        .transition(phaseTransition)
                case .scanning, .cleaning:
                    EventHorizonConsoleView(
                        context: .deepClean(phase: session.phase, profileName: profile.name),
                        stream: session.pathStream,
                        onAbort: { session.severTether() }
                    )
                    .transition(phaseTransition)
                case .results:
                    if let results = session.scanResults {
                        resultsView(results)
                            .transition(phaseTransition)
                    }
                case .summary:
                    if let result = session.cleanupResult {
                        summaryState(result: result)
                            .transition(phaseTransition)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: session.phase)

            if session.showConfirmation, let results = session.scanResults {
                let selected = results.filter { session.selectedResultIDs.contains($0.id) }
                ConfirmationModalView(
                    items: selected,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { session.showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.showConfirmation)
    }

    /// Asymmetric phase transition matching SmartUninstallerView so the
    /// scan→results and cleaning→summary swaps feel like deliberate beats
    /// against the dark background.
    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92))
                .combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -16))
        )
    }

    private func summaryState(result: CleanupResult) -> some View {
        let outcome = SingularityCloseMessage.Outcome.from(result: result)
        let accent = outcomeAccentColor(outcome.accent)
        return VStack(spacing: GargantuaSpacing.space2) {
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
                dismissSummary()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

    private func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Deep Clean",
                subtitle: "Reclaim what the system left behind."
            )

            // Description + action centered
            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                GargantuaBrandIcon(
                    resourceName: "deep-clean-gargantua-gpt2",
                    fallbackSystemName: "bubbles.and.sparkles"
                )

                Text("System Cleanup")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Scans for browser caches, app caches, system logs, temp files, old installers, and other reclaimable space.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                if session.scanProgress.errors.isEmpty == false {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.review)
                        Text(session.scanProgress.errors.first ?? "Scan error")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.review)
                            .lineLimit(1)
                    }
                }

                Button(action: startScan) {
                    Text("Start Deep Clean Scan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)
            }

            Spacer()
        }
    }

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Deep Clean",
                onBack: { session.clearResults() },
                onRescan: { startScan() },
                isBusy: session.isScanning
            )

            // Three-bucket scan results
            ScanBucketListView(
                results: results,
                scanDuration: session.scanDuration,
                selectedIDs: Binding(
                    get: { session.selectedResultIDs },
                    set: { session.selectedResultIDs = $0 }
                ),
                onExplain: onExplain,
                onClean: { session.showConfirmation = true },
                onCancel: { session.clearResults() },
                onAdvisoryForReview: onAdvisory,
                onResolveNaturalLanguageFilter: onResolveFilter
            )
        }
    }

    // MARK: - Actions

    private func confirmCleanup(_ items: [ScanResult], method: CleanupMethod) {
        session.beginCleanup(method: method)
        session.activeTask = Task {
            let engine = CleanupEngine()
            let result = await engine.clean(items, method: method, observer: session.pathStream)
            do {
                try AuditWriter().record(result: result)
            } catch {
                logger.warning("Failed to write audit entry: \(error.localizedDescription)")
            }
            // Mirror SmartUninstaller: hold the EventHorizon console on
            // screen long enough for spaghettify swallow animations to play
            // before transitioning to the singularity summary.
            if !result.itemResults.filter(\.succeeded).isEmpty, !reduceMotion {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
            // If the user severed the tether mid-cleanup, the session was
            // already reset to idle — don't pivot to a summary.
            guard !Task.isCancelled else { return }
            session.finishCleanup(result: result)
        }
    }

    private func dismissSummary() {
        session.dismissSummary()
    }

    private func startScan() {
        session.prepareForScan()
        session.activeTask = Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? NativeScanAdapter.loadDefaults(profile: profile)
                let results = try await adapter.scan(
                    progress: session.scanProgress,
                    observer: session.pathStream
                )
                guard !Task.isCancelled else { return }
                session.finishScan(results: results, duration: Date().timeIntervalSince(start))
            } catch {
                guard !Task.isCancelled else { return }
                session.failScan(error.localizedDescription)
            }
        }
    }
}

// MARK: - Footer helpers

/// Turn a rule category like "browser_cache" into "Browser Cache" for the footer.
func prettyScanCategory(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw
        .split(separator: "_")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// Replace `$HOME` in an absolute path with `~` for display.
func abbreviateHomePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
