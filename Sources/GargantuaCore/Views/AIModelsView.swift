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
///
/// State lives on an injected `AIModelsState` so a scan triggered here
/// survives sidebar navigation. The header's Refresh / Rescan buttons are
/// the only ways to clear cached results.
public struct AIModelsView: View {
    private let profile: CleanupProfile
    private let adapterOverride: (any ScanAdapter)?
    private let scanRoots: [URL]?
    private let session: AIModelsState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onExplain: ((ScanResult) -> Void)?
    private let onAdvisory: (([ScanResult]) -> Void)?
    private let onResolveFilter: ((String) async -> ScanFilterSet?)?

    public init(
        profile: CleanupProfile = .aiModels,
        scanRoots: [URL]? = nil,
        adapter: (any ScanAdapter)? = nil,
        session: AIModelsState,
        onExplain: ((ScanResult) -> Void)? = nil,
        onAdvisory: (([ScanResult]) -> Void)? = nil,
        onResolveFilter: ((String) async -> ScanFilterSet?)? = nil
    ) {
        self.profile = profile
        self.scanRoots = scanRoots
        self.adapterOverride = adapter
        self.session = session
        self.onExplain = onExplain
        self.onAdvisory = onAdvisory
        self.onResolveFilter = onResolveFilter
    }

    @MainActor
    public init(
        profile: CleanupProfile = .aiModels,
        adapter: (any ScanAdapter)? = nil
    ) {
        self.init(
            profile: profile,
            scanRoots: nil,
            adapter: adapter,
            session: AIModelsState(),
            onExplain: nil,
            onAdvisory: nil,
            onResolveFilter: nil
        )
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            ZStack {
                switch session.phase {
                case .idle:
                    idleView
                        .transition(phaseTransition)
                case .scanning, .cleaning:
                    EventHorizonConsoleView(
                        context: .aiModels(phase: session.phase, profileName: profile.name),
                        stream: session.pathStream
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

                if !session.scanProgress.errors.isEmpty {
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
            ForEach(Array(session.scanProgress.errors.enumerated()), id: \.offset) { _, message in
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
                onBack: { session.clearResults() },
                onRescan: { startScan() },
                isBusy: session.isScanning
            )

            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            if !session.scanProgress.errors.isEmpty {
                scanWarningsBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

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
}

// MARK: - Summary + color helpers

extension AIModelsView {
    fileprivate func summaryState(result: CleanupResult) -> some View {
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
                session.dismissSummary()
            }
            Spacer()
        }
        .padding(GargantuaSpacing.space6)
    }

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
        session.beginCleanup(method: method)
        Task {
            let engine = CleanupEngine()
            let result = await engine.clean(items, method: method, observer: session.pathStream)
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
            session.finishCleanup(result: result)
        }
    }

    fileprivate func startScan() {
        session.prepareForScan()
        Task {
            let start = Date()
            do {
                let adapter: any ScanAdapter = try adapterOverride
                    ?? NativeScanAdapter.loadDefaults(profile: profile, scanRoots: scanRoots)
                let results = try await adapter.scan(progress: session.scanProgress, observer: session.pathStream)

                let duration = Date().timeIntervalSince(start)
                session.finishScan(results: results, duration: duration)
            } catch {
                session.failScan(error.localizedDescription)
            }
        }
    }
}
