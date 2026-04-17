import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantCategory")
struct RemnantCategoryTests {

    @Test("Raw values match YAML-friendly snake_case")
    func rawValues() {
        #expect(RemnantCategory.supportFiles.rawValue == "support_files")
        #expect(RemnantCategory.caches.rawValue == "caches")
        #expect(RemnantCategory.preferences.rawValue == "preferences")
        #expect(RemnantCategory.containers.rawValue == "containers")
        #expect(RemnantCategory.groupContainers.rawValue == "group_containers")
        #expect(RemnantCategory.launchAgents.rawValue == "launch_agents")
        #expect(RemnantCategory.launchDaemons.rawValue == "launch_daemons")
        #expect(RemnantCategory.logs.rawValue == "logs")
        #expect(RemnantCategory.savedState.rawValue == "saved_state")
        #expect(RemnantCategory.cookies.rawValue == "cookies")
        #expect(RemnantCategory.webData.rawValue == "web_data")
        #expect(RemnantCategory.helpers.rawValue == "helpers")
        #expect(RemnantCategory.other.rawValue == "other")
    }

    @Test("Safe-by-default categories are disposable post-uninstall")
    func safeDefaults() {
        #expect(RemnantCategory.supportFiles.defaultSafety == .safe)
        #expect(RemnantCategory.caches.defaultSafety == .safe)
        #expect(RemnantCategory.logs.defaultSafety == .safe)
        #expect(RemnantCategory.savedState.defaultSafety == .safe)
        #expect(RemnantCategory.webData.defaultSafety == .safe)
    }

    @Test("Review-by-default categories touch user data or system integration")
    func reviewDefaults() {
        #expect(RemnantCategory.preferences.defaultSafety == .review)
        #expect(RemnantCategory.containers.defaultSafety == .review)
        #expect(RemnantCategory.groupContainers.defaultSafety == .review)
        #expect(RemnantCategory.cookies.defaultSafety == .review)
        #expect(RemnantCategory.launchAgents.defaultSafety == .review)
        #expect(RemnantCategory.helpers.defaultSafety == .review)
        #expect(RemnantCategory.other.defaultSafety == .review)
    }

    @Test("Launch daemons default to protected (system-wide, admin required)")
    func launchDaemonsProtected() {
        #expect(RemnantCategory.launchDaemons.defaultSafety == .protected_)
    }

    @Test("All cases have a defined default safety")
    func allCasesCovered() {
        for category in RemnantCategory.allCases {
            let safety = category.defaultSafety
            #expect([.safe, .review, .protected_].contains(safety))
        }
    }

    @Test("Codable round-trip preserves category")
    func codableRoundTrip() throws {
        for category in RemnantCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(RemnantCategory.self, from: data)
            #expect(decoded == category)
        }
    }
}
