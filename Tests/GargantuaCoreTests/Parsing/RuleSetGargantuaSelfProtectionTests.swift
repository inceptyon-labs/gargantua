import Foundation
import Testing
@testable import GargantuaCore

/// The bundled rules under `Sources/GargantuaCore/Resources/{cleanup_rules,
/// uninstall_rules,command_rules}/` are a synced snapshot of
/// `inceptyon-labs/gargantua-rules` (see AGENTS.md), so the protections
/// Gargantua relies on for its OWN state are owned upstream and can change
/// without anything here failing. These tests are the local guard.
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

    /// Concrete things Gargantua keeps in its own state directory. Patterns are
    /// checked against these rather than against a prefix string, because the
    /// rule set reaches app directories through wildcards like
    /// `~/Library/Application Support/*/logs` that a prefix test cannot see.
    private static let protectedPaths = [
        "~/Library/Application Support/Gargantua",
        "~/Library/Application Support/Gargantua/audit.lock",
        "~/Library/Application Support/Gargantua/rules",
        "~/Library/Application Support/Gargantua/models",
        "~/Library/Application Support/Gargantua/organizer-undo.json",
    ]

    /// A rule path is an offender against a protected path when either the
    /// path's wildcard pattern matches the protected path, or the protected
    /// path sits literally underneath the rule path (the rule names an
    /// ancestor directory outright, no wildcard involved).
    private static func offends(rulePath: String, protectedPath: String) -> Bool {
        NativeScanAdapter.fnmatch(pattern: rulePath, name: protectedPath)
            || protectedPath == rulePath
            || protectedPath.hasPrefix(rulePath + "/")
    }

    @Test("no bundled rule targets Gargantua's Application Support directory")
    func noRuleTargetsGargantuaApplicationSupport() throws {
        var offenders: [String] = []

        // cleanup_rules
        let cleanupResult = try RuleLoader().loadRules(from: RuleDirectoryResolver.resolve()!)
        for rule in cleanupResult.rules {
            for path in rule.paths {
                for protectedPath in Self.protectedPaths where Self.offends(rulePath: path, protectedPath: protectedPath) {
                    offenders.append("cleanup_rules/\(rule.id) → \(path)")
                }
            }
        }

        // uninstall_rules — skip templated paths ({appName}, {bundleID},
        // {appNameVariant}): those legitimately resolve onto Gargantua's own
        // Application Support folder only when the user is deliberately
        // uninstalling Gargantua itself, which is intended behaviour, not the
        // Deep Clean hazard this guard is protecting against.
        let uninstallDirectory = Bundle.module.url(forResource: "uninstall_rules", withExtension: nil)!
        let uninstallResult = try RemnantRuleLoader().loadRules(from: uninstallDirectory)
        for rule in uninstallResult.rules {
            for path in rule.pathTemplates where !path.contains("{") {
                for protectedPath in Self.protectedPaths where Self.offends(rulePath: path, protectedPath: protectedPath) {
                    offenders.append("uninstall_rules/\(rule.id) → \(path)")
                }
            }
        }

        // command_rules
        let commandDirectory = CommandActionRuleDirectoryResolver.resolve()!
        let commandResult = try CommandActionRuleLoader().loadRules(from: commandDirectory)
        for rule in commandResult.rules {
            for path in rule.affectedRoots {
                for protectedPath in Self.protectedPaths where Self.offends(rulePath: path, protectedPath: protectedPath) {
                    offenders.append("command_rules/\(rule.id) → \(path)")
                }
            }
        }

        // Home of the audit.lock sidecar, the organizer undo ledger, user rules
        // and downloaded models. A rule reaching in here would break mutation
        // exclusion or destroy undo state.
        #expect(
            offenders.isEmpty,
            "Bundled rules must not target Gargantua's own state directory: \(offenders)"
        )
    }
}
