import Foundation
import Observation

/// Top-level phases of the Disk Explorer flow.
public enum DiskExplorerPhase: Sendable {
    case idle
    case results
}

/// User-selectable rendering of a directory's children.
///
/// `.focus` is the dominant-folder hero-card view that used to silently
/// substitute for `.treemap` when one folder dwarfed the rest. Promoting it
/// to a first-class toggle state means the segmented control no longer lies
/// about what's on screen, and users can override the auto-substitution by
/// clicking Treemap explicitly.
public enum DiskExplorerDisplayMode: Sendable {
    case treemap
    case list
    case focus
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
    /// True once the user has explicitly tapped the display-mode toggle for
    /// this directory. Gates the auto-promotion to `.focus` on dominance
    /// detection — once the user has made an explicit choice, the auto flip
    /// stops fighting them. Reset by every navigation entry point.
    public var displayModeIsExplicit: Bool = false
    public var phase: DiskExplorerPhase = .idle
    public var scanGeneration: Int = 0
    /// Controls the Rescan confirmation dialog. The view flips this true
    /// instead of calling `rescanFromHome` directly when the user has drilled
    /// past the home directory, so they can't silently lose a deep
    /// drill-down with one click.
    public var showRescanConfirmation: Bool = false
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
        displayModeIsExplicit = false
        isLoading = true
        scanGeneration &+= 1
        phase = .results
    }

    public func refreshCurrent() {
        pathCache.removeValue(forKey: currentPath)
        items = []
        expandedItems = [:]
        maxSize = 1
        displayModeIsExplicit = false
        isLoading = true
        scanGeneration &+= 1
    }

    public func rescanFromHome() {
        pathCache = [:]
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        items = []
        expandedItems = [:]
        maxSize = 1
        displayModeIsExplicit = false
        isLoading = true
        scanGeneration &+= 1
    }

    public func exitToIdle() {
        pathCache = [:]
        items = []
        expandedItems = [:]
        maxSize = 1
        displayModeIsExplicit = false
        pathStack = [DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home")]
        isLoading = false
        phase = .idle
    }

    /// Set by the toggle's user-tap path so the auto-promote-to-focus heuristic
    /// stops fighting the user once they've made a deliberate pick for this
    /// directory.
    public func setDisplayMode(_ mode: DiskExplorerDisplayMode) {
        displayMode = mode
        displayModeIsExplicit = true
    }

    /// Synchronously hydrate `items` from `pathCache` if possible. Called from
    /// every navigation entry point so the user never sees a scanning flash
    /// when stepping back to a directory we've already mapped.
    public func applyCachedItemsIfPresent() {
        expandedItems = [:]
        // Each new directory gets its own auto-promote chance; users who
        // overrode the mode for the previous folder shouldn't have that pick
        // bleed into a sibling that would benefit from focus mode (or vice
        // versa).
        displayModeIsExplicit = false
        if let cached = pathCache[currentPath] {
            items = cached
            maxSize = items.first(where: { !$0.isPermissionDenied && !$0.isSizing })?.size ?? 1
            isLoading = false
            applyAutoPromoteIfNeeded()
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
        applyAutoPromoteIfNeeded()
    }

    /// The largest sized child if it dwarfs the second-largest enough to make
    /// the treemap degenerate (second < 15% of largest). Drives auto-promote
    /// to `.focus` and the rendering of the dominant-child hero card.
    ///
    /// Computed lazily — sizes are only stable once `isLoading` is false, so
    /// callers should gate on that.
    public var dominantChild: DirectoryItem? {
        guard !isLoading else { return nil }
        let sized = items
            .filter { !$0.isPermissionDenied && !$0.isSizing && $0.size > 0 }
            .sorted { $0.size > $1.size }
        guard let largest = sized.first else { return nil }
        guard sized.count > 1 else { return largest }
        let second = sized[1]
        if Double(second.size) / Double(largest.size) < 0.15 {
            return largest
        }
        return nil
    }

    /// Promote `.treemap` → `.focus` when one child dwarfs the rest, but only
    /// if the user hasn't already picked a mode for this directory.
    private func applyAutoPromoteIfNeeded() {
        guard !displayModeIsExplicit, displayMode == .treemap else { return }
        if dominantChild != nil {
            displayMode = .focus
        }
    }
}
