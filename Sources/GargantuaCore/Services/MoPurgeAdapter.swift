import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoPurgeAdapter")

/// Adapter for the `mo purge` (Dev Artifact Purge) command.
///
/// Executes `mo purge --json` via `MoleRunner`, parses output through `MoleOutputParser`,
/// and returns typed `ScanResult` arrays scoped to developer artifacts.
///
/// Unlike `MoCleanAdapter` (which scans all categories), purge is narrowly scoped to
/// dev artifacts: `node_modules`, `build/`, `.gradle/`, `Pods/`, etc.
///
/// Usage:
/// ```swift
/// let adapter = MoPurgeAdapter(runner: MoleRunner())
/// let progress = ScanProgress()
/// let results = try await adapter.scan(paths: ["/Users/dev/projects"], progress: progress)
/// ```
public struct MoPurgeAdapter: Sendable {
    /// Categories that `mo purge` is expected to produce.
    public static let purgeCategories: Set<String> = [
        "dev_artifacts", "docker", "homebrew"
    ]

    private let runner: MoleRunner

    public init(runner: MoleRunner) {
        self.runner = runner
    }

    /// Scan the given paths using `mo purge`.
    ///
    /// - Parameters:
    ///   - paths: File system paths to scan. Empty array scans the default locations.
    ///   - dryRun: When true, passes `--dry-run` so Mole scans without purging.
    ///             When false, the adapter still only returns scan results — actual
    ///             deletion is handled by `CleanupEngine` after user confirmation.
    ///   - progress: Optional progress observer for UI updates.
    /// - Returns: Array of scan results scoped to dev artifact categories.
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

        logger.info("Starting mo purge scan (dryRun: \(dryRun), paths: \(paths.count))")

        let runResult: MoleRunResult
        do {
            runResult = try await runner.run(command: "purge", arguments: arguments)
        } catch {
            await progress?.recordError(error.localizedDescription)
            await progress?.finish(itemsFound: 0)
            throw error
        }

        let allResults: [ScanResult]
        do {
            allResults = try MoleOutputParser.parse(runResult.stdout)
        } catch {
            await progress?.recordError("Failed to parse mo purge output: \(error.localizedDescription)")
            await progress?.finish(itemsFound: 0)
            throw error
        }

        // Filter to purge-scoped categories only. If `mo purge` returns items
        // outside dev artifact categories, exclude them as a safety measure.
        let results = allResults.filter { Self.purgeCategories.contains($0.category) }

        if results.count < allResults.count {
            let dropped = allResults.count - results.count
            logger.warning("Filtered \(dropped) items outside purge categories from mo purge output")
        }

        logger.info("mo purge scan found \(results.count) dev artifacts in \(String(format: "%.2f", runResult.duration))s")
        await progress?.finish(itemsFound: results.count)
        return results
    }
}
