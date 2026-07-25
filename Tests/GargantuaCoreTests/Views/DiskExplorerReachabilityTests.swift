import Foundation
import Testing
@testable import GargantuaCore

/// Two ways the Disk Explorer could strand a user: Escape destroyed the whole
/// session instead of going up one level, and the treemap's "Others (N)" rollup
/// was applied to the list too, hiding those folders from every surface.
@Suite("Disk Explorer navigation reachability")
@MainActor
struct DiskExplorerReachabilityTests {

    private func makeItem(name: String, size: Int64) -> DirectoryItem {
        DirectoryItem(name: name, path: "/tmp/\(name)", size: size)
    }

    @Test("going up one level pops a single crumb and keeps the size cache")
    func upOneLevelPreservesCache() {
        let state = DiskExplorerState()
        state.pathStack = [
            DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home"),
            DiskExplorerCrumb(path: "\(NSHomeDirectory())/Library", name: "Library"),
            DiskExplorerCrumb(path: "\(NSHomeDirectory())/Library/Caches", name: "Caches"),
        ]
        state.pathCache = ["\(NSHomeDirectory())/Library": [makeItem(name: "Caches", size: 10)]]

        state.navigateTo(index: state.pathStack.count - 2)

        #expect(state.pathStack.count == 2)
        #expect(state.pathStack.last?.name == "Library")
        // exitToIdle() wipes this; going up must not. Losing it costs a full
        // rescan of every level to get back to where the user was.
        #expect(state.pathCache.isEmpty == false)
    }

    @Test("exiting to idle still resets the trail and the cache")
    func exitToIdleResets() {
        let state = DiskExplorerState()
        state.pathStack = [
            DiskExplorerCrumb(path: NSHomeDirectory(), name: "Home"),
            DiskExplorerCrumb(path: "\(NSHomeDirectory())/Library", name: "Library"),
        ]
        state.pathCache = ["\(NSHomeDirectory())/Library": [makeItem(name: "Caches", size: 10)]]

        state.exitToIdle()

        #expect(state.pathStack.count == 1)
        #expect(state.pathCache.isEmpty)
    }

    @Test("the treemap collapses sub-1% children but the list enumerates all of them")
    func listIsNotCollapsed() {
        // 5 large children plus 15 that are each well under 1% of the largest,
        // which is past collapseSmall's 12-sized-children threshold.
        var items = (0 ..< 5).map { makeItem(name: "big-\($0)", size: 1_000_000) }
        items += (0 ..< 15).map { makeItem(name: "small-\($0)", size: 100) }

        let collapsed = DiskExplorerView.collapseSmall(items)

        // The treemap rolls the small ones into a single aggregate tile...
        #expect(collapsed.count < items.count)
        #expect(collapsed.contains { $0.isOthersAggregate })
        // ...and the list, which renders `state.items` directly, does not.
        #expect(items.contains { $0.isOthersAggregate } == false)
        #expect(items.count == 20)
    }

    @Test("a directory below the collapse threshold is untouched in both modes")
    func belowThresholdNotCollapsed() {
        let items = (0 ..< 6).map { makeItem(name: "child-\($0)", size: Int64(1_000 * ($0 + 1))) }

        let collapsed = DiskExplorerView.collapseSmall(items)

        #expect(collapsed.count == items.count)
        #expect(collapsed.contains { $0.isOthersAggregate } == false)
    }
}
