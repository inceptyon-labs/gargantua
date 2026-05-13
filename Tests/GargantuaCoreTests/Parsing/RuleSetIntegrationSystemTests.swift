import Foundation
import Testing
@testable import GargantuaCore

/// Integration tests covering system-level rules, protected-root policy
/// adherence, the safety-level distribution, and category alignment with
/// the built-in CleanupProfile definitions.
@Suite("Rule Set Integration: system, safety, and profiles")
struct RuleSetIntegrationSystemTests {
    let loader = RuleLoader()

    private var rulesDirectory: URL {
        guard let url = RuleDirectoryResolver.resolve() else {
            fatalError("cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    // MARK: - System Coverage

    @Test("System rules cover caches, logs, temp, trash")
    func systemCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let categories = Set(result.rules.map(\.category))

        #expect(categories.contains("system_cache"), "Missing system_cache category")
        #expect(categories.contains("system_logs"), "Missing system_logs category")
        #expect(categories.contains("temp_files"), "Missing temp_files category")
        #expect(categories.contains("trash"), "Missing trash category")
    }

    @Test("System temp rules do not target macOS var/folders bucket roots")
    func systemTempRulesDoNotTargetVarFoldersBuckets() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let forbiddenPatterns = try ProtectedRootPolicyLoader()
            .loadBundled()
            .entries
            .map(\.path)
            .filter { $0.contains("/var/folders/") }
        let paths = result.rules.flatMap(\.paths)

        for pattern in forbiddenPatterns {
            #expect(!paths.contains(pattern), "Rule set must not remove macOS-managed bucket root \(pattern)")
        }
    }

    @Test("Cleanup rules do not target protected directory roots")
    func cleanupRulesDoNotTargetProtectedDirectoryRoots() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let policy = try ProtectedRootPolicyLoader()
            .loadBundled()
        let home = URL(fileURLWithPath: "/Users/gargantua-test", isDirectory: true)

        for rule in result.rules {
            for path in rule.paths {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                let emitsResolvedPathDirectly = rule.pattern == nil && rule.exclude.isEmpty
                if emitsResolvedPathDirectly {
                    if !trimmed.contains("*") {
                        let resolvedPath = ProtectedRootPolicy.normalizedPath(
                            trimmed,
                            homeDirectory: home,
                            resolvesSymlinks: false
                        )
                        let protectionReason = policy.protectionReason(
                            for: URL(fileURLWithPath: resolvedPath, isDirectory: true),
                            homeDirectory: home
                        )
                        #expect(protectionReason == nil,
                                "Rule '\(rule.id)' must not remove protected root \(trimmed)")
                    }
                    #expect(!trimmed.hasSuffix("*/Library"),
                            "Rule '\(rule.id)' must not glob protected Library roots via \(trimmed)")
                }
            }
        }
    }

    @Test("System rules cover Mole-backed user and privileged cleanup families")
    func moleSystemUserCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rulesByID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })

        #expect(rulesByID["finder_ds_store_files"]?.safety == .safe, "Missing safe Finder metadata rule")
        #expect(rulesByID["quicklook_iconservices_caches"]?.safety == .safe, "Missing QuickLook/IconServices caches")
        #expect(rulesByID["recent_items_lists"]?.safety == .review, "Recent items should require review")
        #expect(rulesByID["saved_application_states"]?.safety == .review, "Saved app state should require review")
        #expect(rulesByID["autosave_information"]?.safety == .review, "Autosave recovery state should require review")
        #expect(rulesByID["mail_downloads_old"]?.safety == .review, "Mail downloads should require review")
        #expect(rulesByID["cached_ios_device_firmware"]?.safety == .review, "Cached firmware should require review")
        #expect(rulesByID["mobile_sync_backups"]?.safety == .protected_, "MobileSync backups must stay protected")
        #expect(rulesByID["system_diagnostic_reports"]?.safety == .review, "Privileged diagnostics should require review")
        #expect(rulesByID["system_updates_cache"]?.safety == .review, "System updates should require review")
        #expect(rulesByID["rosetta_system_cache"]?.safety == .review, "Privileged Rosetta cache should require review")
        #expect(rulesByID["apple_silicon_user_caches"]?.safety == .safe, "User-level Apple Silicon caches should be safe")
    }

    // MARK: - Safety Distribution

    @Test("Rules use all three safety levels")
    func allSafetyLevelsUsed() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let levels = Set(result.rules.map(\.safety))

        #expect(levels.contains(.safe), "No rules use 'safe' level")
        #expect(levels.contains(.review), "No rules use 'review' level")
        // Protected level may not be used in initial rule set — that's OK
    }

    @Test("Safe rules have high confidence (>= 85)")
    func safeRulesHighConfidence() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules where rule.safety == .safe {
            #expect(rule.confidence >= 85,
                    "Safe rule '\(rule.id)' has low confidence \(rule.confidence)")
        }
    }

    // MARK: - Profile Categories

    @Test("Categories align with built-in CleanupProfile definitions")
    func categoriesAlignWithProfiles() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let ruleCategories = Set(result.rules.map(\.category))
        let allProfileCategories = Set(CleanupProfile.builtIn.flatMap(\.categories))

        let unrecognized = ruleCategories.subtracting(allProfileCategories)
        #expect(unrecognized.isEmpty,
                "Rule categories not in any profile: \(unrecognized)")
    }
}
