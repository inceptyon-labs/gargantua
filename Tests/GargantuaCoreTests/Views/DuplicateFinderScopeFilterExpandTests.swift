import Testing
import Foundation
@testable import GargantuaCore

private let testHome = URL(fileURLWithPath: "/Users/jane")

@Suite("DuplicateFinderScopeFilter.expand")
struct DuplicateFinderScopeFilterExpandTests {

    @Test("Tilde paths expand against the supplied home directory")
    func expandsTildePaths() {
        let urls = DuplicateFinderScopeFilter.expand(
            patterns: ["~/Documents", "~/Pictures/Cameras"],
            homeDirectory: testHome
        )
        #expect(urls.map(\.path) == ["/Users/jane/Documents", "/Users/jane/Pictures/Cameras"])
    }

    @Test("Absolute paths pass through")
    func absolutePassthrough() {
        let urls = DuplicateFinderScopeFilter.expand(
            patterns: ["/Volumes/Photos"],
            homeDirectory: testHome
        )
        #expect(urls.map(\.path) == ["/Volumes/Photos"])
    }

    @Test("Invalid patterns are silently dropped — defence in depth behind Settings validation")
    func invalidDropped() {
        let urls = DuplicateFinderScopeFilter.expand(
            patterns: ["", "  ", "~", "~/", "/", "/Users/jane", "Documents", "../escape"],
            homeDirectory: testHome
        )
        #expect(urls.isEmpty)
    }

    @Test("Mixes are filtered: only valid entries survive, in input order")
    func mixedFiltering() {
        let urls = DuplicateFinderScopeFilter.expand(
            patterns: ["", "~/Documents", "/", "/Volumes/Photos", "Documents"],
            homeDirectory: testHome
        )
        #expect(urls.map(\.path) == ["/Users/jane/Documents", "/Volumes/Photos"])
    }
}
