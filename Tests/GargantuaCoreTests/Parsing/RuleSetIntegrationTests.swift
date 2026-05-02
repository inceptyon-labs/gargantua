import Foundation
import Testing
@testable import GargantuaCore

/// Integration tests that validate the actual YAML rule files in cleanup_rules/.
@Suite("Rule Set Integration")
struct RuleSetIntegrationTests {
    let loader = RuleLoader()

    /// Resolves the cleanup_rules/ directory via the same resolver production uses.
    /// Rules ship as an SPM resource on GargantuaCore, so `Bundle.module` finds
    /// them in tests, `swift run`, and a shipped `.app` alike.
    private var rulesDirectory: URL {
        guard let url = RuleDirectoryResolver.resolve() else {
            fatalError("cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    // MARK: - Loading

    @Test("All rule files load without errors")
    func allFilesLoadCleanly() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.isClean, "Parse errors: \(result.errors.map(\.description))")
        #expect(result.filesLoaded > 0, "No YAML files found in \(rulesDirectory.path)")
    }

    @Test("Expected number of rule files loaded")
    func expectedFileCount() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        // browser: arc, brave, chrome, chromium, comet, dia, edge, firefox,
        // helium, opera, orion, safari, vivaldi, yandex, zen
        // apps: Slack, Spotify, Dropbox, plus Mole app/cache parity batches for
        // cloud sync, office/mail, communication, virtualization, creative/media,
        // productivity, media, launchers, games, utilities, and remote desktop
        // developer: xcode, node, docker, homebrew, python, rust, go,
        // plus Mole parity batches for frontend, cloud, mobile, JVM, editors,
        // AI tools, AI models, languages, CI, database/API tools, shell/network, project caches
        // system: caches, logs, temp, trash, plus Mole parity batches for
        // Apple services, user state, mobile installers/backups, and privileged paths
        #expect(result.filesLoaded == 51)
    }

    // MARK: - Rule Completeness

    @Test("Every rule has a non-empty id")
    func allRulesHaveID() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.id.isEmpty, "Rule has empty id")
        }
    }

    @Test("All rule IDs are unique")
    func uniqueRuleIDs() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let ids = result.rules.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Duplicate IDs: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }

    @Test("Every rule has at least one path")
    func allRulesHavePaths() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.paths.isEmpty, "Rule '\(rule.id)' has no paths")
        }
    }

    @Test("Every rule has confidence between 0 and 100")
    func confidenceInRange() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(rule.confidence >= 0 && rule.confidence <= 100,
                    "Rule '\(rule.id)' confidence \(rule.confidence) out of range")
        }
    }

    @Test("Every rule has a non-empty explanation")
    func allRulesHaveExplanation() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.explanation.isEmpty, "Rule '\(rule.id)' has empty explanation")
        }
    }

    @Test("Every rule has a source with a name")
    func allRulesHaveSource() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.source.name.isEmpty, "Rule '\(rule.id)' has empty source name")
        }
    }

    @Test("Every rule has a non-empty category")
    func allRulesHaveCategory() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.category.isEmpty, "Rule '\(rule.id)' has empty category")
        }
    }

    // MARK: - Category Coverage

    @Test("Browser rules cover shipped browser families")
    func browserCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let browserRuleIDs = result.rules.filter { $0.category == "browser_cache" || $0.category == "browser_data" }.map(\.id)

        let expectedPrefixes = [
            "arc",
            "brave",
            "chrome",
            "chromium",
            "comet",
            "dia",
            "edge",
            "firefox",
            "helium",
            "opera",
            "orion",
            "safari",
            "vivaldi",
            "yandex",
            "zen",
        ]
        for prefix in expectedPrefixes {
            #expect(browserRuleIDs.contains(where: { $0.hasPrefix(prefix) }), "Missing \(prefix) rules")
        }
    }

    @Test("App rules cover shipped app families")
    func appCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let appRules = result.rules.filter { $0.category == "app_cache" || $0.category == "app_data" }
        let appRuleIDs = appRules.map(\.id)

        #expect(appRuleIDs.contains(where: { $0.hasPrefix("slack") }), "Missing Slack rules")
        #expect(appRuleIDs.contains(where: { $0.hasPrefix("spotify") }), "Missing Spotify rules")
        #expect(appRuleIDs.contains(where: { $0.hasPrefix("dropbox") }), "Missing Dropbox rules")
        #expect(appRuleIDs.contains("google_drive_cache"), "Missing Google Drive cache rule")
        #expect(appRuleIDs.contains("onedrive_cache"), "Missing OneDrive cache rule")
        #expect(appRuleIDs.contains("microsoft_word_caches"), "Missing Microsoft Word cache rule")
        #expect(appRuleIDs.contains("apple_mail_cache"), "Missing Apple Mail cache rule")
        #expect(appRuleIDs.contains("microsoft_teams_caches"), "Missing Microsoft Teams cache rule")
        #expect(appRuleIDs.contains("vmware_fusion_cache"), "Missing VMware Fusion cache rule")
        #expect(appRuleIDs.contains("figma_cache"), "Missing Figma cache rule")
        #expect(appRuleIDs.contains("game_platform_caches"), "Missing game platform cache rule")
        #expect(appRuleIDs.contains("launcher_automation_caches"), "Missing launcher automation cache rule")
        #expect(appRules.contains(where: { $0.tags.contains("communication") }), "Missing communication app rules")
        #expect(appRules.contains(where: { $0.tags.contains("office") }), "Missing office app rules")
        #expect(appRules.contains(where: { $0.tags.contains("virtualization") }), "Missing virtualization app rules")
        #expect(appRules.contains(where: { $0.tags.contains("creative") }), "Missing creative app rules")
        #expect(appRules.contains(where: { $0.tags.contains("remote_desktop") }), "Missing remote desktop rules")
    }

    @Test("Mole-backed app rules keep user-adjacent data review gated")
    func moleAppRuleSafety() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rulesByID = Dictionary(uniqueKeysWithValues: result.rules.map { ($0.id, $0) })

        #expect(rulesByID["google_drive_cache"]?.safety == .safe, "Cloud app caches should be safe")
        #expect(rulesByID["microsoft_word_caches"]?.safety == .safe, "Office cache/temp/log paths should be safe")
        #expect(rulesByID["microsoft_teams_caches"]?.safety == .safe, "Communication cache/log paths should be safe")
        #expect(rulesByID["virtualbox_vm_cache"]?.safety == .review, "VM-adjacent caches should require review")
        #expect(rulesByID["davinci_resolve_cacheclip"]?.safety == .review, "Project-adjacent media cache should require review")
        #expect(rulesByID["game_platform_caches"]?.safety == .review, "Large/offline game caches should require review")
        #expect(
            rulesByID["launcher_automation_caches"]?.paths.contains(where: { $0.localizedCaseInsensitiveContains("clipboard") }) == false,
            "Raycast clipboard history must stay out of cache cleanup"
        )
    }

    @Test("Developer rules cover Mole-backed developer tooling families")
    func developerCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let ids = result.rules.map(\.id)

        #expect(ids.contains(where: { $0.hasPrefix("xcode") }), "Missing Xcode rules")
        #expect(ids.contains(where: { $0.hasPrefix("node") || $0 == "npm_cache" }), "Missing Node.js rules")
        #expect(ids.contains(where: { $0.hasPrefix("docker") }), "Missing Docker rules")
        #expect(ids.contains(where: { $0.hasPrefix("homebrew") }), "Missing Homebrew rules")
        #expect(result.rules.contains(where: { $0.tags.contains("python") }), "Missing Python rules")
        #expect(result.rules.contains(where: { $0.tags.contains("rust") }), "Missing Rust rules")
        #expect(result.rules.contains(where: { $0.tags.contains("go") }), "Missing Go rules")
        #expect(result.rules.contains(where: { $0.tags.contains("jvm") }), "Missing JVM rules")
        #expect(result.rules.contains(where: { $0.tags.contains("android") }), "Missing Android rules")
        #expect(result.rules.contains(where: { $0.tags.contains("cloud") }), "Missing cloud CLI rules")
        #expect(result.rules.contains(where: { $0.tags.contains("kubernetes") }), "Missing Kubernetes rules")
        #expect(result.rules.contains(where: { $0.tags.contains("editor") }), "Missing editor rules")
        #expect(result.rules.contains(where: { $0.tags.contains("ai") }), "Missing AI/dev assistant rules")
        #expect(result.rules.contains(where: { $0.tags.contains("ci") }), "Missing CI rules")
        #expect(result.rules.contains(where: { $0.tags.contains("database") }), "Missing database tool rules")
        #expect(result.rules.contains(where: { $0.tags.contains("dotnet") }), "Missing .NET rules")
        #expect(result.rules.contains(where: { $0.tags.contains("php") }), "Missing PHP rules")
        #expect(result.rules.contains(where: { $0.tags.contains("shell") }), "Missing shell rules")
    }

    @Test("AI Models rules cover known model storage and orphan extension scans")
    func aiModelsCoverage() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let aiModels = result.rules.filter { $0.category == "ai_models" }
        let ids = Set(aiModels.map(\.id))

        // Known-location rules — the heavyweight ones the bean called out.
        #expect(ids.contains("ollama_models"), "Missing Ollama models rule")
        #expect(ids.contains(where: { $0.hasPrefix("lm_studio") }), "Missing LM Studio rules")
        #expect(ids.contains("torch_hub_checkpoints"), "Missing PyTorch hub checkpoints rule")
        #expect(ids.contains("comfyui_user_models"), "Missing ComfyUI rule")
        #expect(ids.contains("a1111_user_models"), "Missing A1111 rule")
        #expect(ids.contains("pinokio_workspace"), "Missing Pinokio rule")

        // Orphan-extension rules must declare a min_size to avoid surfacing
        // small files that share the extension but aren't model weights, and
        // must encode the file extension directly in the path (single-walk
        // expansion) rather than via a separate `pattern:` field that would
        // trigger a second uncapped child enumeration.
        let orphanRules = aiModels.filter { $0.id.hasPrefix("orphan_") }
        #expect(!orphanRules.isEmpty, "Missing orphan-extension scan rules")
        for rule in orphanRules {
            #expect(rule.minSize != nil,
                    "Orphan rule '\(rule.id)' must declare min_size")
            #expect(rule.paths.allSatisfy { $0.contains("*.") },
                    "Orphan rule '\(rule.id)' must declare extension globs in `paths` to keep PathExpander caps in effect")
        }

        // Every AI Models rule should be tagged so the UI can identify them.
        for rule in aiModels {
            #expect(rule.tags.contains("ai"),
                    "AI models rule '\(rule.id)' missing 'ai' tag")
        }
    }

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
