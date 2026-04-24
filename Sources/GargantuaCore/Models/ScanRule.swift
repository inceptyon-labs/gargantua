import Foundation

/// Top-level container for a YAML rule file.
///
/// Each rule file declares one or more scan rules that tell Gargantua
/// what paths to look for, how to classify them, and which app created them.
public struct RuleFile: Codable, Sendable {
    /// The scan rules declared in this file.
    public let rules: [ScanRule]

    public init(rules: [ScanRule]) {
        self.rules = rules
    }
}

/// A declarative scan rule that defines what to look for and how to classify it.
///
/// Rules are the authoritative source of safety classifications — the Trust Layer
/// derives all safety decisions from these, and AI cannot override them.
public struct ScanRule: Codable, Sendable, Identifiable {
    /// Stable unique identifier (e.g., "chrome_cache", "xcode_derived_data").
    public let id: String

    /// Human-readable name (e.g., "Chrome Browser Cache").
    public let name: String

    /// Glob paths to scan, supporting `~` expansion and `**` wildcards.
    public let paths: [String]

    /// Optional filename pattern within matched paths (e.g., "Cache/*").
    public let pattern: String?

    /// Paths or patterns to exclude from matches.
    public let exclude: [String]

    /// Running process identifiers that cause the rule to be skipped.
    ///
    /// Values may be bundle identifiers (preferred) or process/app names.
    public let skipIfProcessRunning: [String]

    /// Candidate-relative or absolute paths that skip a match when present.
    public let presenceGuards: [RulePresenceGuard]

    /// Candidate-relative or absolute files whose contents can skip a match.
    public let contentGuards: [RuleContentGuard]

    /// Conditions that must match before a filesystem item is surfaced.
    ///
    /// Supports the same age expressions as `SafetyOverride`, plus `mtime`
    /// and `atime` prefixes for modification/access time filters.
    public let matchFilters: [String]

    /// Trust Layer safety classification for matched items.
    public let safety: SafetyLevel

    /// Confidence percentage (0–100) in the safety classification.
    public let confidence: Int

    /// One-line explanation of what this item is and why it's classified this way.
    public let explanation: String

    /// Attribution for the app or process that created these items.
    public let source: SourceAttribution

    /// Whether matched items can be regenerated (e.g., caches, build artifacts).
    public let regenerates: Bool

    /// Command to regenerate matched items, if applicable (e.g., "npm install").
    public let regenerateCommand: String?

    /// Scan category for grouping and profile filtering (e.g., "browser_cache").
    public let category: String

    /// Tags for additional filtering and grouping.
    public let tags: [String]

    /// Condition-based overrides that reclassify items for specific profiles.
    ///
    /// Overrides support age-based expressions (e.g., `age > 30d`) and can be
    /// scoped to specific cleanup profiles (e.g., `["developer", "deep"]`).
    public let safetyOverrides: [SafetyOverride]

    public init(
        id: String,
        name: String,
        paths: [String],
        pattern: String? = nil,
        exclude: [String] = [],
        skipIfProcessRunning: [String] = [],
        presenceGuards: [RulePresenceGuard] = [],
        contentGuards: [RuleContentGuard] = [],
        matchFilters: [String] = [],
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        source: SourceAttribution,
        regenerates: Bool = false,
        regenerateCommand: String? = nil,
        category: String,
        tags: [String] = [],
        safetyOverrides: [SafetyOverride] = []
    ) {
        self.id = id
        self.name = name
        self.paths = paths
        self.pattern = pattern
        self.exclude = exclude
        self.skipIfProcessRunning = skipIfProcessRunning
        self.presenceGuards = presenceGuards
        self.contentGuards = contentGuards
        self.matchFilters = matchFilters
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.source = source
        self.regenerates = regenerates
        self.regenerateCommand = regenerateCommand
        self.category = category
        self.tags = tags
        self.safetyOverrides = safetyOverrides
    }
}

/// How a rule guard's `path` should be resolved.
public enum RuleGuardPathScope: String, Codable, Sendable, Equatable {
    /// Resolve the guard path relative to the matched candidate path.
    case candidate

    /// Treat the guard path as an absolute or tilde-expanded path.
    case absolute
}

/// A simple filesystem presence predicate attached to a cleanup rule.
public struct RulePresenceGuard: Codable, Sendable, Equatable {
    /// Candidate-relative path by default, or absolute path when `scope == .absolute`.
    public let path: String

    /// Path resolution scope.
    public let scope: RuleGuardPathScope

    public init(path: String, scope: RuleGuardPathScope = .candidate) {
        self.path = path
        self.scope = scope
    }
}

/// A bounded content predicate attached to a cleanup rule.
public struct RuleContentGuard: Codable, Sendable, Equatable {
    /// Candidate-relative path by default, or absolute path when `scope == .absolute`.
    public let path: String

    /// Substrings that cause the candidate to be skipped when found.
    public let contains: [String]

    /// Path resolution scope.
    public let scope: RuleGuardPathScope

    public init(path: String, contains: [String], scope: RuleGuardPathScope = .candidate) {
        self.path = path
        self.contains = contains
        self.scope = scope
    }
}
