import Foundation
import Testing
@testable import GargantuaCore

@Suite("Remnant Rule Set Integration")
struct RemnantRuleSetIntegrationTests {
    let loader = RemnantRuleLoader()

    private var rulesDirectory: URL {
        guard let url = Bundle.module.url(forResource: "uninstall_rules", withExtension: nil) else {
            fatalError("uninstall_rules not bundled")
        }
        return url
    }

    @Test("All remnant rule files load without errors")
    func allFilesLoadCleanly() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.isClean, "Parse errors: \(result.errors.map(\.description))")
        #expect(result.filesLoaded > 0, "No YAML files found in \(rulesDirectory.path)")
    }

    @Test("Expected number of remnant rule files loaded")
    func expectedFileCount() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.filesLoaded == 2)
    }

    @Test("Generic remnant coverage includes locations and launch services")
    func categoryCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let categories = Set(result.rules.map(\.category))

        #expect(categories.contains(.supportFiles))
        #expect(categories.contains(.caches))
        #expect(categories.contains(.preferences))
        #expect(categories.contains(.containers))
        #expect(categories.contains(.launchAgents))
        #expect(categories.contains(.launchDaemons))
        #expect(categories.contains(.logs))
        #expect(categories.contains(.savedState))
        #expect(categories.contains(.webData))
        #expect(categories.contains(.helpers))
    }
}
