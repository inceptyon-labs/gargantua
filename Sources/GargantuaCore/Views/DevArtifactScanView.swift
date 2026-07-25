import GargantuaLicensing
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DevArtifactScanView")

/// Three-state lifecycle for the cold-start ecosystem probe. The view
/// shows a `detecting` placeholder until the detector returns; on
/// `complete` it seeds `selectedBucketIDs` and renders the bucket list.
public enum EcosystemDetectionState: Equatable {
    case pending
    case detecting
    case complete
}

// MARK: - Dev Artifact Scan View

/// Category-based view for scanning and cleaning developer artifacts.
///
/// Presents a category list (node_modules, Xcode, Docker, etc.) with toggles
/// and estimated sizes. Runs a `NativeScanAdapter` scoped to the Developer
/// profile (`dev_artifacts`, `docker`, `homebrew` categories) and displays
/// results using `ScanBucketListView`.
public struct DevArtifactScanView: View {
    private let profile: CleanupProfile
    private let adapterOverride: (any ScanAdapter)?
    private let scanRoots: [URL]?
    private let staleVersionPinnedPaths: Set<String>

    /// Flow state owned by `MainContentView` (mirrors `DeepCleanSessionState`)
    /// so navigating away mid-scan/mid-clean doesn't orphan the in-flight
    /// task, lose the summary, or allow a second overlapping clean.
    @Bindable var session: DevArtifactSessionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blockedReason: BlockReason?

    private let onExplain: ((ScanResult) -> Void)?
    private let onResolveFilter: ((String) async -> ScanFilterSet?)?
    private let onCleanupCompleted: ((CleanupResult) -> Void)?
    private let onOpenDeveloperTools: (() -> Void)?

    public init(
        profile: CleanupProfile = .developer,
        session: DevArtifactSessionState,
        scanRoots: [URL]? = nil,
        adapter: (any ScanAdapter)? = nil,
        staleVersionPinnedPaths: Set<String> = [],
        onExplain: ((ScanResult) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil,
        onCleanupCompleted: ((CleanupResult) -> Void)? = nil,
        onOpenDeveloperTools: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.session = session
        self.scanRoots = scanRoots
        self.adapterOverride = adapter
        self.staleVersionPinnedPaths = staleVersionPinnedPaths
        self.onExplain = onExplain
        self.onResolveFilter = onResolveFilter
        self.onCleanupCompleted = onCleanupCompleted
        self.onOpenDeveloperTools = onOpenDeveloperTools
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch session.phase {
                case .idle:
                    DevArtifactCategorySelectionView(
                        profile: profile,
                        detectionState: session.detectionState,
                        selectedBucketIDs: session.selectedBucketIDs,
                        detectedEcosystemIDs: session.detectedEcosystemIDs,
                        bucketEstimates: session.bucketEstimates,
                        scanProgress: session.scanProgress,
                        isScanRequested: session.isScanRequested,
                        onSelectAll: selectAllBuckets,
                        onDeselectAll: deselectAllBuckets,
                        onInvertSelection: invertBucketSelection,
                        onToggleBucket: toggleBucket,
                        onStartScan: startScan,
                        onOpenDeveloperTools: onOpenDeveloperTools
                    )
                    .task(id: profile.id) {
                        await detectEcosystemsIfNeeded()
                    }
                    .transition(phaseTransition)
                case .scanning, .cleaning:
                    EventHorizonConsoleView(
                        context: .devPurge(phase: session.phase, profileName: profile.name),
                        stream: session.pathStream,
                        onAbort: severTether
                    )
                    .transition(phaseTransition)
                case .results:
                    if let results = session.scanResults {
                        DevArtifactResultsView(
                            profile: profile,
                            results: results,
                            scanDuration: session.scanDuration,
                            selectedResultIDs: $session.selectedResultIDs,
                            scanProgress: session.scanProgress,
                            onExplain: onExplain,
                            onClean: { session.showConfirmation = true },
                            onBack: { session.returnToIdle() },
                            onCancel: { session.returnToIdle() },
                            onRescan: startScan,
                            onResolveFilter: onResolveFilter
                        )
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
        .destructiveActionGate(reason: $blockedReason)
    }

    /// Asymmetric phase transition matching SmartUninstaller / Deep Clean.
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
            CleanupSummaryView(result: result, outcomeAccent: accent, onExplain: onExplain, onRetried: onCleanupCompleted) {
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
}

// MARK: - Actions

extension DevArtifactScanView {
    fileprivate func confirmCleanup(_ items: [ScanResult], method: CleanupMethod) {
        session.beginCleanup(method: method)
        session.activeTask = Task {
            // License gate fronts every Dev Purge execute. On blocked, sever
            // the cleanup phase and present the Unlock sheet instead.
            let authorization: DestructiveActionAuthorization
            switch await LicenseGate.shared.authorize(.devArtifacts) {
            case .failure(let reason):
                session.severTether()
                blockedReason = reason
                return
            case .success(let granted):
                authorization = granted
            }
            let engine = CleanupEngine(privilegedHelper: XPCPrivilegedUninstallHelper())
            let result = await engine.clean(
                items, method: method, observer: session.pathStream, authorization: authorization
            )
            do {
                try AuditWriter().record(result: result)
            } catch {
                logger.warning("Failed to write audit entry: \(error.localizedDescription)")
            }
            // Mirror SmartUninstaller / Deep Clean: hold the EventHorizon
            // console on screen long enough for spaghettify swallow
            // animations to play before transitioning to the summary card.
            if !result.itemResults.filter(\.succeeded).isEmpty, !reduceMotion {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
            // If the user severed the tether mid-cleanup, the session is
            // already idle — do not pivot to a summary.
            guard !Task.isCancelled else { return }
            session.finishCleanup(result: result)
            onCleanupCompleted?(result)
        }
    }

    /// User-initiated abort from the EventHorizon console.
    fileprivate func severTether() {
        session.severTether()
    }

    private func dismissSummary() {
        session.dismissSummary()
    }

    private func toggleBucket(_ id: String) {
        if session.selectedBucketIDs.contains(id) {
            session.selectedBucketIDs.remove(id)
        } else {
            session.selectedBucketIDs.insert(id)
        }
    }

    fileprivate func selectAllBuckets() {
        session.selectedBucketIDs = Set(DevArtifactBucket.catalog.map(\.id))
    }

    fileprivate func deselectAllBuckets() {
        session.selectedBucketIDs = []
    }

    fileprivate func invertBucketSelection() {
        let all = Set(DevArtifactBucket.catalog.map(\.id))
        session.selectedBucketIDs = all.subtracting(session.selectedBucketIDs)
    }

    /// Probe the filesystem once per profile-id to seed `selectedBucketIDs`
    /// with ecosystems that actually appear on this machine. Cross-cutting
    /// buckets are seeded unconditionally (they're additive). Detection is
    /// idempotent — subsequent calls bail without reprobing.
    ///
    /// `detectedEcosystemIDs` records what the probe positively identified
    /// (excluding the catch-all "other" bucket and the fallback subset),
    /// so the UI can mark those rows "on disk" vs. ecosystems that are
    /// available to scan but not present.
    fileprivate func detectEcosystemsIfNeeded() async {
        guard session.detectionState == .pending else { return }
        session.detectionState = .detecting

        let roots = scanRoots ?? PathExpander.defaultScanRoots()
        let detected = await DevArtifactDetection.detectEcosystems(in: roots)

        // If detection found nothing usable on this machine (no scan roots,
        // empty home), fall back to the high-frequency subset so the user
        // isn't staring at zero checkboxes. The fallback is not reflected
        // in `detectedEcosystemIDs`: it's a guess, not evidence.
        let ecosystems = detected.isEmpty
            ? Set(["node", "python", "other"])
            : detected.union(["other"])

        // Cross-fade detecting -> bucket list so the swap doesn't lurch.
        // Reduce-motion users get the instant swap via the environment
        // value already plumbed into `phaseTransition`.
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.4)
        withAnimation(animation) {
            session.detectedEcosystemIDs = detected
            session.selectedBucketIDs = ecosystems.union(DevArtifactDetection.alwaysSelectedCrossCutting)
            session.detectionState = .complete
        }
    }

    private func startScan() {
        session.prepareForScan()
        session.activeTask = Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? ProfileScanAdapterFactory.make(
                        profile: profile,
                        scanRoots: scanRoots,
                        staleVersionPinnedPaths: staleVersionPinnedPaths
                    )
                let results = try await adapter.scan(
                    progress: session.scanProgress,
                    observer: session.pathStream
                )
                guard !Task.isCancelled else { return }

                // Filter results to the user's selected buckets. A result
                // is kept if any of its derived buckets is selected — so
                // a Gradle log (JVM ecosystem + Build caches + Logs)
                // shows up if any of those three buckets is on.
                let selectedBucketIDs = session.selectedBucketIDs
                let filtered = results.filter { result in
                    let derivedIDs = DevArtifactBucket.derive(from: result).map(\.id)
                    return derivedIDs.contains(where: selectedBucketIDs.contains)
                }

                // Bucket estimated sizes come from the full result set (not
                // the filtered set) so the user sees what's available even
                // in buckets they currently have unchecked.
                session.finishScan(
                    results: filtered,
                    duration: Date().timeIntervalSince(start),
                    estimates: Self.estimatedSizes(from: results)
                )
            } catch {
                guard !Task.isCancelled else { return }
                session.failScan(error.localizedDescription)
            }
        }
    }

    static func estimatedSizes(from results: [ScanResult]) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        for result in results {
            for bucket in DevArtifactBucket.derive(from: result) {
                totals[bucket.id, default: 0] += result.size
            }
        }
        return totals
    }
}

// MARK: - SafetyLevel Display Name

extension SafetyLevel {
    var displayName: String {
        switch self {
        case .safe: "safe"
        case .review: "review"
        case .protected_: "protected"
        }
    }
}
