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
    ///
    /// `checkpoint-<tag>.json` are the saved `/chat` conversations Gemini CLI's
    /// `core/logger.ts` writes beside `logs.json`.
    private static let protectedFiles = [
        "~/.qwen/oauth_creds.json",
        "~/.qwen/mcp-oauth-tokens.json",
        "~/.qwen/settings.json",
        "~/.gemini/oauth_creds.json",
        "~/.gemini/settings.json",
        "~/.gemini/tmp/abc123/checkpoint-mytag.json",
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

    @Test("No rule can reach a credential, settings file, or live database")
    func noRuleReachesProtectedFile() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules {
            for declared in rule.paths {
                let path = Self.normalized(declared)
                for protectedFile in Self.protectedFiles + Self.protectedDatabases {
                    if let pattern = rule.pattern {
                        // The rule selects a child of a resolved directory: the file
                        // itself, or a directory containing it.
                        let reached = Self.selectedChild(declared: path, pattern: pattern, reaching: protectedFile)
                        #expect(
                            reached == nil,
                            """
                            Rule \(rule.id) enumerates \(declared) with pattern \(pattern), which selects \
                            \(reached ?? "") and so reaches \(protectedFile)
                            """
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

    @Test("A rule that declares a database path names the processes that own it")
    func databaseRulesAreProcessGuarded() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules {
            for declared in Self.selectors(of: rule) where Self.selectsDatabase(declared) {
                #expect(
                    !rule.skipIfProcessRunning.isEmpty,
                    """
                    Rule \(rule.id) selects \(declared) without skip_if_process_running. The engine \
                    removes a database together with its -wal/-shm/-journal, but removing one its \
                    owner has open still loses the owner's state: name the owner's bundle ID and, \
                    for a command-line owner, its executable name.
                    """
                )
            }
        }
    }

    @Test("No rule declares a database sidecar directly")
    func noRuleDeclaresDatabaseSidecar() throws {
        let rules = try loader.loadRules(from: rulesDirectory).rules

        for rule in rules {
            for declared in Self.selectors(of: rule) {
                #expect(
                    !Self.selectsSidecar(declared),
                    "Rule \(rule.id) selects \(declared). Sidecars go with their database, never on their own."
                )
            }
        }
    }

    /// The globs a rule selects files with: its declared paths, plus its
    /// `pattern`, which picks children inside those paths.
    private static func selectors(of rule: ScanRule) -> [String] {
        rule.paths + [rule.pattern].compactMap { $0 }
    }

    /// Whether a glob can select a SQLite database file.
    static func selectsDatabase(_ glob: String) -> Bool {
        let name = lastComponent(glob)
        return databaseProbes(for: name).contains { fnmatch(name, $0, 0) == 0 }
    }

    /// Whether a glob can select a SQLite sidecar (`x.db-wal`, `*-wal`, `x.db*`).
    static func selectsSidecar(_ glob: String) -> Bool {
        let name = lastComponent(glob)
        let probes = databaseProbes(for: name).flatMap { database in
            SQLiteDatabaseFiles.sidecarSuffixes.map { database + $0 }
        }
        return probes.contains { fnmatch(name, $0, 0) == 0 }
    }

    private static func lastComponent(_ glob: String) -> String {
        (glob as NSString).lastPathComponent.lowercased()
    }

    /// Concrete database filenames a glob is matched against: its text with the
    /// wildcards dropped and its leading literal part, each with every database
    /// suffix added. Empty unless the glob mentions a database or sidecar
    /// suffix, so a bare `*` (covered by `protectedDatabases` where a database
    /// actually lives) isn't flagged everywhere.
    private static func databaseProbes(for name: String) -> [String] {
        let wildcards: Set<Character> = ["*", "?", "[", "]"]
        guard mentionsDatabaseSuffix(name, wildcards: wildcards) else { return [] }
        let filled = filledIn(name)
        let prefix = String(name.prefix { !wildcards.contains($0) })
        var bases = [filled, prefix, prefix + "x", "x"]
        for sidecar in SQLiteDatabaseFiles.sidecarSuffixes where filled.hasSuffix(sidecar) {
            bases.append(String(filled.dropLast(sidecar.count)))
        }
        let candidates = bases + bases.flatMap { base in SQLiteDatabaseFiles.suffixes.map { base + $0 } }
        return candidates.filter(SQLiteDatabaseFiles.isDatabase)
    }

    /// One concrete name a glob matches: `*` matches nothing, `?` an `x`, and a
    /// `[...]` class its first member.
    private static func filledIn(_ glob: String) -> String {
        var result = ""
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                break
            case "?":
                result.append("x")
            case "[":
                let close = glob[index...].firstIndex(of: "]") ?? glob.endIndex
                let members = glob[glob.index(after: index) ..< close].filter { $0 != "!" && $0 != "^" }
                if let first = members.first { result.append(first) }
                index = close == glob.endIndex ? close : glob.index(after: close)
                continue
            default:
                result.append(character)
            }
            index = glob.index(after: index)
        }
        return result
    }

    /// Whether a database or sidecar suffix appears as a suffix: at the end of
    /// the name or before a wildcard or a sidecar's `-`. `.db` inside
    /// `com.dbeaver.*` doesn't count.
    private static func mentionsDatabaseSuffix(_ name: String, wildcards: Set<Character>) -> Bool {
        let markers = SQLiteDatabaseFiles.suffixes + SQLiteDatabaseFiles.sidecarSuffixes
        return markers.contains { marker in
            var searchStart = name.startIndex
            while let found = name.range(of: marker, range: searchStart ..< name.endIndex) {
                if found.upperBound == name.endIndex { return true }
                let next = name[found.upperBound]
                if wildcards.contains(next) || next == "-" { return true }
                searchStart = name.index(after: found.lowerBound)
            }
            return false
        }
    }

    @Test(
        "Database and sidecar selectors are judged by what their globs match",
        arguments: [
            ("~/.codex/logs_*.sqlite", true, false),
            ("~/.codex/logs_*.sqlite*", true, true),
            ("~/.codex/logs_*.sqlite-w*", true, true),
            ("~/Library/Caches/com.dbeaver.*", false, false),
            ("logs_??.sqlite", true, false),
            ("logs_[0-9].sqlite", true, false),
            ("[cC]onfig.db", true, false),
            ("logs_*_?.sqlite", true, false),
            ("*-wal", false, true),
            ("~/Library/Application Support/Dropbox/instance*/config.db*", true, true),
            ("~/Library/Application Support/Dropbox/instance*/config.db", true, false),
            ("state.vscdb-shm", false, true),
            ("*", false, false),
            ("*.png", false, false),
            ("rollout-*.jsonl", false, false),
        ]
    )
    func selectorClassification(glob: String, database: Bool, sidecar: Bool) {
        #expect(Self.selectsDatabase(glob) == database, "selectsDatabase(\(glob))")
        #expect(Self.selectsSidecar(glob) == sidecar, "selectsSidecar(\(glob))")
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

    /// Whether `ancestor` is `path` or a directory containing it. Globs follow
    /// `PathExpander`: `*` is one segment, `**` is zero or more.
    private static func isAncestorOrSelf(_ ancestor: String, of path: String) -> Bool {
        let a = normalized(ancestor).split(separator: "/").map(String.init)
        let b = normalized(path).split(separator: "/").map(String.init)
        return (1 ... max(b.count, 1)).contains { globMatches(a, Array(b.prefix($0))) }
    }

    /// The child a `pattern` rule selects on the way to `file`, or nil. `declared`
    /// resolves to an ancestor directory of `file` and `pattern` matches the next
    /// segment down: `file` itself, or a directory containing it.
    private static func selectedChild(declared: String, pattern: String, reaching file: String) -> String? {
        let d = normalized(declared).split(separator: "/").map(String.init)
        let f = normalized(file).split(separator: "/").map(String.init)
        guard f.count > 1 else { return nil }
        for k in 1 ..< f.count where globMatches(d, Array(f[0 ..< k])) && matches(pattern, f[k]) {
            return f[0 ... k].joined(separator: "/")
        }
        return nil
    }

    /// Full segment-wise glob match where `**` matches zero or more segments.
    private static func globMatches(_ pattern: [String], _ path: [String]) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        let rest = Array(pattern.dropFirst())
        if head == "**" {
            return (0 ... path.count).contains { globMatches(rest, Array(path.dropFirst($0))) }
        }
        guard let first = path.first, matches(head, first) else { return false }
        return globMatches(rest, Array(path.dropFirst()))
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
