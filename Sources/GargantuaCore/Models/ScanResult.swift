import Foundation

/// A single item discovered during a scan, carrying full Trust Layer metadata.
public struct ScanResult: Codable, Sendable, Identifiable {
    /// Unique identifier for this scan item (e.g., "chrome_cache_001").
    public let id: String

    /// Human-readable name (e.g., "Chrome Browser Cache").
    public let name: String

    /// Absolute file path.
    public let path: String

    /// Size in bytes.
    public let size: Int64

    /// Trust Layer safety classification.
    public var safety: SafetyLevel

    /// Confidence percentage (0–100) in the safety classification.
    public let confidence: Int

    /// One-line explanation of what this item is and why it's classified this way.
    public let explanation: String

    /// Source attribution — which app or system process created this.
    public let source: SourceAttribution

    /// When this file was last accessed.
    public let lastAccessed: Date?

    /// Scan category (e.g., "browser_cache", "dev_artifacts").
    public let category: String

    /// Tags for filtering and grouping.
    public let tags: [String]

    /// Whether this item can be regenerated (e.g., caches).
    public let regenerates: Bool

    /// Command to regenerate, if applicable (e.g., "npm install").
    public let regenerateCommand: String?

    public init(
        id: String,
        name: String,
        path: String,
        size: Int64,
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        source: SourceAttribution,
        lastAccessed: Date? = nil,
        category: String,
        tags: [String] = [],
        regenerates: Bool = false,
        regenerateCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.source = source
        self.lastAccessed = lastAccessed
        self.category = category
        self.tags = tags
        self.regenerates = regenerates
        self.regenerateCommand = regenerateCommand
    }
}

/// Attribution for the app or process that created a scan item.
public struct SourceAttribution: Codable, Sendable, Equatable {
    /// Display name (e.g., "Google Chrome").
    public let name: String

    /// macOS bundle identifier, if known (e.g., "com.google.Chrome").
    public let bundleID: String?

    /// Whether the source binary's code signature should be verified.
    public let verifySignature: Bool

    public init(name: String, bundleID: String? = nil, verifySignature: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.verifySignature = verifySignature
    }
}
