import Foundation
import Testing
@testable import GargantuaCore

@Suite("DiskExplorerState")
struct DiskExplorerStateTests {
    private func makeItem(
        name: String,
        size: Int64,
        isPermissionDenied: Bool = false,
        isSizing: Bool = false
    ) -> DirectoryItem {
        DirectoryItem(
            name: name,
            path: "/tmp/disk-explorer/\(name)",
            size: size,
            isPermissionDenied: isPermissionDenied,
            isSizing: isSizing
        )
    }

    @Test("startScan resets to the home root and bumps the generation")
    @MainActor
    func startScanResets() {
        let state = DiskExplorerState()
        state.items = [makeItem(name: "stale", size: 10)]
        state.displayMode = .list
        state.displayModeIsExplicit = true
        let generationBefore = state.scanGeneration

        state.startScan()

        #expect(state.items.isEmpty)
        #expect(state.pathStack.count == 1)
        #expect(state.currentPath == NSHomeDirectory())
        #expect(state.isLoading)
        #expect(state.phase == .results)
        #expect(state.scanGeneration == generationBefore + 1)
        #expect(!state.displayModeIsExplicit)
    }

    @Test("startScan(root:) sets the scan root and scopes the breadcrumb to it")
    @MainActor
    func startScanWithRootSetsScanRoot() {
        let state = DiskExplorerState()
        let root = DiskExplorerCrumb(path: "/Volumes/External", name: "External")

        state.startScan(root: root)

        #expect(state.scanRoot == root)
        #expect(state.pathStack == [root])
        #expect(state.currentPath == root.path)
    }

    @Test("rescanFromRoot after drilling down returns to the chosen root, not Home")
    @MainActor
    func rescanFromRootReturnsToChosenRoot() {
        let state = DiskExplorerState()
        let root = DiskExplorerCrumb(path: "/Volumes/External", name: "External")
        state.startScan(root: root)
        state.drillDown(into: makeItem(name: "child", size: 100))
        #expect(state.pathStack.count == 2)

        state.rescanFromRoot()

        #expect(state.pathStack == [root])
        #expect(state.currentPath == root.path)
    }

    @Test("exitToIdle resets the scan root to Home")
    @MainActor
    func exitToIdleResetsScanRoot() {
        let state = DiskExplorerState()
        state.startScan(root: DiskExplorerCrumb(path: "/Volumes/External", name: "External"))

        state.exitToIdle()

        #expect(state.scanRoot == .home)
        #expect(state.pathStack == [.home])
    }

    @Test("crumb(forRootPath:) names the boot volume, Home, and an arbitrary folder")
    @MainActor
    func crumbForRootPath() {
        let root = DiskExplorerState.crumb(forRootPath: "/")
        #expect(root.path == "/")
        #expect(!root.name.isEmpty)

        let home = DiskExplorerState.crumb(forRootPath: NSHomeDirectory())
        #expect(home == .home)

        let folder = DiskExplorerState.crumb(forRootPath: "/tmp/foo")
        #expect(folder.path == "/tmp/foo")
        #expect(folder.name == "foo")
    }

    @Test("upsert keeps items sorted largest-first with denied rows last")
    @MainActor
    func upsertSorts() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "small", size: 10))
        state.upsert(makeItem(name: "large", size: 100))
        state.upsert(makeItem(name: "denied", size: 0, isPermissionDenied: true))
        state.upsert(makeItem(name: "medium", size: 50))

        #expect(state.items.map(\.name) == ["large", "medium", "small", "denied"])
        // maxSize tracks the largest non-denied, non-sizing child.
        #expect(state.maxSize == 100)
    }

    @Test("upsert replaces an existing item by id rather than duplicating")
    @MainActor
    func upsertReplaces() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "folder", size: 10))
        state.upsert(makeItem(name: "folder", size: 999))

        #expect(state.items.count == 1)
        #expect(state.items.first?.size == 999)
        #expect(state.maxSize == 999)
    }

    @Test("drillDown pushes a crumb for a normal directory")
    @MainActor
    func drillDownPushesCrumb() {
        let state = DiskExplorerState()
        let child = makeItem(name: "child", size: 100)

        state.drillDown(into: child)

        #expect(state.pathStack.count == 2)
        #expect(state.currentPath == child.path)
    }

    @Test("drillDown ignores permission-denied and sizing rows")
    @MainActor
    func drillDownIgnoresUndrillable() {
        let state = DiskExplorerState()
        state.drillDown(into: makeItem(name: "denied", size: 0, isPermissionDenied: true))
        state.drillDown(into: makeItem(name: "sizing", size: 0, isSizing: true))

        #expect(state.pathStack.count == 1)
    }

    @Test("navigateTo truncates the breadcrumb stack to the chosen index")
    @MainActor
    func navigateToTruncates() {
        let state = DiskExplorerState()
        state.drillDown(into: makeItem(name: "a", size: 100))
        state.drillDown(into: makeItem(name: "b", size: 100))
        #expect(state.pathStack.count == 3)

        state.navigateTo(index: 0)

        #expect(state.pathStack.count == 1)
        #expect(state.currentPath == NSHomeDirectory())
    }

    @Test("navigateTo is a no-op for the current or out-of-range index")
    @MainActor
    func navigateToNoOp() {
        let state = DiskExplorerState()
        state.drillDown(into: makeItem(name: "a", size: 100))

        state.navigateTo(index: 1) // already the last crumb
        #expect(state.pathStack.count == 2)

        state.navigateTo(index: 5) // out of range
        #expect(state.pathStack.count == 2)
    }

    @Test("setDisplayMode marks the choice explicit")
    @MainActor
    func setDisplayModeIsExplicit() {
        let state = DiskExplorerState()
        state.setDisplayMode(.list)

        #expect(state.displayMode == .list)
        #expect(state.displayModeIsExplicit)
    }

    @Test("dominantChild flags a folder that dwarfs its siblings")
    @MainActor
    func dominantChildDetected() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "huge", size: 1000))
        state.upsert(makeItem(name: "tiny", size: 50)) // < 15% of huge
        state.isLoading = false

        #expect(state.dominantChild?.name == "huge")
    }

    @Test("dominantChild is nil when siblings are comparable")
    @MainActor
    func dominantChildNilWhenBalanced() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "a", size: 1000))
        state.upsert(makeItem(name: "b", size: 800)) // > 15% of a
        state.isLoading = false

        #expect(state.dominantChild == nil)
    }

    @Test("dominantChild is nil while still loading")
    @MainActor
    func dominantChildNilWhileLoading() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "huge", size: 1000))
        state.upsert(makeItem(name: "tiny", size: 50))
        state.isLoading = true

        #expect(state.dominantChild == nil)
    }

    @Test("completeLoad caches items and auto-promotes to focus on dominance")
    @MainActor
    func completeLoadAutoPromotes() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "huge", size: 1000))
        state.upsert(makeItem(name: "tiny", size: 50))

        state.completeLoad(for: state.currentPath)

        #expect(!state.isLoading)
        #expect(state.pathCache[state.currentPath]?.count == 2)
        #expect(state.displayMode == .focus)
    }

    @Test("completeLoad does not override an explicit display-mode choice")
    @MainActor
    func completeLoadRespectsExplicitChoice() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "huge", size: 1000))
        state.upsert(makeItem(name: "tiny", size: 50))
        state.setDisplayMode(.treemap) // explicit

        state.completeLoad(for: state.currentPath)

        #expect(state.displayMode == .treemap)
    }

    @Test("applyCachedItemsIfPresent hydrates from cache without a loading flash")
    @MainActor
    func applyCachedHydrates() {
        let state = DiskExplorerState()
        let cached = [makeItem(name: "a", size: 500), makeItem(name: "b", size: 100)]
        state.pathCache[state.currentPath] = cached

        state.applyCachedItemsIfPresent()

        #expect(state.items.count == 2)
        #expect(!state.isLoading)
        #expect(state.maxSize == 500)
    }

    @Test("applyCachedItemsIfPresent shows loading when the path is uncached")
    @MainActor
    func applyCachedMissesToLoading() {
        let state = DiskExplorerState()
        state.applyCachedItemsIfPresent()

        #expect(state.items.isEmpty)
        #expect(state.isLoading)
        #expect(state.maxSize == 1)
    }

    @Test("exitToIdle clears the cache and returns to the idle phase")
    @MainActor
    func exitToIdleClears() {
        let state = DiskExplorerState()
        state.upsert(makeItem(name: "a", size: 100))
        state.pathCache["/tmp/x"] = [makeItem(name: "a", size: 100)]

        state.exitToIdle()

        #expect(state.phase == .idle)
        #expect(state.items.isEmpty)
        #expect(state.pathCache.isEmpty)
        #expect(!state.isLoading)
        #expect(state.pathStack.count == 1)
    }

    @Test("refreshCurrent removes the current path from unreadablePaths; startScan clears it")
    @MainActor
    func unreadablePathsClearedByRefreshAndStartScan() {
        let state = DiskExplorerState()
        state.unreadablePaths = [state.currentPath, "/other"]

        state.refreshCurrent()

        #expect(!state.unreadablePaths.contains(state.currentPath))
        #expect(state.unreadablePaths.contains("/other"))

        state.startScan()

        #expect(state.unreadablePaths.isEmpty)
    }

    @Test("scanLoadKey combines generation and current path")
    @MainActor
    func scanLoadKeyComposed() {
        let state = DiskExplorerState()
        let key = state.scanLoadKey
        #expect(key == "\(state.scanGeneration)|\(state.currentPath)")

        state.refreshCurrent()
        #expect(state.scanLoadKey != key)
    }
}
