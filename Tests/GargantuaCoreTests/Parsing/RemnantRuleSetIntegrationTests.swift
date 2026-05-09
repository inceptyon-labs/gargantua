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
        #expect(result.filesLoaded == 9)
    }

    @Test("Expected number of remnant rules loaded")
    func expectedRuleCount() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.rules.count == 91)
    }

    @Test("App packs scope every rule with applies_to.bundle_ids")
    func appPacksAreScoped() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let appPackRules = result.rules.filter { $0.tags.contains("app_pack") }

        #expect(!appPackRules.isEmpty, "Expected app_pack-tagged rules in vendored snapshot")

        for rule in appPackRules {
            #expect(
                rule.appliesTo?.bundleIDs.isEmpty == false,
                "App-pack rule \(rule.id) must scope itself with applies_to.bundle_ids"
            )
        }
    }

    @Test("App pack credentials and signing artifacts are protected")
    func appPackProtectedCarveOuts() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rulesByID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })

        let protectedIDs = [
            "docker_desktop_credentials_protected",
            "xcode_provisioning_profiles_protected",
            "android_signing_keys_protected",
            "jetbrains_license_state_protected",
            "vscode_user_settings_protected",
            "zed_settings_protected",
            "unity_project_roots_protected",
            "unreal_project_roots_protected",
            "godot_project_roots_protected",
            "raycast_sensitive_history_protected",
            "raycast_user_automation_protected",
        ]

        for id in protectedIDs {
            #expect(rulesByID[id]?.safety == .protected_, "\(id) must be protected")
        }
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

    @Test("Game-engine and Raycast app packs scope variants and sensitive carve-outs")
    func appPackBatch2Coverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rulesByID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })

        #expect(rulesByID["unity_engine_caches"]?.appliesTo?.bundleIDs.contains("com.unity3d.unityhub") == true)
        #expect(rulesByID["unreal_derived_data_cache"]?.safety == .review)
        #expect(rulesByID["godot_editor_state"]?.pathTemplates.contains("~/.config/{appNameVariant}") == true)
        #expect(rulesByID["godot_editor_state"]?.appliesTo?.bundleIDs.contains("org.godotengine.godot4") == true)

        #expect(rulesByID["raycast_support_state"]?.exclude.contains("clipboard*") == true)
        #expect(rulesByID["raycast_support_state"]?.exclude.contains("Raycast.sqlite*") == true)
        #expect(rulesByID["raycast_support_state"]?.safety == .review)
        #expect(rulesByID["raycast_transient_caches"]?.safety == .safe)
        #expect(rulesByID["raycast_sensitive_history_protected"]?.safety == .protected_)
        #expect(rulesByID["raycast_user_automation_protected"]?.safety == .protected_)
    }

    @Test("App-pack paths do not target protected filesystem roots directly")
    func appPackRulesAvoidProtectedRootTargets() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let appPackRules = result.rules.filter { $0.tags.contains("app_pack") }
        let forbiddenRoots = Set(["~", "~/Library", "/", "/Applications", "/Library", "/System", "/Users"])

        for rule in appPackRules {
            for path in rule.pathTemplates {
                #expect(!forbiddenRoots.contains(path), "\(rule.id) targets protected root \(path)")
            }
        }
    }
}
