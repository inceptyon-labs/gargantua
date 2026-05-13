import Foundation
import Testing
@testable import GargantuaCore

/// Integration tests validating that the shipped cleanup_rules/ YAML files
/// load cleanly and that every rule has the structural fields it needs.
@Suite("Rule Set Integration: loading and rule completeness")
struct RuleSetIntegrationCompletenessTests {
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
}
