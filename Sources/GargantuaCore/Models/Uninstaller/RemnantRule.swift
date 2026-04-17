import Foundation

/// Top-level container for a YAML remnant-rule file.
///
/// A remnant-rule file declares one or more `RemnantRule`s that describe
/// where an uninstalled app may have left files on disk. Rules are
/// parameterised with placeholders (`{bundleID}`, `{appName}`, `{teamID}`)
/// which the scanner expands at runtime against a concrete `AppInfo`.
public struct RemnantRuleFile: Codable, Sendable {
    /// The remnant rules declared in this file.
    public let rules: [RemnantRule]

    public init(rules: [RemnantRule]) {
        self.rules = rules
    }
}

/// A declarative rule for discovering uninstall remnants.
///
/// A remnant rule is conceptually a `ScanRule` scoped to an app uninstall
/// context: the `pathTemplates` are expanded against a specific app's
/// metadata, the `category` selects a default safety, and the `appliesTo`
/// scope can narrow a rule to a subset of apps.
public struct RemnantRule: Codable, Sendable, Identifiable {
    /// Stable unique identifier (e.g., `generic_support_files`, `slack_webdata`).
    public let id: String

    /// Human-readable name (e.g., `Application Support folder`).
    public let name: String

    /// Remnant category — drives `defaultSafety` unless explicitly overridden.
    public let category: RemnantCategory

    /// Path templates with `{bundleID}`, `{appName}`, `{teamID}` placeholders.
    ///
    /// Supports `~` expansion and `**` wildcards, same as `ScanRule.paths`.
    public let pathTemplates: [String]

    /// Optional filename pattern within matched paths (e.g., `*.plist`).
    public let pattern: String?

    /// Paths or patterns to exclude from matches.
    public let exclude: [String]

    /// Trust Layer safety classification for matched items.
    ///
    /// Authors may omit this in YAML to inherit `category.defaultSafety`;
    /// the parser fills in the default when no explicit value is given.
    public let safety: SafetyLevel

    /// Confidence percentage (0–100) in the safety classification.
    public let confidence: Int

    /// One-line explanation shown in the Trust Layer / audit log.
    public let explanation: String

    /// Attribution for the process that originally wrote these files.
    ///
    /// For remnants, this typically mirrors the owning app. Generic rules
    /// (e.g., a rule that matches `~/Library/Application Support/{AppName}/`
    /// for any app) use a `name` such as `"macOS"` or the app's own name
    /// resolved at expansion time.
    public let source: SourceAttribution

    /// Optional scope restricting this rule to a subset of apps.
    public let appliesTo: AppScope?

    /// Whether matched items regenerate if the app is reinstalled.
    public let regenerates: Bool

    /// Tags for filtering and grouping (e.g., `["generic", "sandbox"]`).
    public let tags: [String]

    public init(
        id: String,
        name: String,
        category: RemnantCategory,
        pathTemplates: [String],
        pattern: String? = nil,
        exclude: [String] = [],
        safety: SafetyLevel? = nil,
        confidence: Int,
        explanation: String,
        source: SourceAttribution,
        appliesTo: AppScope? = nil,
        regenerates: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.pathTemplates = pathTemplates
        self.pattern = pattern
        self.exclude = exclude
        self.safety = safety ?? category.defaultSafety
        self.confidence = confidence
        self.explanation = explanation
        self.source = source
        self.appliesTo = appliesTo
        self.regenerates = regenerates
        self.tags = tags
    }
}

/// Narrows a `RemnantRule` to a subset of apps by bundle identifier.
///
/// When both `bundleIDs` and `excludeBundleIDs` are non-empty, a rule
/// applies to an app if its bundle ID is in `bundleIDs` **and** not in
/// `excludeBundleIDs`. When `bundleIDs` is `nil` or empty, the rule
/// applies to all apps except those listed in `excludeBundleIDs`.
public struct AppScope: Codable, Sendable, Equatable {
    /// Allow-list of bundle IDs the rule applies to.
    public let bundleIDs: [String]

    /// Deny-list of bundle IDs the rule must skip.
    public let excludeBundleIDs: [String]

    public init(bundleIDs: [String] = [], excludeBundleIDs: [String] = []) {
        self.bundleIDs = bundleIDs
        self.excludeBundleIDs = excludeBundleIDs
    }

    /// Whether this scope applies to an app with the given bundle ID.
    public func matches(bundleID: String) -> Bool {
        if excludeBundleIDs.contains(bundleID) { return false }
        if bundleIDs.isEmpty { return true }
        return bundleIDs.contains(bundleID)
    }
}
