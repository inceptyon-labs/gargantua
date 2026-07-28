import Foundation
import Testing
@testable import GargantuaCore

/// The bundled rules under `Sources/GargantuaCore/Resources/cleanup_rules/` are
/// a synced snapshot of `inceptyon-labs/gargantua-rules` (see AGENTS.md), so
/// the protections Gargantua relies on for its OWN state are owned upstream and
/// can change without anything here failing. These tests are the local guard.
@Suite("Rule set does not sweep Gargantua's own state")
struct RuleSetGargantuaSelfProtectionTests {
    let loader = RuleLoader()

    private var rulesDirectory: URL {
        guard let url = RuleDirectoryResolver.resolve() else {
            fatalError("cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    @Test("system_logs excludes the Gargantua log directory")
    func systemLogsExcludesGargantuaLogs() throws {
        let result = try loader.loadRules(from: rulesDirectory)
        let rule = try #require(
            result.rules.first { $0.id == "system_logs" },
            "system_logs rule is missing from the bundled rule set"
        )

        // The audit log at ~/Library/Logs/Gargantua/audit.json is forensic
        // record; a sweep of ~/Library/Logs would erase it.
        #expect(
            rule.exclude.contains("*/Gargantua"),
            "system_logs sweeps ~/Library/Logs and must keep excluding */Gargantua — current excludes: \(rule.exclude)"
        )
    }

    @Test("no bundled rule targets Gargantua's Application Support directory")
    func noRuleTargetsGargantuaApplicationSupport() throws {
        let result = try loader.loadRules(from: rulesDirectory)

        // Home of the audit.lock sidecar, the organizer undo ledger, user rules
        // and downloaded models. A rule reaching in here would break mutation
        // exclusion or destroy undo state.
        let protectedPrefix = "~/Library/Application Support/Gargantua"
        let offenders = result.rules.flatMap { rule in
            rule.paths
                .filter { $0 == protectedPrefix || $0.hasPrefix(protectedPrefix + "/") }
                .map { "\(rule.id) → \($0)" }
        }

        #expect(
            offenders.isEmpty,
            "Bundled rules must not target Gargantua's own state directory: \(offenders)"
        )
    }
}
