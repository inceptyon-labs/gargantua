import Foundation
import Observation

/// Observable progress state for scan operations.
///
/// Shared by scan adapters to drive UI progress indicators regardless of
/// which engine is running.
///
/// Usage:
/// ```swift
/// let progress = ScanProgress()
/// let results = try await adapter.scan(progress: progress)
/// // SwiftUI observes progress.isScanning, progress.fractionCompleted, etc.
/// ```
@Observable @MainActor
public final class ScanProgress {
    /// Whether a scan is currently in progress.
    public private(set) var isScanning: Bool = false

    /// Fraction completed (0.0–1.0). Stays at 0 until the adapter can estimate progress.
    public private(set) var fractionCompleted: Double = 0

    /// The category currently being scanned (e.g., "browser_cache").
    public private(set) var currentCategory: String?

    /// Path currently being measured (e.g. during a directory-size walk).
    /// Updated mid-rule so long sizing passes don't look frozen.
    public private(set) var currentPath: String?

    /// Running count of items discovered so far.
    public private(set) var itemsFound: Int = 0

    /// Running total of reclaimable bytes across results found so far.
    public private(set) var reclaimableBytes: Int64 = 0

    /// Non-fatal errors encountered during the scan.
    public private(set) var errors: [String] = []

    public init() {}

    // MARK: - Mutations (called by adapters)

    /// Signal that a scan has started.
    public func start() {
        isScanning = true
        fractionCompleted = 0
        currentCategory = nil
        currentPath = nil
        itemsFound = 0
        reclaimableBytes = 0
        errors = []
    }

    /// Update progress mid-scan.
    public func update(
        fractionCompleted: Double,
        currentCategory: String?,
        itemsFound: Int,
        reclaimableBytes: Int64
    ) {
        self.fractionCompleted = fractionCompleted
        self.currentCategory = currentCategory
        self.currentPath = nil
        self.itemsFound = itemsFound
        self.reclaimableBytes = reclaimableBytes
    }

    /// Update the path currently being measured. Fires from long sizing passes so
    /// the UI has something moving even when `fractionCompleted` is static.
    public func noteSizing(path: String?) {
        currentPath = path
    }

    /// Record a non-fatal error.
    public func recordError(_ message: String) {
        errors.append(message)
    }

    /// Signal that the scan has finished.
    public func finish(itemsFound: Int) {
        self.itemsFound = itemsFound
        fractionCompleted = 1
        currentCategory = nil
        currentPath = nil
        isScanning = false
    }
}
