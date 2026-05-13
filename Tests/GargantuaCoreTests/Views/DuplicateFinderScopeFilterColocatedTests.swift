import Testing
import Foundation
@testable import GargantuaCore

@Suite("DuplicateFinderScopeFilter.isDeeplyColocated")
struct DuplicateFinderScopeFilterColocatedTests {

    @Test("Deep common ancestor below home triggers the rule")
    func deepCommonAncestor() {
        let homeDepth = 2 // /Users/jane
        let paths = [
            "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/lib/fonts/msjh.ttf",
            "/Users/jane/Documents/cpsppp/update_file/2.6.1.s/PPP_UPDATE_TO_2.6.1.s_mac/Resources/resources/fonts/msjh.ttf",
        ]
        #expect(DuplicateFinderScopeFilter.isDeeplyColocated(paths: paths, homeDepth: homeDepth))
    }

    @Test("Shallow common ancestor does NOT trigger the rule")
    func shallowCommonAncestor() {
        let homeDepth = 2
        let paths = [
            "/Users/jane/Documents/photo.jpg",
            "/Users/jane/Pictures/photo.jpg",
        ]
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: paths, homeDepth: homeDepth))
    }

    @Test("Single-element path list never triggers")
    func singlePath() {
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: ["/a/b/c/d/e/f/g/h"], homeDepth: 2))
    }

    @Test("Threshold is exactly home + 5 segments")
    func thresholdBoundary() {
        let homeDepth = 2 // /Users/jane
        let belowThreshold = [
            "/Users/jane/a/b/c/d/x/file.txt",
            "/Users/jane/a/b/c/d/y/file.txt",
        ]
        #expect(!DuplicateFinderScopeFilter.isDeeplyColocated(paths: belowThreshold, homeDepth: homeDepth))

        let atThreshold = [
            "/Users/jane/a/b/c/d/e/x/file.txt",
            "/Users/jane/a/b/c/d/e/y/file.txt",
        ]
        #expect(DuplicateFinderScopeFilter.isDeeplyColocated(paths: atThreshold, homeDepth: homeDepth))
    }
}
