import Testing
import Foundation
@testable import GargantuaCore

private let testHome = URL(fileURLWithPath: "/Users/jane")

@Suite("DuplicateFinderScopeFilter.defaultPersonalRoots")
struct DuplicateFinderScopeFilterDefaultsTests {

    @Test("Default roots cover the standard user-document folders")
    func defaultsCoverage() {
        let roots = DuplicateFinderScopeFilter.defaultPersonalRoots(homeDirectory: testHome)
        let paths = roots.map(\.path)
        #expect(paths.contains("/Users/jane/Documents"))
        #expect(paths.contains("/Users/jane/Downloads"))
        #expect(paths.contains("/Users/jane/Desktop"))
        #expect(paths.contains("/Users/jane/Pictures"))
        #expect(paths.contains("/Users/jane/Movies"))
        #expect(paths.contains("/Users/jane/Music"))
    }
}
