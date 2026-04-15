import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoCleanAdapter")

/// Adapter for the `mo clean` (Deep Clean) command.
///
/// Executes `mo clean --json` via `MoleRunner`, parses output through `MoleOutputParser`,
/// and returns typed `ScanResult` arrays with Trust Layer safety metadata.
///
/// Usage:
/// ```swift
/// let adapter = MoCleanAdapter(runner: MoleRunner())
/// let progress = ScanProgress()
/// let results = try await adapter.scan(paths: ["/Users/dev"], progress: progress)
/// ```
public struct MoCleanAdapter: Sendable {
    private let runner: MoleRunner

    public init(runner: MoleRunner) {
        self.runner = runner
    }

    /// Scan the given paths using `mo clean`.
    ///
    /// - Parameters:
    ///   - paths: File system paths to scan. Empty array scans the default locations.
    ///   - dryRun: When true, passes `--dry-run` so Mole scans without cleaning.
    ///             When false, the adapter still only returns scan results — actual
    ///             deletion is handled by `CleanupEngine` after user confirmation.
    ///   - progress: Optional progress observer for UI updates.
    /// - Returns: Array of scan results with Trust Layer safety classifications.
    public func scan(
        paths: [String] = [],
        dryRun: Bool = true,
        progress: ScanProgress? = nil
    ) async throws -> [ScanResult] {
        await progress?.start()

        var arguments = ["--json"]
        if dryRun {
            arguments.append("--dry-run")
        }
        arguments.append(contentsOf: paths)

        logger.info("Starting mo clean scan (dryRun: \(dryRun), paths: \(paths.count))")

        let runResult: MoleRunResult
        do {
            runResult = try await runner.run(command: "clean", arguments: arguments)
        } catch {
            await progress?.recordError(error.localizedDescription)
            await progress?.finish(itemsFound: 0)
            throw error
        }

        let results: [ScanResult]
        do {
            results = try MoleOutputParser.parse(runResult.stdout)
        } catch {
            await progress?.recordError("Failed to parse mo clean output: \(error.localizedDescription)")
            await progress?.finish(itemsFound: 0)
            throw error
        }

        logger.info("mo clean scan found \(results.count) items in \(String(format: "%.2f", runResult.duration))s")
        await progress?.finish(itemsFound: results.count)
        return results
    }
}
