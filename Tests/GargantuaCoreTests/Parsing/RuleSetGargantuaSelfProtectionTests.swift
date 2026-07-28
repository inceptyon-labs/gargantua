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

    /// The state root Gargantua keeps its own data under.
    private static let protectedRoot = "~/Library/Application Support/Gargantua"

    /// Concrete things Gargantua keeps directly in its state root. Used only
    /// by the wildcard-ancestor clause below — never as the sole reach of the
    /// guard — because a rule like `~/Library/Application Support/*/models`
    /// wildcards the `Gargantua` segment itself, so no literal prefix match
    /// against `protectedRoot` is possible; fnmatch against representative
    /// children is the only way to catch it.
    private static let protectedSamples = [
        protectedRoot,
        "\(protectedRoot)/audit.lock",
        "\(protectedRoot)/rules",
        "\(protectedRoot)/models",
        "\(protectedRoot)/organizer-undo.json",
    ]

    /// A rule path offends the protected state root when either:
    ///
    /// 1. Ignoring any wildcard suffix, it literally names the root or
    ///    anything beneath it. This is generic: it covers arbitrary depth and
    ///    arbitrary filenames with no sample list needed — a deep path like
    ///    `.../Gargantua/models/*.bin`, a brand-new state file like
    ///    `.../Gargantua/some-future-state.db`, or a templated path like
    ///    `.../Gargantua/{bundleID}` are all caught because `protectedRoot`
    ///    is a literal prefix of each.
    /// 2. Its ANCESTOR segments are wildcarded (e.g.
    ///    `~/Library/Application Support/*/models`), so clause 1's literal
    ///    prefix check cannot see it — `*` is not literally `Gargantua`. This
    ///    clause is necessarily sample-based, and therefore INCOMPLETE: an
    ///    upstream rule wildcarding onto a state filename Gargantua adds
    ///    later, and not yet in `protectedSamples`, would not be caught until
    ///    that name is added here. It is a bounded, known limitation, not
    ///    full coverage.
    private static func offends(rulePath: String) -> Bool {
        if rulePath == protectedRoot || rulePath.hasPrefix(protectedRoot + "/") {
            return true
        }
        return protectedSamples.contains { sample in
            NativeScanAdapter.fnmatch(pattern: rulePath, name: sample)
        }
    }

    @Test("no bundled rule targets Gargantua's Application Support directory")
    func noRuleTargetsGargantuaApplicationSupport() throws {
        var offenders: [String] = []

        // cleanup_rules
        let cleanupDirectory = try #require(
            RuleDirectoryResolver.resolve(),
            "cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken"
        )
        let cleanupResult = try RuleLoader().loadRules(from: cleanupDirectory)
        for rule in cleanupResult.rules {
            for path in rule.paths where Self.offends(rulePath: path) {
                offenders.append("cleanup_rules/\(rule.id) → \(path)")
            }
        }

        // uninstall_rules — skip a templated path ({appName}, {bundleID},
        // {appNameVariant}) UNLESS it literally names Gargantua. The generic
        // template `~/Library/Application Support/{appName}` legitimately
        // resolves onto Gargantua's own Application Support folder only when
        // the user is deliberately uninstalling Gargantua itself, which is
        // intended behaviour, not the Deep Clean hazard this guard protects
        // against. But a template that literally contains `Gargantua` (e.g.
        // `~/Library/Application Support/Gargantua/{bundleID}`) is targeting
        // us specifically regardless of templating, and must still be
        // flagged.
        let uninstallDirectory = try #require(
            Bundle.module.url(forResource: "uninstall_rules", withExtension: nil),
            "uninstall_rules resource not resolvable via Bundle.module — SPM resource wiring broken"
        )
        let uninstallResult = try RemnantRuleLoader().loadRules(from: uninstallDirectory)
        for rule in uninstallResult.rules {
            for path in rule.pathTemplates {
                if path.contains("{") && !path.contains("Gargantua") {
                    continue
                }
                if Self.offends(rulePath: path) {
                    offenders.append("uninstall_rules/\(rule.id) → \(path)")
                }
            }
        }

        // command_rules
        let commandDirectory = try #require(
            CommandActionRuleDirectoryResolver.resolve(),
            "command_rules not resolvable via CommandActionRuleDirectoryResolver — SPM resource wiring broken"
        )
        let commandResult = try CommandActionRuleLoader().loadRules(from: commandDirectory)
        for rule in commandResult.rules {
            for path in rule.affectedRoots where Self.offends(rulePath: path) {
                offenders.append("command_rules/\(rule.id) → \(path)")
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
