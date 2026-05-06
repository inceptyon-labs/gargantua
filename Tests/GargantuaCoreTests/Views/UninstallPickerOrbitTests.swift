import Foundation
import Testing
@testable import GargantuaCore

@Suite("UninstallPickerOrbit")
struct UninstallPickerOrbitTests {

    // MARK: - confidencePercent

    @Test("nil category count maps to 0%")
    func nilCount() {
        #expect(UninstallPickerOrbit.confidencePercent(forCategoryCount: nil) == 0)
    }

    @Test("zero category count maps to 0%")
    func zeroCount() {
        #expect(UninstallPickerOrbit.confidencePercent(forCategoryCount: 0) == 0)
    }

    @Test("category count maxing the enum maps to 100%")
    func saturatesAtFullCoverage() {
        let total = RemnantCategory.allCases.count
        #expect(UninstallPickerOrbit.confidencePercent(forCategoryCount: total) == 100)
    }

    @Test("category count exceeding the enum still clamps to 100%")
    func clampsAboveCeiling() {
        let total = RemnantCategory.allCases.count
        #expect(UninstallPickerOrbit.confidencePercent(forCategoryCount: total + 5) == 100)
    }

    @Test("confidence rises monotonically with category count")
    func monotonic() {
        var previous = -1
        for count in 0 ... RemnantCategory.allCases.count {
            let pct = UninstallPickerOrbit.confidencePercent(forCategoryCount: count)
            #expect(pct >= previous, "pct decreased between count \(count - 1) and \(count)")
            previous = pct
        }
    }

    // MARK: - safety

    @Test("system app maps to protected_ — uninstalling is the dangerous path")
    func systemAppIsProtected() {
        let app = AppInfo(
            bundleID: "com.apple.systemapp",
            name: "SystemApp",
            bundlePath: "/Applications/SystemApp.app",
            isSystemApp: true
        )
        #expect(UninstallPickerOrbit.safety(forApp: app) == .protected_)
    }

    @Test("non-system app maps to review — neutral until plan classification")
    func userAppIsReview() {
        let app = AppInfo(
            bundleID: "com.example.app",
            name: "App",
            bundlePath: "/Applications/App.app",
            isSystemApp: false
        )
        #expect(UninstallPickerOrbit.safety(forApp: app) == .review)
    }
}
