import Foundation
import OSLog

private let scanLogger = Logger(subsystem: "com.gargantua.core", category: "FileHealthScanCoordinator")

@MainActor
final class FileHealthScanCoordinator {
    typealias EngineFactory = (_ scanRoots: [URL], _ profile: CleanupProfile) throws -> any ScanAdapter

    private var activeScanTask: Task<Void, Never>?
    private var scanGeneration: Int = 0

    func startScan(
        state: FileHealthContainerState,
        scanRoots: [URL]?,
        profile: CleanupProfile,
        engineFactory: EngineFactory
    ) {
        activeScanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        let roots = Self.resolvedScanRoots(scanRoots)
        let engine: any ScanAdapter
        do {
            engine = try engineFactory(roots, profile)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            scanLogger.error("Failed to build file-health engine: \(message, privacy: .public)")
            state.failScan(message)
            return
        }

        state.prepareForScan()
        let freshProgress = state.scanProgress

        activeScanTask = Task { [weak self] in
            do {
                let results = try await engine.scan(progress: freshProgress, observer: nil)
                let errors = await MainActor.run { freshProgress.errors }
                await MainActor.run { [weak self] in
                    guard let self, generation == scanGeneration else { return }
                    state.finishScan(results: results, errors: errors)
                    activeScanTask = nil
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                scanLogger.error("File-health scan failed: \(message, privacy: .public)")
                await MainActor.run { [weak self] in
                    guard let self, generation == scanGeneration else { return }
                    state.failScan(message)
                    activeScanTask = nil
                }
            }
        }
    }

    func cancelActiveScan(state: FileHealthContainerState) {
        activeScanTask?.cancel()
        activeScanTask = nil
        state.showConfirmation = false
        scanGeneration &+= 1
    }

    static func resolvedScanRoots(_ scanRoots: [URL]?) -> [URL] {
        if let scanRoots, !scanRoots.isEmpty {
            return scanRoots
        }
        return PathExpander.defaultScanRoots()
    }

    static func defaultEngine(
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
