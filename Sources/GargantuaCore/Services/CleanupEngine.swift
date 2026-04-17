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
    /// How the items were removed.
    public let cleanupMethod: CleanupMethod
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

    public init(
        itemResults: [CleanupItemResult],
        cleanupMethod: CleanupMethod = .trash,
        completedAt: Date = Date()
    ) {
        self.itemResults = itemResults
        self.cleanupMethod = cleanupMethod
        self.completedAt = completedAt
    }
}

/// Removes files via the selected cleanup method and tracks per-item results.
public final class CleanupEngine: Sendable {
    public init() {}

    /// Remove the given scan results with the selected cleanup method.
    ///
    /// Each file is handled individually so partial failures are tracked.
    /// Returns a `CleanupResult` with per-item success/failure details.
    @MainActor
    public func clean(_ items: [ScanResult], method: CleanupMethod = .trash) async -> CleanupResult {
        var results: [CleanupItemResult] = []

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            let result = await cleanSingle(url: url, item: item, method: method)
            results.append(result)
        }

        return CleanupResult(itemResults: results, cleanupMethod: method)
    }

    @MainActor
    private func cleanSingle(url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult {
        switch method {
        case .trash:
            await recycleSingle(url: url, item: item)
        case .delete:
            deleteSingle(url: url, item: item)
        }
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

    /// Permanently delete a single URL.
    private func deleteSingle(url: URL, item: ScanResult) -> CleanupItemResult {
        do {
            try FileManager.default.removeItem(at: url)
            return CleanupItemResult(item: item, succeeded: true)
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }
}
