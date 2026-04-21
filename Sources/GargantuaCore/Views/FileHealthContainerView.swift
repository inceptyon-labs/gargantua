import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "FileHealthContainerView")

// MARK: - File Health Container View

/// Scan-state owner for the File Health panel.
///
/// Builds a `ScanEngine` pipeline around ``CzkawkaAdapter`` (all eight
/// categories) and renders one of four phases:
///   1. **Idle** — call-to-action to run the scan.
///   2. **Scanning** — progress indicator with live "items found" count.
///   3. **Results** — ``FileHealthView`` grouped by category tabs.
///   4. **Cleaning** — selected findings are moved to Trash.
///   5. **Summary** — cleanup result, audit trail, and Trash reveal affordance.
///   6. **Error** — czkawka binary missing or scan failure with retry.
public struct FileHealthContainerView: View {
    public let scanRoots: [URL]?
    public let profile: CleanupProfile
    public let engineFactory: (_ scanRoots: [URL], _ profile: CleanupProfile) throws -> any ScanAdapter
    public let onExplain: ((ScanResult) -> Void)?

    @State var scanState: ScanState = .idle
    @State private var scanProgress: ScanProgress = ScanProgress()
    @State private var activeScanTask: Task<Void, Never>?
    @State private var scanGeneration: Int = 0
    @State var session = FileHealthSessionState()
    @State var showConfirmation = false
    @State var cleanupContext: CleanupContext?

    enum ScanState {
        case idle
        case scanning
        case cleaning
        case summary
        case results([ScanResult], warnings: [String])
        case error(String)
    }

    struct CleanupContext {
        let result: CleanupResult
        let remainingResults: [ScanResult]
        let warnings: [String]
    }

    /// Derive the terminal scan state from results + adapter-recorded errors.
    ///
    /// CzkawkaAdapter runs eight independent subcommands; per-category failures
    /// land in `errors` without blocking the scan. Three outcomes:
    ///
    /// - No results + errors → `.error` (every category failed, nothing to show).
    /// - Results + errors → `.results(_, warnings:)` so the UI can surface a
    ///   partial-failure banner; silent success would mislead the user into
    ///   thinking an incomplete audit was clean.
    /// - Results + no errors → plain `.results(_, warnings: [])`.
    static func deriveScanState(results: [ScanResult], errors: [String]) -> ScanState {
        if results.isEmpty, !errors.isEmpty {
            return .error(errors.joined(separator: "\n"))
        }
        return .results(results, warnings: errors)
    }

    public init(
        scanRoots: [URL]? = nil,
        profile: CleanupProfile = .deep,
        engine: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil
    ) {
        self.scanRoots = scanRoots
        self.profile = profile
        self.onExplain = onExplain
        if let engine {
            self.engineFactory = { _, _ in engine }
        } else {
            self.engineFactory = Self.defaultEngine
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch scanState {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .cleaning:
                    cleanupProgressView
                case .summary:
                    if let cleanupContext {
                        summaryState(context: cleanupContext)
                    }
                case .results(let results, let warnings):
                    FileHealthView(
                        results: results,
                        warnings: warnings,
                        session: session,
                        onExplain: onExplain,
                        onRescan: startScan,
                        onSendToTrash: { showConfirmation = true }
                    )
                case .error(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showConfirmation, case .results(let results, _) = scanState {
                let selected = FileHealthCleanupFlow.selectedResults(
                    from: results,
                    selectedIDs: session.selectedResultIDs
                )
                ConfirmationModalView(
                    items: selected,
                    allowsPermanentDelete: false,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .onDisappear(perform: cancelActiveScan)
        .animation(.easeOut(duration: 0.15), value: showConfirmation)
    }

    // MARK: - Phase views

    private var idleView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            Image(systemName: "stethoscope")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Audit file health")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text(
                    "Runs czkawka across your scan roots to surface empty, broken, temporary, oversized, "
                    + "and visually similar files. Review-by-default — nothing is selected automatically."
                )
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(action: startScan) {
                Text("Scan file health")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.accent)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var scanningView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Auditing file health…")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if scanProgress.itemsFound > 0 {
                    Text("\(scanProgress.itemsFound) item\(scanProgress.itemsFound == 1 ? "" : "s") found so far")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                } else {
                    Text("czkawka is walking your scan roots across eight categories. Large trees can take a few minutes.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.review)

            Text("File Health scan unavailable")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(action: startScan) {
                Text("Try again")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(GargantuaColors.surface3)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Scan orchestration

    private func startScan() {
        // Cancel any in-flight scan so its completion can't overwrite the new
        // scan's state. Generation id is the belt to this suspenders —
        // cancellation is cooperative and may no-op past un-cancellable points.
        activeScanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        let roots = resolvedScanRoots()
        let engine: any ScanAdapter
        do {
            engine = try engineFactory(roots, profile)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to build file-health engine: \(message, privacy: .public)")
            scanState = .error(message)
            return
        }

        // Fresh ScanProgress per attempt — a superseded scan's late error
        // append can't mutate the next scan's progress bookkeeping.
        let progress = ScanProgress()
        scanProgress = progress
        scanState = .scanning
        cleanupContext = nil
        showConfirmation = false
        session.clear()

        activeScanTask = Task {
            let outcome: ScanState
            do {
                let results = try await engine.scan(progress: progress, observer: nil)
                let errors = await MainActor.run { progress.errors }
                outcome = Self.deriveScanState(results: results, errors: errors)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("File-health scan failed: \(message, privacy: .public)")
                outcome = .error(message)
            }

            await MainActor.run {
                // Drop completions that belong to a superseded scan.
                guard generation == scanGeneration else { return }
                scanState = outcome
                if case .results(let results, _) = outcome {
                    session.finishScan(results: results)
                }
                activeScanTask = nil
            }
        }
    }

    /// Cancels the in-flight scan on view teardown so czkawka subprocess work
    /// doesn't outlive the panel. `scanGeneration` is bumped so any late
    /// completion from the cancelled task is discarded at the generation guard.
    private func cancelActiveScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        showConfirmation = false
        scanGeneration &+= 1
    }

    private func resolvedScanRoots() -> [URL] {
        if let scanRoots, !scanRoots.isEmpty {
            return scanRoots
        }
        return PathExpander.defaultScanRoots()
    }

    // MARK: - Default engine factory

    /// Build the default pipeline: a ``ScanEngine`` wrapping ``CzkawkaAdapter``.
    ///
    /// The active profile is passed into the adapter so czkawka findings pass
    /// through `SafetyClassifier` — profile-level age overrides (e.g.
    /// developer's `age > 30d → safe`) now apply to File Health results the
    /// same way they apply to YAML-driven rules.
    private static func defaultEngine(
        scanRoots: [URL],
        profile: CleanupProfile
    ) throws -> any ScanAdapter {
        let czkawka = try CzkawkaAdapter.autoDetect(
            scanRoots: scanRoots,
            profile: profile
        )
        return ScanEngine(adapters: [czkawka])
    }
}
