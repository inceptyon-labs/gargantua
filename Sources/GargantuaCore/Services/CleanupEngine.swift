import AppKit
import Foundation

/// Result of cleaning a single item.
public struct CleanupItemResult: Sendable {
    /// The scan result that was cleaned.
    public let item: ScanResult
    /// Whether the cleanup succeeded.
    public let succeeded: Bool
    /// The new URL (Trash location) if the item was moved successfully.
    public let trashURL: URL?
    /// Error description if the cleanup failed.
    public let error: String?

    public init(item: ScanResult, succeeded: Bool, trashURL: URL? = nil, error: String? = nil) {
        self.item = item
        self.succeeded = succeeded
        self.trashURL = trashURL
        self.error = error
    }
}

/// Aggregate result of a cleanup operation.
public struct CleanupResult: Sendable {
    /// Per-item results.
    public let itemResults: [CleanupItemResult]
    /// Timestamp when the cleanup completed.
    public let completedAt: Date

    public var succeededItems: [CleanupItemResult] {
        itemResults.filter(\.succeeded)
    }

    public var failedItems: [CleanupItemResult] {
        itemResults.filter { !$0.succeeded }
    }

    public var totalFreed: Int64 {
        succeededItems.reduce(Int64(0)) { $0 + $1.item.size }
    }

    public var allSucceeded: Bool {
        failedItems.isEmpty
    }

    public init(itemResults: [CleanupItemResult], completedAt: Date = Date()) {
        self.itemResults = itemResults
        self.completedAt = completedAt
    }
}

/// Moves files to Trash via NSWorkspace and tracks per-item results.
public final class CleanupEngine: Sendable {
    public init() {}

    /// Move the given scan results to Trash.
    ///
    /// Each file is recycled individually so partial failures are tracked.
    /// Returns a `CleanupResult` with per-item success/failure details.
    @MainActor
    public func clean(_ items: [ScanResult]) async -> CleanupResult {
        var results: [CleanupItemResult] = []

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            let result = await recycleSingle(url: url, item: item)
            results.append(result)
        }

        return CleanupResult(itemResults: results)
    }

    /// Recycle a single URL via NSWorkspace, returning the Trash URL on success.
    @MainActor
    private func recycleSingle(url: URL, item: ScanResult) async -> CleanupItemResult {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { trashedURLs, error in
                if let error {
                    continuation.resume(returning: CleanupItemResult(
                        item: item,
                        succeeded: false,
                        error: error.localizedDescription
                    ))
                } else {
                    continuation.resume(returning: CleanupItemResult(
                        item: item,
                        succeeded: true,
                        trashURL: trashedURLs[url]
                    ))
                }
            }
        }
    }
}
