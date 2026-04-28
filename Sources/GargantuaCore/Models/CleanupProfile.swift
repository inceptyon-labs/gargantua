import Foundation

/// A cleanup profile that determines which categories are scanned and how safety overrides apply.
public struct CleanupProfile: Codable, Sendable, Identifiable {
    public let id: String

    /// Display name (e.g., "Developer", "Light Cleanup").
    public let name: String

    /// Description of what this profile does.
    public let description: String

    /// Categories included in scans using this profile.
    public let categories: [String]

    /// Safety overrides that can reclassify items based on conditions.
    public let safetyOverrides: [SafetyOverride]

    /// Whether this profile was created by the user (vs. built-in).
    public let isCustom: Bool

    public init(
        id: String,
        name: String,
        description: String,
        categories: [String],
        safetyOverrides: [SafetyOverride] = [],
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.categories = categories
        self.safetyOverrides = safetyOverrides
        self.isCustom = isCustom
    }
}

/// A condition-based override that reclassifies items for specific profiles.
///
/// Example: Developer profile auto-classifies node_modules older than 30 days as safe.
public struct SafetyOverride: Codable, Sendable {
    /// Condition expression (e.g., "age > 30d").
    public let condition: String

    /// The safety level to assign when the condition matches.
    public let safety: SafetyLevel

    /// Override confidence value.
    public let confidence: Int?

    /// Suffix appended to the base explanation when this override applies.
    public let explanationSuffix: String?

    /// Which profile IDs this override applies to. Empty means all profiles.
    public let profiles: [String]

    public init(
        condition: String,
        safety: SafetyLevel,
        confidence: Int? = nil,
        explanationSuffix: String? = nil,
        profiles: [String] = []
    ) {
        self.condition = condition
        self.safety = safety
        self.confidence = confidence
        self.explanationSuffix = explanationSuffix
        self.profiles = profiles
    }
}

extension CleanupProfile {
    /// Built-in Developer profile.
    public static let developer = CleanupProfile(
        id: "developer",
        name: "Developer",
        description: "All caches + app caches + dev artifacts + Docker + Homebrew + installers",
        categories: [
            "browser_cache", "system_cache", "system_logs", "temp_files", "trash",
            "app_cache", "dev_artifacts", "docker", "homebrew", "installers",
        ],
        safetyOverrides: [
            SafetyOverride(
                condition: "age > 30d",
                safety: .safe,
                confidence: 95,
                explanationSuffix: "No project activity in 30+ days. Restore with package manager.",
                profiles: ["developer"]
            ),
        ]
    )

    /// Built-in Light Cleanup profile.
    public static let light = CleanupProfile(
        id: "light",
        name: "Light Cleanup",
        description: "Browser caches + app caches + system logs + Trash + installers",
        categories: [
            "browser_cache", "app_cache", "system_logs", "trash", "installers"
        ]
    )

    /// Built-in Deep Clean profile.
    public static let deep = CleanupProfile(
        id: "deep",
        name: "Deep Clean",
        description: "Everything + app data + similar images + empty files + broken symlinks",
        categories: [
            "browser_cache", "browser_data", "system_cache", "system_logs",
            "temp_files", "trash", "app_cache", "app_data", "dev_artifacts", "docker", "homebrew",
            "installers", "similar_images", "empty_files", "broken_symlinks", "ai_models",
        ],
        safetyOverrides: [
            SafetyOverride(
                condition: "age > 7d",
                safety: .safe,
                confidence: 90,
                explanationSuffix: "Inactive for over a week.",
                profiles: ["deep"]
            ),
        ]
    )

    /// Built-in Dev Purge profile.
    ///
    /// Narrow scope for the Dev Artifact Purge view: only developer artifacts,
    /// Docker, and Homebrew. Deliberately excludes browser caches, system caches,
    /// temp files, etc. so Dev Purge cannot inadvertently widen into a full clean.
    public static let devPurge = CleanupProfile(
        id: "devPurge",
        name: "Dev Purge",
        description: "Developer artifacts + Docker + Homebrew only",
        categories: ["dev_artifacts", "docker", "homebrew"],
        safetyOverrides: [
            SafetyOverride(
                condition: "age > 30d",
                safety: .safe,
                confidence: 95,
                explanationSuffix: "No project activity in 30+ days. Restore with package manager.",
                profiles: ["devPurge"]
            ),
        ]
    )

    /// Built-in AI Models profile.
    ///
    /// Narrow scope for the AI / Models view: only AI model storage. Models
    /// take minutes to hours to re-download, so the default safety lean is
    /// `review` and overrides bias toward keeping recently-touched files.
    public static let aiModels = CleanupProfile(
        id: "aiModels",
        name: "AI Models",
        description: "Downloaded LLM and diffusion models from local AI tools",
        categories: ["ai_models"],
        safetyOverrides: [
            SafetyOverride(
                condition: "age > 90d",
                safety: .review,
                confidence: 75,
                explanationSuffix: "No access in 90+ days. Re-downloading requires the original tool.",
                profiles: ["aiModels"]
            ),
        ]
    )

    /// All built-in profiles.
    public static let builtIn: [CleanupProfile] = [.developer, .light, .deep]

    /// Resolve a cleanup profile for the given active profile ID.
    ///
    /// Searches the provided persisted profiles first (user overrides win),
    /// then the built-in set (including `.devPurge` and `.aiModels`), and
    /// finally returns the supplied fallback when nothing matches. Call sites
    /// that cannot reach persistence should pass `persisted: []` and rely on
    /// the fallback.
    public static func resolve(
        activeProfileID: String,
        persisted: [CleanupProfile] = [],
        fallback: CleanupProfile = .deep
    ) -> CleanupProfile {
        if let match = persisted.first(where: { $0.id == activeProfileID }) {
            return match
        }
        for profile in [CleanupProfile.developer, .light, .deep, .devPurge, .aiModels]
            where profile.id == activeProfileID {
            return profile
        }
        return fallback
    }
}
