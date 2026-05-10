import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DuplicateFinderContainerView")

// MARK: - Duplicate Finder Container View

/// Renders the Duplicate Finder flow against a `DuplicateFinderContainerState`
/// owned by `MainContentView` so the cache, in-flight task, and last-scan
/// timestamp survive sidebar navigation.
///
/// Builds a `ScanEngine` pipeline containing `FclonesAdapter` (per PRD §8.4
/// sequential pipeline rule) and renders one of four phases:
///   1. **Idle** — "Scan for duplicates" call-to-action, or a "View previous
///      results / Scan again" pair when a cached scan exists.
///   2. **Scanning** — progress indicator.
///   3. **Results** — `DuplicateFinderView` with the discovered groups.
///   4. **Error** — binary-missing or scan-failure message with retry.
///
/// Destructive operations (trash) are still routed through the caller-provided
/// `onSendToTrash` closure so the Trust Layer boundary stays above this view.
public struct DuplicateFinderContainerView: View {
    public let scanRoots: [URL]?
    @Bindable public var state: DuplicateFinderContainerState
    @Binding public var selectedIDs: Set<String>
    public let engineFactory: (_ scanRoots: [URL]) throws -> any ScanAdapter
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?
    public let persistence: PersistenceController?

    public init(
        state: DuplicateFinderContainerState,
        scanRoots: [URL]? = nil,
        selectedIDs: Binding<Set<String>>,
        engine: (any ScanAdapter)? = nil,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil,
        persistence: PersistenceController? = nil
    ) {
        self.state = state
        self.scanRoots = scanRoots
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
        self.persistence = persistence
        if let engine {
            self.engineFactory = { _ in engine }
        } else {
            self.engineFactory = Self.defaultEngine
        }
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            Group {
                switch state.scanState {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .results(let results):
                    DuplicateFinderView(
                        results: results,
                        selectedIDs: $selectedIDs,
                        onSendToTrash: onSendToTrash,
                        onExplain: onExplain,
                        onBack: { state.returnToIdle() },
                        onRefresh: refreshResults,
                        onRescan: startScan,
                        persistence: persistence
                    )
                case .error(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Phase views

    private var idleView: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Duplicate Finder",
                subtitle: "Group duplicate bytes across your filesystem.",
                subtitleStyle: .voice
            )

            VStack(spacing: GargantuaSpacing.space4) {
                Spacer()

                GargantuaBrandIcon(
                    resourceName: "duplicates-gargantua-gpt2",
                    fallbackSystemName: "doc.on.doc",
                    fallbackColor: GargantuaColors.ink4
                )

                VStack(spacing: GargantuaSpacing.space2) {
                    Text("Find duplicate files")
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(idleSubtitle)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: GargantuaSpacing.space3) {
                    if state.cachedResults != nil {
                        Button(action: showCachedResults) {
                            Text("View previous results")
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

                        Button(action: startScan) {
                            Text("Scan again")
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
                    } else {
                        Button(action: startScan) {
                            Text("Scan for duplicates")
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

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idleSubtitle: String {
        guard let cached = state.cachedResults, let when = state.cachedAt else {
            return "Runs `fclones group` across your scan roots. Review-by-default — nothing is selected automatically."
        }
        let groups = DuplicateGrouper.group(cached).count
        let files = cached.count
        return "Last scan \(relativeTime(since: when)): \(groups) group\(groups == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")."
    }

    private func relativeTime(since date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var scanningView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            AccretionDiskView(activityRate: 18, size: 64, color: GargantuaColors.accent)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Scanning for duplicates…")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if state.scanProgress.itemsFound > 0 {
                    Text("\(state.scanProgress.itemsFound) duplicate file\(state.scanProgress.itemsFound == 1 ? "" : "s") found so far")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                } else {
                    Text("fclones is walking your scan roots. Large trees can take a few minutes.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.review)

            Text("Scan unavailable")
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
        // The state class cancels any in-flight task, bumps the generation,
        // and wipes the cache up-front (a Rescan must not leave stale data
        // around if the new scan ultimately fails).
        state.prepareForScan()
        let generation = state.scanGeneration

        let roots = resolvedScanRoots()
        let engine: any ScanAdapter
        do {
            engine = try engineFactory(roots)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to build duplicate-scan engine: \(message, privacy: .public)")
            state.failScan(message)
            return
        }

        // Reset selection so a stale scan's ids can't point into a new result set.
        selectedIDs = []
        let progress = state.scanProgress

        state.activeScanTask = Task {
            let resultsOrError: Result<([ScanResult], [String]), Error>
            do {
                let results = try await engine.scan(progress: progress, observer: nil)
                let errors = await MainActor.run { progress.errors }
                resultsOrError = .success((results, errors))
            } catch {
                resultsOrError = .failure(error)
            }

            await MainActor.run {
                // Drop any completion that belongs to a superseded scan.
                guard generation == state.scanGeneration else { return }
                switch resultsOrError {
                case .success(let (results, errors)):
                    state.finishScan(results: results, errors: errors)
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    logger.error("Duplicate scan failed: \(message, privacy: .public)")
                    state.failScan(message)
                }
                state.activeScanTask = nil
            }
        }
    }

    /// Re-stat every cached path off the main actor, drop missing ones, and
    /// publish the pruned list. Cheap relative to a full fclones run — even
    /// for tens of thousands of paths it's a few hundred ms of stat() calls.
    private func refreshResults() {
        guard !state.isRefreshing, case .results(let current) = state.scanState else { return }
        state.isRefreshing = true

        let snapshot = current
        Task.detached(priority: .userInitiated) {
            let paths = snapshot.map(\.path)
            var existing: Set<String> = []
            existing.reserveCapacity(paths.count)
            let fileManager = FileManager.default
            for path in paths {
                if fileManager.fileExists(atPath: path) {
                    existing.insert(path)
                }
            }
            let pruned = DuplicateFinderRefresh.prune(
                results: snapshot,
                existingPaths: existing
            )

            await MainActor.run {
                // Bail if a Rescan landed while we were stat()-ing — the new
                // scan's results win.
                guard case .results = state.scanState else {
                    state.isRefreshing = false
                    return
                }
                selectedIDs = DuplicateFinderRefresh.sanitizeSelection(
                    selectedIDs: selectedIDs,
                    against: pruned
                )
                state.applyRefresh(pruned: pruned)
                state.isRefreshing = false
            }
        }
    }

    /// Re-enter results from idle using the cached scan output, no work needed.
    private func showCachedResults() {
        guard let cached = state.cachedResults else { return }
        // Sanitize selection in case anything changed about the cached set
        // (e.g. a previous refresh dropped rows while idle).
        selectedIDs = DuplicateFinderRefresh.sanitizeSelection(
            selectedIDs: selectedIDs,
            against: cached
        )
        state.showCachedResults()
    }

    private func resolvedScanRoots() -> [URL] {
        if let scanRoots, !scanRoots.isEmpty {
            return scanRoots
        }
        return PathExpander.defaultScanRoots()
    }

    // MARK: - Default engine factory

    /// Build the default pipeline: a `ScanEngine` wrapping `FclonesAdapter`.
    ///
    /// Wrapped in an engine rather than returned as a bare adapter so future
    /// work can compose additional duplicate-aware adapters without changing
    /// the call site.
    private static func defaultEngine(scanRoots: [URL]) throws -> any ScanAdapter {
        let fclones = try FclonesAdapter.autoDetect(scanRoots: scanRoots)
        return ScanEngine(adapters: [fclones])
    }
}
