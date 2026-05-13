import Foundation
import Testing
@testable import GargantuaCore

extension CzkawkaAdapterTests {
    @Test("builtIn trust defaults cover every category")
    func trustDefaultsCoverAllCategories() {
        let defaults = CzkawkaTrustDefaults.builtIn
        for category in CzkawkaCategory.allCases {
            let entry = defaults.entry(for: category)
            // Categories that are user-owned content default to review; the
            // trivially-disposable ones default to safe. Both are acceptable
            // here — we just want to guarantee an explicit mapping exists.
            let allowed: [SafetyLevel] = [.safe, .review]
            #expect(allowed.contains(entry.safety), "Missing or invalid default for \(category)")
        }
    }

    @Test("safe-default categories are all the zero-loss ones")
    func safeDefaultsAreZeroLossCategories() {
        let defaults = CzkawkaTrustDefaults.builtIn
        let safeCategories = CzkawkaCategory.allCases.filter {
            defaults.entry(for: $0).safety == .safe
        }
        #expect(Set(safeCategories) == [.emptyFiles, .emptyFolders, .brokenSymlinks, .temporaryFiles])
    }
}
