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

// swiftlint:disable type_body_length
// Encapsulates the full Dev Purge flow (detection → category selection →
// scan → results) in one screen. Tracked for split under the refactor bean.

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

    public init(
        profile: CleanupProfile = .developer,
        scanRoots: [URL]? = nil,
        adapter: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.profile = profile
        self.scanRoots = scanRoots
        self.adapterOverride = adapter
        self.onExplain = onExplain
        self.onResolveFilter = onResolveFilter
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch phase {
                case .idle:
                    categorySelectionView
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
                        resultsView(results)
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

    // MARK: - Bucket Selection

    private var categorySelectionView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Dev Artifact Purge",
                subtitle: "Find build artifacts the tools forgot. Caches, DerivedData, node_modules — pulled straight off the disk.",
                subtitleStyle: .voice
            )

            ZStack {
                switch detectionState {
                case .pending, .detecting:
                    detectingPlaceholder
                        .transition(.opacity)
                case .complete:
                    VStack(spacing: 0) {
                        bucketToolbar

                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                                bucketSection(
                                    title: "ECOSYSTEMS",
                                    buckets: bucketsInTier(.ecosystem)
                                )

                                bucketSection(
                                    title: "CROSS-CUTTING",
                                    buckets: bucketsInTier(.crossCutting)
                                )
                            }
                            .padding(.bottom, GargantuaSpacing.space2)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Profile override banner
            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Scan button / progress
            scanFooter
        }
        .task(id: profile.id) {
            await detectEcosystemsIfNeeded()
        }
    }

    private var detectingPlaceholder: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            AccretionDiskView(activityRate: 12, size: 28, color: GargantuaColors.accretion)
            Text("Detecting ecosystems…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bucketToolbar: some View {
        let totalBuckets = DevArtifactBucket.catalog.count
        let selectedCount = selectedBucketIDs.count
        let detectedCount = detectedEcosystemIDs.count

        return HStack(spacing: GargantuaSpacing.space3) {
            toolbarButton("All", action: selectAllBuckets)
            toolbarDot
            toolbarButton("None", action: deselectAllBuckets)
            toolbarDot
            toolbarButton("Invert", action: invertBucketSelection)

            Spacer()

            HStack(spacing: GargantuaSpacing.space2) {
                Text("\(selectedCount) / \(totalBuckets) selected")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()

                toolbarDot

                detectionChip(count: detectedCount)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    /// Right-side toolbar chip reporting how many ecosystems the probe
    /// found on disk. Always renders so the user knows detection happened
    /// — including the zero-detection case, which falls back to the
    /// ink3 "using defaults" state instead of silently disappearing.
    @ViewBuilder
    private func detectionChip(count: Int) -> some View {
        if count > 0 {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(GargantuaColors.safe)
                    .frame(width: 5, height: 5)
                Text("\(count) on disk")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .monospacedDigit()
            }
        } else {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(GargantuaColors.ink4)
                    .frame(width: 5, height: 5)
                Text("0 on disk: using defaults")
                    .font(GargantuaFonts.caption.italic())
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    private func toolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
    }

    private var toolbarDot: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink4)
    }

    private func bucketsInTier(_ tier: DevArtifactBucket.Tier) -> [DevArtifactBucket] {
        DevArtifactBucket.catalog
            .filter { $0.tier == tier }
            .sorted(by: { $0.priority < $1.priority })
    }

    private func bucketSection(title: String, buckets: [DevArtifactBucket]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.top, GargantuaSpacing.space3)
                .padding(.bottom, GargantuaSpacing.space2)

            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                bucketRow(bucket)

                if index < buckets.count - 1 {
                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(height: 1)
                }
            }
        }
    }

    private func bucketRow(_ bucket: DevArtifactBucket) -> some View {
        let isSelected = selectedBucketIDs.contains(bucket.id)
        let isDetected = bucket.tier == .ecosystem && detectedEcosystemIDs.contains(bucket.id)

        return Button {
            toggleBucket(bucket.id)
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.borderEm)
                    .frame(width: 16, height: 16)

                Image(systemName: bucket.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(bucket.tier == .crossCutting ? GargantuaColors.ink : GargantuaColors.ink2)
                    .frame(width: 20, alignment: .center)

                Text(bucket.label)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                if isDetected {
                    Circle()
                        .fill(GargantuaColors.safe)
                        .frame(width: 5, height: 5)
                        .help("Detected on disk")
                }

                Spacer()

                // Estimated size from last scan
                if let size = bucketEstimates[bucket.id], size > 0 {
                    Text(AlertItem.formatBytes(size))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, GargantuaSpacing.space4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bucket.label)
        .accessibilityValue(isSelected ? "selected, on disk" : (isDetected ? "not selected, on disk" : "not selected"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var scanWarningsBanner: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            ForEach(Array(scanProgress.errors.enumerated()), id: \.offset) { _, message in
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)
                    Text(message)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    private var profileOverrideBanner: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.ink2)

                Text("Profile: \(profile.name)")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }

            ForEach(Array(profile.safetyOverrides.enumerated()), id: \.offset) { _, override_ in
                HStack(spacing: GargantuaSpacing.space1) {
                    Circle()
                        .fill(safetyColor(override_.safety))
                        .frame(width: 6, height: 6)

                    Text("Auto-classified as \(override_.safety.displayName): \(override_.explanationSuffix ?? override_.condition)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .padding(.leading, GargantuaSpacing.space4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    private var scanFooter: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if scanProgress.isScanning || isScanRequested {
                AccretionDiskView(activityRate: 18, size: 14, color: GargantuaColors.accretion)

                Text(scanProgress.currentCategory ?? "Scanning…")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()
            } else {
                if let firstError = scanProgress.errors.first {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)

                    Text(firstError)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(1)
                } else {
                    footerEvidence
                }

                Spacer()

                Button(action: startScan) {
                    Text("Scan Selected Buckets")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(selectedBucketIDs.isEmpty || detectionState != .complete)
                .opacity(selectedBucketIDs.isEmpty || detectionState != .complete ? 0.5 : 1)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    /// Aggregate evidence shown when the scan button is the next action.
    /// Pre-scan: "First scan — sizes will appear after." Post-scan, with a
    /// non-empty selection: "N selected · X GB estimated." Empty selection:
    /// "Select at least one bucket to scan."
    @ViewBuilder
    private var footerEvidence: some View {
        if selectedBucketIDs.isEmpty {
            Text("Select at least one bucket to scan.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        } else {
            let estimatedTotal = selectedBucketIDs.reduce(into: Int64(0)) { sum, id in
                sum += bucketEstimates[id, default: 0]
            }
            HStack(spacing: GargantuaSpacing.space2) {
                Text("\(selectedBucketIDs.count) selected")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()

                if estimatedTotal > 0 {
                    Text("·")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Text("\(AlertItem.formatBytes(estimatedTotal)) estimated")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                } else {
                    Text("·")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Text("first scan: sizes appear after")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Dev Artifact Purge",
                onBack: {
                    scanResults = nil
                    pathStream.clear()
                    phase = .idle
                },
                onRescan: { startScan() },
                isBusy: scanProgress.isScanning
            )

            // Profile override banner in results view too
            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            // Walker-cap warnings from the scan (e.g., "Stopped scanning … time cap reached").
            // Partial-result scans can otherwise look complete in the bucket view.
            if !scanProgress.errors.isEmpty {
                scanWarningsBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            // Three-bucket scan results
            ScanBucketListView(
                results: results,
                scanDuration: scanDuration,
                selectedIDs: $selectedResultIDs,
                onExplain: onExplain,
                onClean: { showConfirmation = true },
                onCancel: {
                    scanResults = nil
                    pathStream.clear()
                    phase = .idle
                },
                onResolveNaturalLanguageFilter: onResolveFilter
            )
        }
    }
}

// MARK: - Actions

//
// Extracted into an in-file extension so DevArtifactScanView's
// primary body stays under the 350-line type_body_length threshold.

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
                    ?? CompositeScanAdapter(
                        primary: NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots),
                        bestEffort: [
                            CommandActionScanAdapter.loadDefaults(
                                categories: Set(profile.categories)
                            )
                        ]
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

// MARK: - Helpers

extension DevArtifactScanView {
    fileprivate func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
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
