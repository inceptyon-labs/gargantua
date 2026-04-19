import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "ScanEngine")

/// Sequential multi-adapter scan pipeline.
///
/// Composes `ScanAdapter` conformers (`NativeScanAdapter`, `CzkawkaAdapter`,
/// `FclonesAdapter`, …) into a single `ScanAdapter` facade so views can treat
/// "the scan engine" as one opaque adapter regardless of how many backends
/// feed it.
///
/// Adapters are invoked in the order supplied and awaited one at a time to
/// satisfy PRD §8.4 "Sequential pipeline by default — never run fclones +
/// czkawka + native scanner simultaneously". `ScanEngine` never uses
/// `async let` or a `TaskGroup`; parallelism across adapters is an explicit
/// non-goal here.
///
/// Results from every adapter are concatenated in adapter order. Each adapter
/// is responsible for its own Trust Layer defaults — `ScanEngine` does not
/// re-classify results, so duplicate review-by-default semantics from
/// `FclonesAdapter` carry through unchanged.
///
/// ## Known limitation: shared `ScanProgress` across multiple adapters
///
/// The `ScanProgress` argument is forwarded to each child adapter as-is.
/// Adapters currently call `progress.start()` / `progress.finish()`
/// themselves, so with `n > 1` adapters the aggregate `fractionCompleted`
/// and `itemsFound` values oscillate instead of rising monotonically, and
/// `isScanning` flickers false between adapter boundaries. This is
/// acceptable for the current single-adapter duplicate-finder pipeline;
/// multi-adapter UIs (e.g. Deep Clean composing native + czkawka) should
/// either pass `nil` for `progress` to each child and synthesise
/// aggregate progress here, or give each child its own `ScanProgress`.
public struct ScanEngine: ScanAdapter {
    private let adapters: [any ScanAdapter]

    public init(adapters: [any ScanAdapter]) {
        self.adapters = adapters
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    public func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        guard !adapters.isEmpty else {
            logger.info("ScanEngine: no adapters configured, returning empty results")
            return []
        }

        var merged: [ScanResult] = []
        for (index, adapter) in adapters.enumerated() {
            logger.info(
                "ScanEngine: running adapter \(index + 1, privacy: .public)/\(self.adapters.count, privacy: .public)"
            )
            let results = try await adapter.scan(progress: progress, observer: observer)
            merged.append(contentsOf: results)
        }
        logger.info(
            "ScanEngine: pipeline complete, \(merged.count, privacy: .public) total results from \(self.adapters.count, privacy: .public) adapter(s)"
        )
        return merged
    }
}
