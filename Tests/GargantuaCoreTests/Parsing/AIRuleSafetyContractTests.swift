import Foundation
import Testing
@testable import GargantuaCore

/// Mechanical checks on the safety contract the AI tool rules are written to.
///
/// Three review rounds on those rules produced the same classes of defect: a
/// path that looked disposable by its name but held conversation history or
/// credentials, an age gate pointed at something whose timestamp doesn't move
/// when the content does, and a live database sitting beside the files being
/// matched. These assert those invariants across the whole bundled rule set.
///
/// Each check models what the engine actually does with a rule: a rule with a
/// `pattern` enumerates the children of each declared path, and a rule without
/// one emits the declared path itself. Checking only one of those shapes is how
/// an earlier version of this file let a whole-directory rule through.
@Suite("AI rule safety contract")
struct AIRuleSafetyContractTests {
    let loader = RuleLoader()

    private var rulesDirectory: URL {
        guard let url = RuleDirectoryResolver.resolve() else {
            fatalError("cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    /// Files that hold an AI tool's credentials, tokens or settings. No rule may
    /// emit one, emit a directory containing one, or enumerate its parent with a
    /// pattern that matches it.
    ///
    /// Sources: `oauth_creds.json` and `mcp-oauth-tokens.json` in both Qwen
    /// Code's and Gemini CLI's `config/storage.ts`; `providers.json` ("API keys
    /// and provider credentials") in Cline's config docs; `~/.aws/credentials`.
    private static let protectedFiles = [
        "~/.qwen/oauth_creds.json",
        "~/.qwen/mcp-oauth-tokens.json",
        "~/.qwen/settings.json",
        "~/.gemini/oauth_creds.json",
        "~/.gemini/settings.json",
        "~/.claude/settings.json",
        "~/.claude/.credentials.json",
        "~/.codex/auth.json",
        "~/.aws/credentials",
        "~/.aws/config",
        "~/.cline/data/settings/providers.json",
        "~/.continue/config.yaml",
        "~/.local/share/goose/sessions/sessions.db",
    ]

    /// Live databases that sit in the same directories these rules work in.
    ///
    /// Checked as full paths, not bare names: a `pattern: "*"` rule is only a
    /// hazard where a database actually lives, and flagging every such rule
    /// everywhere would be noise rather than a contract.
    private static let protectedDatabases = [
        "~/.local/share/goose/sessions/sessions.db",
        "~/.local/share/goose/sessions/sessions.db-wal",
        "~/.local/share/goose/sessions/sessions.db-shm",
        "~/.cline/data/db/cron.db",
        "~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db",
        "~/Library/Application Support/Code/User/workspaceStorage/abc123/state.vscdb",
    ]

    /// Filename suffixes no rule may declare directly, wherever it is anchored.
    private static let databaseSuffixes = [".db", ".db-wal", ".db-shm", ".sqlite", ".sqlite3", ".vscdb"]

    @Test("No rule can reach a credential, settings file, or live database")
    func noRuleReachesProtectedFile() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules {
            for declared in rule.paths {
                let path = Self.normalized(declared)
                for protectedFile in Self.protectedFiles + Self.protectedDatabases {
                    if let pattern = rule.pattern {
                        // The rule enumerates this directory's children.
                        let parent = Self.normalized((protectedFile as NSString).deletingLastPathComponent)
                        let name = (protectedFile as NSString).lastPathComponent
                        #expect(
                            !(path == parent && Self.matches(pattern, name)),
                            "Rule \(rule.id) enumerates \(declared) with pattern \(pattern), which selects \(protectedFile)"
                        )
                    } else {
                        // The rule emits this path itself, taking everything under it.
                        #expect(
                            !Self.isAncestorOrSelf(path, of: protectedFile),
                            "Rule \(rule.id) emits \(declared), which would remove \(protectedFile)"
                        )
                    }
                }
            }
        }
    }

    @Test("No rule declares a database path directly")
    func noRuleDeclaresDatabasePath() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules {
            for declared in rule.paths where Self.databaseSuffixes.contains(where: declared.hasSuffix) {
                Issue.record(
                    """
                    Rule \(rule.id) targets \(declared). Removing a live database without its \
                    -wal/-shm sidecars can corrupt the owning tool, and the running-process \
                    guard only sees GUI apps, so a CLI cannot be guarded.
                    """
                )
            }
        }
    }

    @Test("Every ai_history rule is gated on a minimum age, not merely on some filter")
    func aiHistoryRulesAreAgeGated() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules
        let history = rules.filter { $0.tags.contains("ai_history") }

        #expect(!history.isEmpty, "Expected the bundle to carry ai_history rules")
        for rule in history {
            #expect(
                rule.matchFilters.contains(where: Self.isMinimumAgeFilter),
                """
                Rule \(rule.id) is tagged ai_history but has no minimum-age filter \
                (\(rule.matchFilters)). It needs one of the form "mtime > Nd" so content \
                in active use is never proposed — a "<" filter selects the recent items instead.
                """
            )
        }
    }

    @Test("No ai_history rule is safe, and none is promoted to safe by an override")
    func aiHistoryRulesAreReviewInEveryProfile() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules where rule.tags.contains("ai_history") {
            #expect(
                rule.safety == .review,
                "Rule \(rule.id) is tagged ai_history but classified \(rule.safety.rawValue)"
            )
            for override in rule.safetyOverrides {
                #expect(
                    override.safety != .safe,
                    """
                    Rule \(rule.id) is tagged ai_history but its override "\(override.condition)" \
                    promotes it to safe, which lets conversation content be bulk-selected.
                    """
                )
            }
        }
    }

    // MARK: - Helpers

    private static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Whether `ancestor` is `path` or a directory containing it. Glob segments
    /// are compared segment-wise so `~/.qwen/tmp/*` is recognised as covering
    /// `~/.qwen/tmp/anything/file`.
    private static func isAncestorOrSelf(_ ancestor: String, of path: String) -> Bool {
        let a = normalized(ancestor).split(separator: "/").map(String.init)
        let b = normalized(path).split(separator: "/").map(String.init)
        guard a.count <= b.count else { return false }
        return zip(a, b).allSatisfy { matches($0, $1) }
    }

    /// True for a filter that establishes a *minimum* age, e.g. "mtime > 30d".
    private static func isMinimumAgeFilter(_ filter: String) -> Bool {
        let parts = filter.split(separator: ">", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, ["mtime", "atime", "age"].contains(parts[0]) else { return false }
        return parts[1].hasSuffix("d") || parts[1].hasSuffix("h")
    }

    private static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
