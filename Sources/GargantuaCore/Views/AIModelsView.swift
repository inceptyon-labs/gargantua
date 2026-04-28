import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "AIModelsView")

/// Scan and clean downloaded LLM / diffusion model storage.
///
/// Mirrors DevArtifactScanView's phase machine (idle → scanning → results →
/// cleaning → summary) but presents a DiskExplorerView-style centered idle
/// CTA because there's only one logical scope (AI models) — no per-category
/// checkboxes. Runs a `NativeScanAdapter` against the `aiModels` profile and
/// renders results with `ScanBucketListView`.
public struct AIModelsView: View {
    private let profile: CleanupProfile
    private let adapterOverride: (any ScanAdapter)?
    private let scanRoots: [URL]?

    @State private var scanProgress = ScanProgress()
    @State private var scanResults: [ScanResult]?
    @State private var scanDuration: TimeInterval = 0
    @State private var selectedResultIDs: Set<String> = []
    @State private var isScanRequested = false
    @State private var showConfirmation = false
    @State private var activeCleanupMethod: CleanupMethod = .trash
    @State private var cleanupResult: CleanupResult?
    @State private var phase: DeepCleanPhase = .idle
    @State private var pathStream = PathStreamViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onExplain: ((ScanResult) -> Void)?
    private let onAdvisory: (([ScanResult]) -> Void)?
    private let onResolveFilter: ((String) async -> ScanFilterSet?)?

    public init(
        profile: CleanupProfile = .aiModels,
        scanRoots: [URL]? = nil,
        adapter: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onAdvisory: (([ScanResult]) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.profile = profile
        self.scanRoots = scanRoots
        self.adapterOverride = adapter
        self.onExplain = onExplain
        self.onAdvisory = onAdvisory
        self.onResolveFilter = onResolveFilter
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch phase {
                case .idle:
                    idleView
                        .transition(phaseTransition)
                case .scanning, .cleaning:
                    EventHorizonConsoleView(
                        context: .aiModels(phase: phase, profileName: profile.name),
                        stream: pathStream
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

    /// Asymmetric phase transition matching SmartUninstaller / Deep Clean / Dev Purge.
    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92))
                .combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -16))
        )
    }

    // MARK: - Idle CTA

    private var idleView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Models")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "brain")
                    .font(.system(size: 36))
                    .foregroundStyle(GargantuaColors.ink3)

                Text("Locate your downloaded AI models")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(
                    "Surface multi-GB model files left by Ollama, LM Studio, ComfyUI, "
                        + "and friends — plus orphan .gguf / .safetensors weights forgotten "
                        + "in your folders."
                )
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

                Button(action: startScan) {
                    Text("Scan AI Models")
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

            if !scanProgress.errors.isEmpty {
                scanWarningsBanner
            }

            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner
            }
        }
    }

    // MARK: - Profile override banner

    private var profileOverrideBanner: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.accent)

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

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "AI Models",
                onBack: {
                    scanResults = nil
                    pathStream.clear()
                    phase = .idle
                },
                onRescan: { startScan() },
                isBusy: scanProgress.isScanning
            )

            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            if !scanProgress.errors.isEmpty {
                scanWarningsBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

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
                onAdvisoryForReview: onAdvisory,
                onResolveNaturalLanguageFilter: onResolveFilter
            )
        }
    }

    // MARK: - Summary

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
}

// MARK: - Color helpers

extension AIModelsView {
    fileprivate func outcomeAccentColor(_ accent: SingularityCloseMessage.OutcomeAccent) -> Color {
        switch accent {
        case .safe: return GargantuaColors.safe
        case .accretion: return GargantuaColors.accretion
        case .protected: return GargantuaColors.protected_
        }
    }

    fileprivate func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

// MARK: - Actions

extension AIModelsView {
    fileprivate func confirmCleanup(_ items: [ScanResult], method: CleanupMethod) {
        showConfirmation = false
        activeCleanupMethod = method
        pathStream.clear()
        phase = .cleaning
        Task {
            let engine = CleanupEngine()
            let result = await engine.clean(items, method: method, observer: pathStream)
            do {
                try AuditWriter().record(result: result)
            } catch {
                logger.warning("Failed to write audit entry: \(error.localizedDescription)")
            }
            // Hold the EventHorizon console long enough for spaghettify
            // animations to finish before switching to the summary card.
            if !result.itemResults.filter(\.succeeded).isEmpty, !reduceMotion {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
            cleanupResult = result
            phase = .summary
        }
    }

    private func dismissSummary() {
        cleanupResult = nil
        scanResults = nil
        activeCleanupMethod = .trash
        pathStream.clear()
        phase = .idle
    }

    fileprivate func startScan() {
        isScanRequested = true
        scanProgress = ScanProgress()
        pathStream.clear()
        phase = .scanning
        Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots)
                let results = try await adapter.scan(progress: scanProgress, observer: pathStream)

                scanDuration = Date().timeIntervalSince(start)
                // Default selection mirrors Dev Purge: pre-check `safe` items
                // so the user can fast-path obvious wins. AI model rules are
                // mostly `review`, so this nudges nothing destructive.
                selectedResultIDs = Set(
                    results.filter { $0.safety == .safe }.map(\.id)
                )
                scanResults = results
                isScanRequested = false
                phase = .results
            } catch {
                scanProgress.recordError(error.localizedDescription)
                isScanRequested = false
                phase = .idle
            }
        }
    }
}
