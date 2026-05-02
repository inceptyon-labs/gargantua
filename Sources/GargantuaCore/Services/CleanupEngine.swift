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
    /// Override the home directory used to resolve `~/.Trash`. Tests only.
    private let homeDirectory: URL
    private let trashMover: any TrashMoving
    private let protectedRootPolicy: ProtectedRootPolicy

    public init() {
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.trashMover = FinderFirstTrashMover()
        self.protectedRootPolicy = .loadDefault()
    }

    /// Test-only initializer. Use the default `init()` in app code.
    internal init(
        homeDirectoryForTesting: URL,
        trashMover: any TrashMoving = FinderFirstTrashMover(),
        protectedRootPolicy: ProtectedRootPolicy = .loadDefault()
    ) {
        self.homeDirectory = homeDirectoryForTesting
        self.trashMover = trashMover
        self.protectedRootPolicy = protectedRootPolicy
    }

    /// Remove the given scan results with the selected cleanup method.
    ///
    /// Each file is handled individually so partial failures are tracked.
    /// Returns a `CleanupResult` with per-item success/failure details.
    @MainActor
    public func clean(_ items: [ScanResult], method: CleanupMethod = .trash) async -> CleanupResult {
        await clean(items, method: method, observer: nil)
    }

    /// Variant that emits a `ScanProgressEvent` per item to feed the
    /// EventHorizon console during the cleaning phase. Successful removals
    /// surface as `.match` (with bytes); failures surface as `.failed`.
    @MainActor
    public func clean(
        _ items: [ScanResult],
        method: CleanupMethod = .trash,
        observer: (any ScanProgressObserving)?
    ) async -> CleanupResult {
        var results: [CleanupItemResult] = []

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            let result = await cleanSingle(url: url, item: item, method: method)
            if let observer {
                if result.succeeded {
                    observer.didEmit(ScanProgressEvent(
                        path: item.path,
                        outcome: .match,
                        bytes: item.size
                    ))
                } else {
                    observer.didEmit(ScanProgressEvent(
                        path: item.path,
                        outcome: .failed(reason: result.error ?? "unknown error")
                    ))
                }
            }
            results.append(result)
        }

        return CleanupResult(itemResults: results, cleanupMethod: method)
    }

    @MainActor
    private func cleanSingle(url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult {
        if let protectedRoot = protectedRootPolicy.protectionReason(for: url, homeDirectory: homeDirectory) {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Skipped \(protectedRoot): \(url.path)"
            )
        }

        // Special case: the Trash container itself cannot be removed or
        // recycled. Empty its contents instead so "Move to Trash" and
        // "Delete Permanently" both do the right thing.
        if isTrashContainer(url) {
            return emptyTrashContainer(item: item)
        }

        switch method {
        case .trash:
            return await recycleSingle(url: url, item: item)
        case .delete:
            return await deleteSingle(url: url, item: item)
        case .toolNative:
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Tool-native cleanup is not supported by CleanupEngine."
            )
        }
    }

    /// Move a single URL to Trash. Finder Automation is tried first, with the
    /// direct macOS Trash API kept as a fallback for denied or failed events.
    @MainActor
    private func recycleSingle(url: URL, item: ScanResult) async -> CleanupItemResult {
        do {
            let trashURL = try await trashMover.moveToTrash(url)
            return CleanupItemResult(item: item, succeeded: true, trashURL: trashURL)
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }

    /// Permanently delete a single URL. Runs on a detached task so the
    /// caller's MainActor thread isn't blocked while `FileManager.removeItem`
    /// walks the directory tree — large dev caches can take several seconds
    /// per item, which froze the UI (beach ball) every time the agent's
    /// modal confirmed a "Delete Permanently" cleanup.
    private func deleteSingle(url: URL, item: ScanResult) async -> CleanupItemResult {
        let pathToRemove = url
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: pathToRemove)
            }.value
            return CleanupItemResult(item: item, succeeded: true)
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }

    /// Resolves to true when `url` refers to the user's Trash directory.
    /// Both `.trash` and `.delete` operations on this URL would fail
    /// (macOS refuses to remove the Trash container), so we intercept.
    private func isTrashContainer(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let trash = trashURL.standardizedFileURL.resolvingSymlinksInPath().path
        return target == trash
    }

    private var trashURL: URL {
        homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Empty the Trash: enumerate its top-level contents and remove each.
    /// Reports aggregate success/failure on a single `CleanupItemResult`
    /// keyed to the original "Trash" scan item.
    private func emptyTrashContainer(item: ScanResult) -> CleanupItemResult {
        let fm = FileManager.default
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return CleanupItemResult(
                item: item,
                succeeded: false,
                error: "Could not read Trash contents: \(error.localizedDescription)"
            )
        }

        if children.isEmpty {
            return CleanupItemResult(item: item, succeeded: true)
        }

        var failures: [(name: String, message: String)] = []
        for child in children {
            do {
                try fm.removeItem(at: child)
            } catch {
                failures.append((child.lastPathComponent, error.localizedDescription))
            }
        }

        if failures.isEmpty {
            return CleanupItemResult(item: item, succeeded: true)
        }

        let summary: String
        if failures.count == 1 {
            summary = "\(failures[0].name): \(failures[0].message)"
        } else {
            let preview = failures.prefix(3).map(\.name).joined(separator: ", ")
            let more = failures.count > 3 ? " and \(failures.count - 3) more" : ""
            summary = "\(failures.count) Trash items could not be removed (\(preview)\(more))"
        }
        return CleanupItemResult(item: item, succeeded: false, error: summary)
    }
}
