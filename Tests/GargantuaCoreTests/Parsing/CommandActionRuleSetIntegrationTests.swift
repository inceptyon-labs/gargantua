import Foundation
import Testing
@testable import GargantuaCore

/// Validates the bundled `command_rules/` snapshot.
@Suite("Command Action Rule Set Integration")
struct CommandActionRuleSetIntegrationTests {
    let loader = CommandActionRuleLoader()

    private var rulesDirectory: URL {
        guard let url = CommandActionRuleDirectoryResolver.resolve() else {
            fatalError("command_rules not resolvable via CommandActionRuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    @Test("All command-rule files load without errors")
    func allFilesLoadCleanly() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        #expect(result.isClean, "Parse errors: \(result.errors.map(\.description))")
        #expect(result.filesLoaded >= 3)
    }

    @Test("Starter set is present")
    func starterSetPresent() throws {
        let ids = try Set(loader.loadRules(from: rulesDirectory).rules.map(\.id))
        #expect(ids.contains("simctl_delete_unavailable"))
        #expect(ids.contains("pnpm_store_prune"))
        #expect(ids.contains("go_clean_cache"))
    }

    @Test("All command rules use the developer_tool_command category")
    func sharedCategory() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(rule.category == "developer_tool_command", "\(rule.id) has unexpected category: \(rule.category)")
        }
    }

    @Test("All rule IDs are unique")
    func uniqueIDs() throws {
        let ids = try loader.loadRules(from: rulesDirectory).rules.map(\.id)
        #expect(ids.count == Set(ids).count, "Duplicate command-rule IDs: \(ids)")
    }

    @Test("No bundled rule declares safety: protected")
    func noProtectedSafety() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(rule.safety != .protected_, "\(rule.id) is protected — disallowed for command rules")
        }
    }

    @Test("Every rule declares at least one affected root")
    func declaresAffectedRoots() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        for rule in result.rules {
            #expect(!rule.affectedRoots.isEmpty, "\(rule.id) has no affected_roots — Trust Layer can't validate it")
        }
    }
}
