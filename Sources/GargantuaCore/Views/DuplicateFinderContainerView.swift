import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.gargantua.core", category: "DuplicateFinderContainerView")

// MARK: - Duplicate Finder Container View

/// Scan state owner that feeds `DuplicateFinderView` with fclones results.
///
/// Builds a `ScanEngine` pipeline containing `FclonesAdapter` (per PRD §8.4
/// sequential pipeline rule) and renders one of four phases:
///   1. **Idle** — "Scan for duplicates" call-to-action.
///   2. **Scanning** — progress indicator.
///   3. **Results** — `DuplicateFinderView` with the discovered groups.
///   4. **Error** — binary-missing or scan-failure message with retry.
///
/// Destructive operations (trash) are still routed through the caller-provided
/// `onSendToTrash` closure so the Trust Layer boundary stays above this view.
public struct DuplicateFinderContainerView: View {
    public let scanRoots: [URL]?
    @Binding public var selectedIDs: Set<String>
    public let engineFactory: (_ scanRoots: [URL]) throws -> any ScanAdapter
    public let onSendToTrash: (([ScanResult]) -> Void)?
    public let onExplain: ((ScanResult) -> Void)?

    @State private var scanState: ScanState = .idle
    @State private var scanProgress = ScanProgress()
    @State private var activeScanTask: Task<Void, Never>?
    @State private var scanGeneration: Int = 0

    enum ScanState {
        case idle
        case scanning
        case results([ScanResult])
        case error(String)
    }

    /// Derive the terminal scan state from a finished scan's results + the
    /// errors an adapter recorded on `ScanProgress`.
    ///
    /// `FclonesAdapter` reports hard failures (timeout, non-zero exit, JSON
    /// parse failure) by appending to `progress.errors` and returning `[]`
    /// rather than throwing. If we don't translate that into `.error`, a
    /// silent scan failure would render as "No duplicates found" — the
    /// user would never know something broke.
    ///
    /// Partial successes (some results + some errors) still surface as
    /// `.results` so the user isn't blocked by a non-fatal read failure on a
    /// single subdirectory.
    static func deriveScanState(results: [ScanResult], errors: [String]) -> ScanState {
        if results.isEmpty, !errors.isEmpty {
            return .error(errors.joined(separator: "\n"))
        }
        return .results(results)
    }

    public init(
        scanRoots: [URL]? = nil,
        selectedIDs: Binding<Set<String>>,
        engine: (any ScanAdapter)? = nil,
        onSendToTrash: (([ScanResult]) -> Void)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil
    ) {
        self.scanRoots = scanRoots
        self._selectedIDs = selectedIDs
        self.onSendToTrash = onSendToTrash
        self.onExplain = onExplain
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
                switch scanState {
                case .idle:
                    idleView
                case .scanning:
                    scanningView
                case .results(let results):
                    DuplicateFinderView(
                        results: results,
                        selectedIDs: $selectedIDs,
                        onSendToTrash: onSendToTrash,
                        onExplain: onExplain
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
        VStack(spacing: GargantuaSpacing.space4) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)

            VStack(spacing: GargantuaSpacing.space2) {
                Text("Find duplicate files")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Runs `fclones group` across your scan roots. Review-by-default — nothing is selected automatically.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

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

    private var scanningView: some View {
        VStack(spacing: GargantuaSpacing.space4) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)

            VStack(spacing: GargantuaSpacing.space1) {
                Text("Scanning for duplicates…")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                if scanProgress.itemsFound > 0 {
                    Text("\(scanProgress.itemsFound) duplicate file\(scanProgress.itemsFound == 1 ? "" : "s") found so far")
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
        // Cancel any in-flight scan so its completion can't overwrite the new
        // scan's state. The generation id below is the belt to this suspenders
        // — cancellation is cooperative and may no-op if the task is already
        // at an un-cancellable point.
        activeScanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        let roots = resolvedScanRoots()
        let engine: any ScanAdapter
        do {
            engine = try engineFactory(roots)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to build duplicate-scan engine: \(message, privacy: .public)")
            scanState = .error(message)
            return
        }

        // Reset selection so a stale scan's ids can't point into a new result set.
        selectedIDs = []
        scanState = .scanning

        activeScanTask = Task {
            let outcome: ScanState
            do {
                let results = try await engine.scan(progress: scanProgress, observer: nil)
                let errors = await MainActor.run { scanProgress.errors }
                outcome = Self.deriveScanState(results: results, errors: errors)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("Duplicate scan failed: \(message, privacy: .public)")
                outcome = .error(message)
            }

            await MainActor.run {
                // Drop any completion that belongs to a superseded scan.
                guard generation == scanGeneration else { return }
                scanState = outcome
                activeScanTask = nil
            }
        }
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
