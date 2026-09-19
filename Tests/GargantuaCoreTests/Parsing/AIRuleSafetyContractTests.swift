import Foundation
import Testing
@testable import GargantuaCore

/// Mechanical checks on the safety contract the AI tool rules are written to.
///
/// Two review rounds on those rules produced the same class of defect twice: a
/// path that looked disposable by its name but held conversation history or
/// credentials, and an age gate pointed at something whose timestamp doesn't
/// move when the content does. These assert the invariants that came out of
/// those rounds against the whole bundled rule set, so the next rule that
/// breaks one fails here rather than on a user's disk.
@Suite("AI rule safety contract")
struct AIRuleSafetyContractTests {
    let loader = RuleLoader()

    private var rulesDirectory: URL {
        guard let url = RuleDirectoryResolver.resolve() else {
            fatalError("cleanup_rules not resolvable via RuleDirectoryResolver — SPM resource wiring broken")
        }
        return url
    }

    /// Directories that hold an AI tool's credentials, tokens or settings
    /// alongside whatever else is in them. A rule may reach *into* these for a
    /// specific child, but must never enumerate one, because `pattern` would
    /// sweep the secrets up with the history.
    ///
    /// Sources: `~/.qwen` and `~/.gemini` hold `oauth_creds.json` and
    /// `mcp-oauth-tokens.json` (both projects' `config/storage.ts`);
    /// `~/.cline/data/settings/providers.json` holds API keys (Cline config
    /// docs); `~/.aws` holds `credentials` and `config`.
    private static let credentialBearingRoots = [
        "~/.qwen",
        "~/.gemini",
        "~/.claude",
        "~/.codex",
        "~/.aws",
        "~/.cline",
        "~/.cline/data",
        "~/.cline/data/settings",
        "~/.continue",
    ]

    @Test("No rule enumerates a directory that holds AI tool credentials")
    func noRuleEnumeratesCredentialBearingRoot() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules where rule.pattern != nil {
            for path in rule.paths {
                let normalized = Self.normalized(path)
                #expect(
                    !Self.credentialBearingRoots.contains(normalized),
                    """
                    Rule \(rule.id) enumerates \(path) with pattern \(rule.pattern ?? "") — \
                    that directory holds credentials or settings, so a child glob can match them. \
                    Target the specific history subdirectory instead.
                    """
                )
            }
        }
    }

    @Test("Goose session rule cannot match the SQLite store that shares its directory")
    func gooseRuleExcludesSessionDatabase() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules
        let goose = try #require(rules.first { $0.id == "goose_legacy_sessions" })
        let pattern = try #require(goose.pattern)

        // `~/.local/share/goose/sessions/` holds both the legacy transcripts
        // and goose's live sessions.db. Matching the database — or its -wal and
        // -shm sidecars — would corrupt goose's current state.
        #expect(Self.matches(pattern, "20260101_120000.jsonl"))
        #expect(!Self.matches(pattern, "sessions.db"))
        #expect(!Self.matches(pattern, "sessions.db-wal"))
        #expect(!Self.matches(pattern, "sessions.db-shm"))
    }

    @Test("Every ai_history rule is age-gated")
    func aiHistoryRulesAreAgeGated() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules
        let history = rules.filter { $0.tags.contains("ai_history") }

        #expect(!history.isEmpty, "Expected the bundle to carry ai_history rules")
        for rule in history {
            #expect(
                !rule.matchFilters.isEmpty,
                """
                Rule \(rule.id) is tagged ai_history but carries no match_filters. \
                Anything holding conversation or generated output must be age-gated \
                so a session in active use is never proposed.
                """
            )
        }
    }

    @Test("Every ai_history rule is review, never safe")
    func aiHistoryRulesAreReview() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules where rule.tags.contains("ai_history") {
            #expect(
                rule.safety == .review,
                "Rule \(rule.id) is tagged ai_history but classified \(rule.safety.rawValue) — conversation content is never safe"
            )
        }
    }

    @Test("No rule targets a SQLite database")
    func noRuleTargetsSQLiteDatabase() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules
        let databaseSuffixes = [".db", ".sqlite", ".sqlite3", ".db-wal", ".db-shm"]

        for rule in rules {
            for path in rule.paths where databaseSuffixes.contains(where: path.hasSuffix) {
                Issue.record(
                    """
                    Rule \(rule.id) targets \(path). Removing a live database without its \
                    -wal/-shm sidecars can corrupt the owning tool, and the running-process \
                    guard only sees GUI apps, so a CLI cannot be guarded.
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

    private static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}
