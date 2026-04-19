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
///   4. **Error** — czkawka binary missing or scan failure with retry.
///
/// Destructive operations are intentionally not wired here. Tabs are
/// read-only until Trust Layer composition (see bean gargantua-i36a) lets
/// the Confirmation flow route File Health deletions the same way Duplicate
/// Finder will.
public struct FileHealthContainerView: View {
    public let scanRoots: [URL]?
    public let engineFactory: (_ scanRoots: [URL]) throws -> any ScanAdapter
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

    /// Derive the terminal scan state from results + adapter-recorded errors,
    /// mirroring ``DuplicateFinderContainerView/deriveScanState``.
    ///
    /// A silent "no findings" with errors would otherwise render as a clean
    /// bill of health — misleading the user about a genuine scan failure.
    static func deriveScanState(results: [ScanResult], errors: [String]) -> ScanState {
        if results.isEmpty, !errors.isEmpty {
            return .error(errors.joined(separator: "\n"))
        }
        return .results(results)
    }

    public init(
        scanRoots: [URL]? = nil,
        engine: (any ScanAdapter)? = nil,
        onExplain: ((ScanResult) -> Void)? = nil
    ) {
        self.scanRoots = scanRoots
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
                    FileHealthView(
                        results: results,
                        onExplain: onExplain,
                        onRescan: startScan
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
            engine = try engineFactory(roots)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to build file-health engine: \(message, privacy: .public)")
            scanState = .error(message)
            return
        }

        scanState = .scanning

        activeScanTask = Task {
            let outcome: ScanState
            do {
                let results = try await engine.scan(progress: scanProgress, observer: nil)
                let errors = await MainActor.run { scanProgress.errors }
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

    /// Build the default pipeline: a ``ScanEngine`` wrapping ``CzkawkaAdapter``.
    private static func defaultEngine(scanRoots: [URL]) throws -> any ScanAdapter {
        let czkawka = try CzkawkaAdapter.autoDetect(scanRoots: scanRoots)
        return ScanEngine(adapters: [czkawka])
    }
}
