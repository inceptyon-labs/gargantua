import Testing
import Foundation
@testable import GargantuaCore

private let testHome = URL(fileURLWithPath: "/Users/jane")

@Suite("DuplicateFinderScopeFilter.normalize")
struct DuplicateFinderScopeFilterNormalizeTests {

    @Test("Tilde-rooted paths are accepted and trimmed")
    func acceptsTildePaths() {
        #expect(DuplicateFinderScopeFilter.normalize("~/Documents", homeDirectory: testHome) == "~/Documents")
        #expect(DuplicateFinderScopeFilter.normalize("  ~/Documents  ", homeDirectory: testHome) == "~/Documents")
        #expect(DuplicateFinderScopeFilter.normalize("~/Pictures/Cameras", homeDirectory: testHome) == "~/Pictures/Cameras")
    }

    @Test("Absolute paths are accepted")
    func acceptsAbsolutePaths() {
        #expect(DuplicateFinderScopeFilter.normalize("/Volumes/Photos", homeDirectory: testHome) == "/Volumes/Photos")
        #expect(DuplicateFinderScopeFilter.normalize("/Users/jane/Workspace", homeDirectory: testHome) == "/Users/jane/Workspace")
    }

    @Test("Empty, whitespace-only, and bare ~ are rejected")
    func rejectsEmptyAndBareTilde() {
        #expect(DuplicateFinderScopeFilter.normalize("", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("   ", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("~", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("~/", homeDirectory: testHome) == nil)
    }

    @Test("Filesystem root and the user's home are rejected — they would void the filter")
    func rejectsRootAndHome() {
        #expect(DuplicateFinderScopeFilter.normalize("/", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("/Users/jane", homeDirectory: testHome) == nil)
        // ~/. and ~/.. resolve to home or above — also rejected via standardization.
        #expect(DuplicateFinderScopeFilter.normalize("/Users/jane/", homeDirectory: testHome) == nil)
    }

    @Test("Relative paths and bare names are rejected")
    func rejectsRelativeAndBareNames() {
        #expect(DuplicateFinderScopeFilter.normalize("Documents", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("./relative", homeDirectory: testHome) == nil)
        #expect(DuplicateFinderScopeFilter.normalize("../escape", homeDirectory: testHome) == nil)
    }

    @Test("isValidRoot mirrors normalize")
    func isValidMirrors() {
        #expect(DuplicateFinderScopeFilter.isValidRoot("~/Documents"))
        #expect(!DuplicateFinderScopeFilter.isValidRoot("/"))
        #expect(!DuplicateFinderScopeFilter.isValidRoot(""))
    }
}
