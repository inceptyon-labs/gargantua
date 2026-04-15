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
