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

    /// Smart-default lifecycle. Empty until ecosystem detection completes;
    /// then seeded from `DevArtifactDetection.detectEcosystems` plus the
    /// always-on cross-cutting set. The user is free to widen from there.
    @State private var selectedBucketIDs: Set<String> = []
    @State private var detectionState: EcosystemDetectionState = .pending
    /// Ecosystem ids the probe positively identified on disk. Used as a
    /// visual signal in the bucket list ("on disk" dot) and in the toolbar
    /// tally so the user can see which buckets are pre-selected because
    /// they were actually found, vs. which are available but absent.
    @State private var detectedEcosystemIDs: Set<String> = []
    /// Per-bucket size totals from the most recent scan. Keyed by bucket id.
    @State private var bucketEstimates: [String: Int64] = [:]
    @State private var scanProgress = ScanProgress()
    @State private var scanResults: [ScanResult]?
    @State private var scanDuration: TimeInterval = 0
    @State private var selectedResultIDs: Set<String> = []
    @State private var isScanRequested = false
    @State private var showConfirmation = false
    @State private var isCleaning = false
    @State private var activeCleanupMethod: CleanupMethod = .trash
    @State private var cleanupResult: CleanupResult?
    @State private var phase: DeepCleanPhase = .idle
    @State private var pathStream = PathStreamViewModel()
    /// In-flight scan or cleanup task. Held so "Sever Tether" can cancel
    /// from inside the EventHorizon console. Always overwrite when starting
    /// new work so a stale handle can't leak across phases.
    @State private var activeTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onExplain: ((ScanResult) -> Void)?
    private let onResolveFilter: ((String) async -> ScanFilterSet?)?
    private let onCleanupCompleted: ((CleanupResult) -> Void)?

    public init(
        profile: CleanupProfile = .developer,
        scanRoots: [URL]? = nil,
        adapter: (any ScanAdapter)? = nil,
        staleVersionPinnedPaths: Set<String> = [],
        onExplain: ((ScanResult) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil,
        onCleanupCompleted: ((CleanupResult) -> Void)? = nil
    ) {
        self.profile = profile
        self.scanRoots = scanRoots
        self.adapterOverride = adapter
        self.staleVersionPinnedPaths = staleVersionPinnedPaths
        self.onExplain = onExplain
        self.onResolveFilter = onResolveFilter
        self.onCleanupCompleted = onCleanupCompleted
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch phase {
                case .idle:
                    DevArtifactCategorySelectionView(
                        profile: profile,
                        detectionState: detectionState,
                        selectedBucketIDs: selectedBucketIDs,
                        detectedEcosystemIDs: detectedEcosystemIDs,
                        bucketEstimates: bucketEstimates,
                        scanProgress: scanProgress,
                        isScanRequested: isScanRequested,
                        onSelectAll: selectAllBuckets,
                        onDeselectAll: deselectAllBuckets,
                        onInvertSelection: invertBucketSelection,
                        onToggleBucket: toggleBucket,
                        onStartScan: startScan
                    )
                    .task(id: profile.id) {
                        await detectEcosystemsIfNeeded()
                    }
                    .transition(phaseTransition)
                case .scanning, .cleaning:
                    EventHorizonConsoleView(
                        context: .devPurge(phase: phase, profileName: profile.name),
                        stream: pathStream,
                        onAbort: severTether
                    )
                    .transition(phaseTransition)
                case .results:
                    if let results = scanResults {
                        DevArtifactResultsView(
                            profile: profile,
                            results: results,
                            scanDuration: scanDuration,
                            selectedResultIDs: $selectedResultIDs,
                            scanProgress: scanProgress,
                            onExplain: onExplain,
                            onClean: { showConfirmation = true },
                            onBack: {
                                scanResults = nil
                                pathStream.clear()
                                phase = .idle
                            },
                            onCancel: {
                                scanResults = nil
                                pathStream.clear()
                                phase = .idle
                            },
                            onRescan: startScan,
                            onResolveFilter: onResolveFilter
                        )
                        .transition(phaseTransition)
                    }
                case .summary:
                    if let result = cleanupResult {
                        summaryState(result: result)
                            .transition(phaseTransition)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: phase)

            if showConfirmation, let results = scanResults {
                let selected = results.filter { selectedResultIDs.contains($0.id) }
                ConfirmationModalView(
                    items: selected,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showConfirmation)
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
}

// MARK: - Actions

extension DevArtifactScanView {
    fileprivate func confirmCleanup(_ items: [ScanResult], method: CleanupMethod) {
        activeTask?.cancel()
        showConfirmation = false
        isCleaning = true
        activeCleanupMethod = method
        pathStream.clear()
        phase = .cleaning
        activeTask = Task {
            let engine = CleanupEngine()
            let result = await engine.clean(items, method: method, observer: pathStream)
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
            // If the user severed the tether mid-cleanup, the view is
            // already idle — do not pivot to a summary.
            guard !Task.isCancelled else { return }
            isCleaning = false
            cleanupResult = result
            phase = .summary
            onCleanupCompleted?(result)
        }
    }

    /// User-initiated abort from the EventHorizon console. Cancels the
    /// in-flight scan or cleanup task and rewinds to the category-selection
    /// idle screen. Items already cleaned during this run stay cleaned.
    fileprivate func severTether() {
        activeTask?.cancel()
        activeTask = nil
        isScanRequested = false
        isCleaning = false
        showConfirmation = false
        scanProgress = ScanProgress()
        scanDuration = 0
        scanResults = nil
        selectedResultIDs = []
        cleanupResult = nil
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }

    private func dismissSummary() {
        cleanupResult = nil
        scanResults = nil
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }

    private func toggleBucket(_ id: String) {
        if selectedBucketIDs.contains(id) {
            selectedBucketIDs.remove(id)
        } else {
            selectedBucketIDs.insert(id)
        }
    }

    fileprivate func selectAllBuckets() {
        selectedBucketIDs = Set(DevArtifactBucket.catalog.map(\.id))
    }

    fileprivate func deselectAllBuckets() {
        selectedBucketIDs = []
    }

    fileprivate func invertBucketSelection() {
        let all = Set(DevArtifactBucket.catalog.map(\.id))
        selectedBucketIDs = all.subtracting(selectedBucketIDs)
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
        guard detectionState == .pending else { return }
        detectionState = .detecting

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
            detectedEcosystemIDs = detected
            selectedBucketIDs = ecosystems.union(DevArtifactDetection.alwaysSelectedCrossCutting)
            detectionState = .complete
        }
    }

    private func startScan() {
        activeTask?.cancel()
        isScanRequested = true
        scanProgress = ScanProgress()
        pathStream.clear()
        phase = .scanning
        activeTask = Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? ProfileScanAdapterFactory.make(
                        profile: profile,
                        scanRoots: scanRoots,
                        staleVersionPinnedPaths: staleVersionPinnedPaths
                    )
                let results = try await adapter.scan(progress: scanProgress, observer: pathStream)
                guard !Task.isCancelled else { return }

                // Filter results to the user's selected buckets. A result
                // is kept if any of its derived buckets is selected — so
                // a Gradle log (JVM ecosystem + Build caches + Logs)
                // shows up if any of those three buckets is on.
                let filtered = results.filter { result in
                    let derivedIDs = DevArtifactBucket.derive(from: result).map(\.id)
                    return derivedIDs.contains(where: selectedBucketIDs.contains)
                }

                scanDuration = Date().timeIntervalSince(start)

                // Update bucket estimated sizes from the full result set
                // (not the filtered set) so the user sees what's available
                // even in buckets they currently have unchecked.
                updateEstimatedSizes(from: results)

                // Pre-select safe items
                selectedResultIDs = Set(
                    filtered.filter { $0.safety == .safe }.map(\.id)
                )
                scanResults = filtered
                isScanRequested = false
                phase = .results
            } catch {
                guard !Task.isCancelled else { return }
                scanProgress.recordError(error.localizedDescription)
                isScanRequested = false
                phase = .idle
            }
        }
    }

    private func updateEstimatedSizes(from results: [ScanResult]) {
        var totals: [String: Int64] = [:]
        for result in results {
            for bucket in DevArtifactBucket.derive(from: result) {
                totals[bucket.id, default: 0] += result.size
            }
        }
        bucketEstimates = totals
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
