import Foundation
import Observation

/// Top-level phases of the Disk Explorer flow.
public enum DiskExplorerPhase: Sendable {
    case idle
    case results
}

/// User-selectable rendering of a directory's children.
public enum DiskExplorerDisplayMode: Sendable {
    case treemap
    case list
}

/// One step in the Disk Explorer breadcrumb stack.
///
/// A struct (vs. a tuple) so the state class can store an array of these in
/// `@Observable` storage without paying for a `__SwiftValue` boxing dance.
public struct DiskExplorerCrumb: Sendable, Equatable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Navigation, scan, and cache state for the Disk Explorer.
///
/// Owned at the `MainContentView` level (mirrors `FileHealthContainerState`,
/// `DuplicateFinderContainerState`, `DeepCleanSessionState`,
/// `SmartUninstallerViewModel`) so a sidebar nav away-and-back doesn't tear
/// down the breadcrumb, the per-directory size cache, or the user's chosen
/// display mode. The view layer reads/writes these properties via
/// `@Bindable`/`@Observable`.
@Observable @MainActor
public final class DiskExplorerState {
    /// Stack of crumbs representing the drill-down trail. The last entry is
    /// the directory currently displayed.
    public var pathStack: [DiskExplorerCrumb] = [
        DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")
    ]
    public var items: [DirectoryItem] = []
    public var expandedItems: [String: [DirectoryItem]] = [:]
    public var isLoading: Bool = false
    public var maxSize: Int64 = 1
    public var displayMode: DiskExplorerDisplayMode = .treemap
    public var phase: DiskExplorerPhase = .idle
    public var scanGeneration: Int = 0
    /// Per-path snapshot of the last successful scan. Lets the breadcrumb
    /// navigate back to a directory we've already mapped without paying for
    /// another recursive sizing pass. Invalidated by Refresh / Rescan / Back.
    public var pathCache: [String: [DirectoryItem]] = [:]

    public init() {}

    public var currentPath: String {
        pathStack.last?.path ?? NSHomeDirectory()
    }

    /// Bumped on every navigation/rescan so the view's `.task(id:)` re-runs
    /// the scan even when the path hasn't changed (e.g. Refresh on the same
    /// dir).
    public var scanLoadKey: String {
        "\(scanGeneration)|\(currentPath)"
    }

    // MARK: - Transitions

    public func startScan() {
        pathCache = [:]
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        items = []
        expandedItems = [:]
        maxSize = 1
        isLoading = true
        scanGeneration &+= 1
        phase = .results
    }

    public func refreshCurrent() {
        pathCache.removeValue(forKey: currentPath)
        items = []
        expandedItems = [:]
        maxSize = 1
        isLoading = true
        scanGeneration &+= 1
    }

    public func rescanFromHome() {
        pathCache = [:]
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        items = []
        expandedItems = [:]
        maxSize = 1
        isLoading = true
        scanGeneration &+= 1
    }

    public func exitToIdle() {
        pathCache = [:]
        items = []
        expandedItems = [:]
        maxSize = 1
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        isLoading = false
        phase = .idle
    }

    /// Synchronously hydrate `items` from `pathCache` if possible. Called from
    /// every navigation entry point so the user never sees a scanning flash
    /// when stepping back to a directory we've already mapped.
    public func applyCachedItemsIfPresent() {
        expandedItems = [:]
        if let cached = pathCache[currentPath] {
            items = cached
            maxSize = items.first(where: { !$0.isPermissionDenied && !$0.isSizing })?.size ?? 1
            isLoading = false
        } else {
            items = []
            maxSize = 1
            isLoading = true
        }
    }

    /// Insert or replace `item` (keyed by `item.id`), then keep `items`
    /// sorted largest-first with permission-denied rows pushed to the bottom.
    public func upsert(_ item: DirectoryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        items.sort { lhs, rhs in
            if lhs.isPermissionDenied != rhs.isPermissionDenied {
                return !lhs.isPermissionDenied
            }
            return lhs.size > rhs.size
        }
        maxSize = items.first(where: { !$0.isPermissionDenied && !$0.isSizing })?.size ?? 1
    }

    public func drillDown(into item: DirectoryItem) {
        guard !item.isPermissionDenied,
              !item.isFilesAggregate,
              !item.isOthersAggregate,
              !item.isSizing else { return }
        pathStack.append(DiskExplorerCrumb(path: item.path, name: item.name))
        applyCachedItemsIfPresent()
    }

    public func navigateTo(index: Int) {
        guard index < pathStack.count - 1 else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        applyCachedItemsIfPresent()
    }

    /// Mark the in-flight scan for `path` complete: cache its items and
    /// stop the loading indicator. Called from the streaming load loop after
    /// the scanner finishes without cancellation.
    public func completeLoad(for path: String) {
        pathCache[path] = items
        isLoading = false
    }
}
