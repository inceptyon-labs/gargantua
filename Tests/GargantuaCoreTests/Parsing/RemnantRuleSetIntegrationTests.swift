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

    @Test("Expected number of remnant rules loaded")
    func expectedRuleCount() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.rules.count == 28)
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
        #expect(categories.contains(.cookies))
        #expect(categories.contains(.webData))
        #expect(categories.contains(.helpers))
        #expect(categories.contains(.other))
    }

    @Test("Mole-backed remnant families stay conservatively gated")
    func moleBackedFamiliesStayConservative() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rulesByID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })

        #expect(
            rulesByID["generic_application_support_variants"]?.pathTemplates
                .contains("~/Library/Application Support/{appNameVariant}") == true
        )
        #expect(rulesByID["generic_application_support_variants"]?.safety == .review)
        #expect(
            rulesByID["generic_http_cookie_storage"]?.pathTemplates
                .contains("~/Library/HTTPStorages/{bundleID}.binarycookies") == true
        )
        #expect(rulesByID["generic_http_cookie_storage"]?.safety == .review)
        #expect(
            rulesByID["generic_app_extension_containers"]?.pathTemplates
                .contains("~/Library/Application Support/FileProvider/{bundleID}*") == true
        )
        #expect(rulesByID["generic_app_extension_containers"]?.safety == .review)
        #expect(rulesByID["generic_group_container_variants"]?.safety == .review)
        #expect(rulesByID["generic_application_scripts_services"]?.safety == .review)
        #expect(rulesByID["generic_privileged_helpers"]?.safety == .review)
        #expect(rulesByID["generic_launch_daemons"]?.safety == .protected_)
        #expect(rulesByID["generic_package_receipts"]?.safety == .protected_)
        #expect(rulesByID["generic_webkit_webcontent_storage"]?.safety == .safe)
    }
}
