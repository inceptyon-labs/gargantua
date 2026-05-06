import Foundation
import OSLog
import SwiftUI

// swiftlint:disable type_body_length
// Container coordinates scanning, clustering, AI cluster suggestions,
// and the inner FileHealthView. Tracked for split under the refactor bean.

private let logger = Logger(subsystem: "com.gargantua.core", category: "FileHealthContainerView")

// MARK: - File Health Container View

/// Scan-state owner for the File Health panel.
///
/// Accepts an externally owned `FileHealthContainerState` so scan results
/// survive sidebar navigation — switching away and back does not reset the
/// phase or discard findings.
public struct FileHealthContainerView: View {
    public typealias ClusterSuggestionHandler = @MainActor ([FileHealthClusterSummary]) async -> [FileHealthClusterSuggestion]

    public let state: FileHealthContainerState
    public let scanRoots: [URL]?
    public let profile: CleanupProfile
    public let engineFactory: (_ scanRoots: [URL], _ profile: CleanupProfile) throws -> any ScanAdapter
    public let onExplain: ((ScanResult) -> Void)?
    public let onSuggestClusters: ClusterSuggestionHandler?

    @State private var activeScanTask: Task<Void, Never>?
    @State private var scanGeneration: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let fileHealthSubtitlePool: [String] = [
        "Tracing duplicate file signatures",
        "Scanning for broken symlinks",
        "Cataloguing empty directories",
        "Comparing visual fingerprints",
        "Probing extension anomalies",
        "Measuring oversized file mass",
        "Detecting corrupted archives",
        "Mapping file health topology",
        "Cross-referencing checksum manifests",
        "Surveying orphaned fragments",
        "Analyzing entropy distributions",
        "Charting the debris field",
    ]

    public init(
        state: FileHealthContainerState,
        scanRoots: [URL]? = nil,
        profile: CleanupProfile = .deep,
        engine: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        onSuggestClusters: ClusterSuggestionHandler? = nil
    ) {
        self.state = state
        self.scanRoots = scanRoots
        self.profile = profile
        self.onExplain = onExplain
        self.onSuggestClusters = onSuggestClusters
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
                switch state.phase {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .cleaning:
                    cleanupProgressView
                case .summary:
                    summaryState()
                case .results:
                    FileHealthView(
                        results: state.scanResults,
                        warnings: state.scanWarnings,
                        session: state.session,
                        onExplain: onExplain,
                        onBack: { state.clearResults() },
                        onRescan: startScan,
                        onSendToTrash: { state.showConfirmation = true },
                        onSuggestClusters: onSuggestClusters
                    )
                case .error:
                    errorView(state.errorMessage ?? "Unknown scan error")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if state.showConfirmation {
                let selected = FileHealthCleanupFlow.selectedResults(
                    from: state.scanResults,
                    selectedIDs: state.session.selectedResultIDs
                )
                ConfirmationModalView(
                    items: selected,
                    allowsPermanentDelete: false,
                    onConfirm: { method in confirmCleanup(selected, method: method) },
                    onCancel: { state.showConfirmation = false }
                )
                .transition(.opacity)
            }
        }
        .onDisappear(perform: cancelActiveScan)
        .animation(.easeOut(duration: 0.15), value: state.showConfirmation)
    }

    // MARK: - Phase views

    private var idleView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "File Health",
                subtitle: "Cluster the redundancies. Surface what's broken.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "file-health-gargantua-gpt2",
                    fallbackSystemName: "stethoscope",
                    fallbackColor: GargantuaColors.ink4
                )

                VStack(spacing: GargantuaSpacing.space2) {
                    Text("Audit file health")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(
                        "Runs czkawka across your scan roots to surface empty, broken, temporary, oversized, "
                            + "and visually similar files. Review-by-default: nothing is selected automatically."
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

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            consoleHeader
            consoleSubtitle

            if state.scanProgress.fractionCompleted > 0 {
                progressBar
            }

            if let path = state.scanProgress.currentPath {
                Text(abbreviatedPath(path))
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            Spacer()

            HStack(spacing: GargantuaSpacing.space5) {
                Text("SCAN ROOTS: \(resolvedScanRoots().count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Text("CATEGORIES: \(CzkawkaCategory.allCases.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: state.scanProgress.currentPath)
        .animation(.easeInOut(duration: 0.3), value: state.scanProgress.fractionCompleted > 0)
    }

    private var consoleHeader: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("ENDURANCE · FILE HEALTH AUDIT")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(2)
                    .foregroundStyle(GargantuaColors.ink2)
                Spacer()
                AccretionDiskView(activityRate: 20)
            }

            HStack(spacing: GargantuaSpacing.space5) {
                if let cat = state.scanProgress.currentCategory {
                    Text("CATEGORY: \(prettifiedCategory(cat))")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink)
                        .animation(.none, value: cat)
                } else {
                    Text("CATEGORY: initializing")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink3)
                }

                if state.scanProgress.itemsFound > 0 {
                    Text("ITEMS FOUND: \(state.scanProgress.itemsFound)")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.accretion)
                        .transition(.opacity)
                }
            }

            Text("[TARS] Humor: 75% · Honesty: 90% · Pragmatism: 100%")
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
        }
    }

    private var consoleSubtitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            AccretionDiskView(activityRate: 20, size: 11)
            rotatingSubtitle
            scanEllipsis
        }
    }

    @ViewBuilder
    private var rotatingSubtitle: some View {
        let pool = Self.fileHealthSubtitlePool
        if reduceMotion {
            Text(pool[0])
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
        } else {
            TimelineView(.periodic(from: .now, by: 4.0)) { tlContext in
                let step = Int(tlContext.date.timeIntervalSinceReferenceDate / 4.0) % pool.count
                Text(pool[step])
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .id(step)
                    .animation(.easeInOut(duration: 0.5), value: step)
            }
        }
    }

    @ViewBuilder
    private var scanEllipsis: some View {
        if reduceMotion {
            Text("…")
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.45)) { tlContext in
                let step = Int(tlContext.date.timeIntervalSinceReferenceDate / 0.45) % 3
                Text(String(repeating: ".", count: step + 1))
                    .font(GargantuaFonts.body.italic())
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GargantuaColors.surface3)
                    .frame(height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(GargantuaColors.accretion)
                    .frame(width: max(0, geo.size.width * state.scanProgress.fractionCompleted), height: 3)
                    .animation(.linear(duration: 0.3), value: state.scanProgress.fractionCompleted)
            }
        }
        .frame(height: 3)
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

    func startScan() {
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
            state.failScan(message)
            return
        }

        let progress = state.scanProgress
        state.prepareForScan()
        // prepareForScan replaces scanProgress; capture the new one
        let freshProgress = state.scanProgress

        activeScanTask = Task {
            do {
                let results = try await engine.scan(progress: freshProgress, observer: nil)
                let errors = await MainActor.run { freshProgress.errors }
                await MainActor.run {
                    guard generation == scanGeneration else { return }
                    state.finishScan(results: results, errors: errors)
                    activeScanTask = nil
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("File-health scan failed: \(message, privacy: .public)")
                await MainActor.run {
                    guard generation == scanGeneration else { return }
                    state.failScan(message)
                    activeScanTask = nil
                }
            }
        }
        _ = progress // suppress unused warning
    }

    private func cancelActiveScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        state.showConfirmation = false
        scanGeneration &+= 1
    }

    func resolvedScanRoots() -> [URL] {
        if let scanRoots, !scanRoots.isEmpty {
            return scanRoots
        }
        return PathExpander.defaultScanRoots()
    }

    // MARK: - Default engine factory

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

    // MARK: - Helpers

    private func prettifiedCategory(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        if path == home { return "~" }
        return path
    }
}
